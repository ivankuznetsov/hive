require "json"
require "timeout"
require "yaml"
require "hive/secret_patterns"

module Hive
  module Gh
    NETWORK_TIMEOUT_SEC = 60
    POLL_INTERVAL_SEC = 0.05

    CommandStatus = Struct.new(:exitstatus, keyword_init: true) do
      def success?
        exitstatus == 0
      end
    end

    # Returned by push_branch so callers can decide whether to set a
    # `reason=unpushed_commits` marker vs. exit. A persistent push
    # failure during finalize must surface as an ERROR marker, not an
    # uncaught exit (Plan R5 / finalize verify_state!).
    PushResult = Struct.new(:success, :stdout, :stderr, keyword_init: true) do
      def success?
        success
      end
    end

    # Returned by scan_pr_for_secrets so a remote-fetch failure is
    # distinguishable from a clean scan. A blanket rescue that
    # returned `[]` on any error would reduce a security-critical
    # gate to a no-op on any transient gh hiccup.
    ScanResult = Struct.new(:hits, :fetch_failed, :fetch_error, keyword_init: true) do
      def clean?
        hits.empty? && !fetch_failed
      end
    end

    module_function

    def ensure_authenticated!(cfg = nil)
      out, err, status = capture3("gh", "auth", "status", cfg: cfg)
      return if status.success?

      raise Hive::GhError, "gh not authenticated (`gh auth login`):\n#{err.empty? ? out : err}"
    end

    # Push the branch and return a PushResult. Callers that want to
    # exit on failure can do so explicitly; finalize prefers to write
    # a structured marker.
    def push_branch(worktree_path, branch, cfg: nil)
      out, err, status = capture3("git", "-C", worktree_path, "push", "-u", "origin", branch, cfg: cfg)
      PushResult.new(success: status.success?, stdout: out, stderr: err)
    rescue Hive::GhError => e
      PushResult.new(success: false, stdout: "", stderr: e.message)
    end

    # Hard-fail wrapper for callers that have no recovery path (open-pr).
    def push_branch!(worktree_path, branch, cfg: nil)
      result = push_branch(worktree_path, branch, cfg: cfg)
      return if result.success?

      raise Hive::GhError, "git push failed: #{result.stderr.strip.empty? ? result.stdout : result.stderr}"
    end

    # Look up all pull requests for `branch`. Returns the raw array from
    # `gh pr list --state all`; callers decide which states matter.
    # Raises Hive::GhError when `gh pr list` itself fails or returns
    # unparseable JSON — the caller can't safely decide between
    # "no PR exists" and "remote unavailable" without this signal.
    #
    # The returned hashes may omit optional fields on older/future gh JSON
    # shapes. Stage code treats a missing `isDraft` key as draft for
    # forward compatibility; only an explicit false means "already ready".
    def lookup_prs_for_branch(worktree_path, branch, cfg: nil)
      # `gh -R` accepts a `owner/repo` slug but not a worktree path;
      # `--repo` likewise. `gh` resolves the remote from cwd's git
      # config, so route through chdir. Earlier passes flagged the
      # inconsistency with the `git -C <path>` style used elsewhere
      # in this module; the difference is load-bearing (gh has no
      # `-C` flag), not stylistic. Kept here with a comment so the
      # next reader doesn't "fix" it.
      out, err, status = capture3("gh", "pr", "list", "--head", branch,
                                  "--state", "all", "--json", "url,number,state,isDraft,headRefName,headRefOid",
                                  chdir: worktree_path, cfg: cfg)
      unless status.success?
        raise Hive::GhError, "`gh pr list` failed for branch #{branch}: #{err.to_s.strip.empty? ? out : err.strip}"
      end

      list = JSON.parse(out)
      unless list.is_a?(Array)
        raise Hive::GhError, "`gh pr list` returned #{list.class} for branch #{branch}; expected Array"
      end
      list
    rescue JSON::ParserError => e
      raise Hive::GhError, "`gh pr list` returned unparseable JSON for branch #{branch}: #{e.message}"
    end

    # Normal open-PR path: return only OPEN pull requests. CLOSED/MERGED
    # PRs are handled by explicit recovery paths so a stale URL cannot
    # silently flow into draft-finalization commands.
    def lookup_existing_pr(worktree_path, branch, cfg: nil)
      lookup_prs_for_branch(worktree_path, branch, cfg: cfg).find { |p| p["state"] == "OPEN" }
    end

    def list_open_prs(worktree_path, cfg: nil)
      fields = %w[
        number
        headRefName
        baseRefName
        labels
        isDraft
        isCrossRepository
        author
        headRepository
        url
        updatedAt
      ].join(",")
      out, err, status = capture3("gh", "pr", "list",
                                  "--state", "open",
                                  "--limit", "1000",
                                  "--json", fields,
                                  chdir: worktree_path,
                                  cfg: cfg)
      unless status.success?
        raise Hive::GhError, "`gh pr list` failed: #{err.to_s.strip.empty? ? out : err.strip}"
      end

      list = JSON.parse(out)
      raise Hive::GhError, "`gh pr list` returned #{list.class}; expected Array" unless list.is_a?(Array)

      list
    rescue JSON::ParserError => e
      raise Hive::GhError, "`gh pr list` returned unparseable JSON: #{e.message}"
    end

    def pr_status_rollup(worktree_path, number, cfg: nil)
      out, err, status = capture3("gh", "pr", "view", number.to_s,
                                  "--json", "mergeable,mergeStateStatus,statusCheckRollup,headRefOid,url",
                                  chdir: worktree_path,
                                  cfg: cfg)
      unless status.success?
        raise Hive::GhError, "`gh pr view #{number}` failed: #{err.to_s.strip.empty? ? out : err.strip}"
      end

      doc = JSON.parse(out)
      raise Hive::GhError, "`gh pr view #{number}` returned #{doc.class}; expected Hash" unless doc.is_a?(Hash)

      doc
    rescue JSON::ParserError => e
      raise Hive::GhError, "`gh pr view #{number}` returned unparseable JSON: #{e.message}"
    end

    def pr_failing_job_logs(worktree_path, number, cfg: nil, byte_cap: 50 * 1024)
      rollup = pr_status_rollup(worktree_path, number, cfg: cfg)
      failing_jobs_with_logs(worktree_path, rollup, cfg: cfg, byte_cap: byte_cap)
    end

    def failing_jobs_with_logs(worktree_path, rollup, cfg: nil, byte_cap: 50 * 1024)
      jobs = failing_jobs_from_rollup(rollup)
      return [] if jobs.empty?

      # Two-pass budget allocation: jobs whose full log fits under an even
      # share keep their full text, and the bytes they leave unused are
      # redistributed across the over-cap jobs. A flat `byte_cap / jobs.size`
      # cap makes short jobs underspend while truncating the large failing
      # job more aggressively than the budget allows (plan IU-8).
      raw = jobs.map do |job|
        job_id = job["databaseId"] || job["id"]
        { "name" => job["name"].to_s, "job_id" => job_id, "log" => fetch_job_log(worktree_path, job_id, cfg: cfg) }
      end

      caps = allocate_log_budget(raw.map { |entry| entry["log"].bytesize }, byte_cap)
      raw.each_with_index.map do |entry, index|
        entry.merge("log" => tail_clip(entry["log"], caps[index]))
      end
    end

    def fetch_job_log(worktree_path, job_id, cfg: nil)
      return "[hive-babysitter: no job id available, cannot fetch log]" unless job_id

      fetch_result = fetch_failed_job_log(worktree_path, job_id, cfg: cfg)
      return fetch_result[:log] if fetch_result[:success]

      "[hive-babysitter: failed to fetch log for job #{job_id} via gh run view: #{fetch_result[:error]}]"
    end

    # Max-min fair allocation: repeatedly hand out an even share of the
    # remaining budget; any log that fits under the current share is settled
    # at full size, freeing its leftover bytes for the rest. Whatever stays
    # over-cap then splits the leftover budget evenly.
    def allocate_log_budget(sizes, byte_cap)
      caps = Array.new(sizes.size)
      remaining = byte_cap
      unsettled = (0...sizes.size).to_a

      loop do
        break if unsettled.empty?

        share = [ remaining / unsettled.size, 1 ].max
        fits = unsettled.select { |i| sizes[i] <= share }
        break if fits.empty?

        fits.each do |i|
          caps[i] = sizes[i]
          remaining -= sizes[i]
        end
        unsettled -= fits
      end

      unless unsettled.empty?
        share = [ remaining / unsettled.size, 1 ].max
        unsettled.each { |i| caps[i] = share }
      end

      caps
    end

    def pr_diff_stat(worktree_path, base_ref, head_ref, cfg: nil)
      capture3("git", "fetch", "origin", base_ref.to_s, chdir: worktree_path, cfg: cfg)
      out, err, status = capture3("git", "diff", "--stat",
                                  "origin/#{base_ref}...#{head_ref}",
                                  chdir: worktree_path,
                                  cfg: cfg)
      unless status.success?
        raise Hive::GhError, "`git diff --stat origin/#{base_ref}...#{head_ref}` failed: #{err.to_s.strip.empty? ? out : err.strip}"
      end

      out
    end

    # Base HEAD + merge divergence summary for the babysitter prompt
    # (plan IU-5): the agent needs the current base tip and how far the PR
    # branch has diverged to decide between rebase, merge, or leave-alone.
    # Best-effort — supplementary context, so a git hiccup yields blank
    # values rather than failing the whole context build.
    def pr_base_divergence(worktree_path, base_ref, cfg: nil)
      capture3("git", "fetch", "origin", base_ref.to_s, chdir: worktree_path, cfg: cfg)
      counts = git_rev(worktree_path, "rev-list", "--left-right", "--count", "origin/#{base_ref}...HEAD", cfg: cfg)
      behind, ahead = counts.split(/\s+/)
      {
        "base_ref" => base_ref.to_s,
        "base_sha" => git_rev(worktree_path, "rev-parse", "origin/#{base_ref}", cfg: cfg),
        "merge_base" => git_rev(worktree_path, "merge-base", "origin/#{base_ref}", "HEAD", cfg: cfg),
        "ahead" => ahead.to_i,
        "behind" => behind.to_i
      }
    end

    def git_rev(worktree_path, *args, cfg: nil)
      out, _err, status = capture3("git", *args, chdir: worktree_path, cfg: cfg)
      status.success? ? out.to_s.strip : ""
    end

    def failing_jobs_from_rollup(rollup)
      Array(rollup["statusCheckRollup"]).select do |entry|
        next false unless entry.is_a?(Hash)

        conclusion = entry["conclusion"].to_s.upcase
        status = entry["status"].to_s.upcase
        conclusion == "FAILURE" || conclusion == "TIMED_OUT" || conclusion == "CANCELLED" || status == "FAILURE"
      end
    end

    def fetch_failed_job_log(worktree_path, job_id, cfg: nil)
      out, err, status = capture3("gh", "run", "view",
                                  "--log-failed",
                                  "--job", job_id.to_s,
                                  chdir: worktree_path,
                                  cfg: cfg)
      if status.success?
        { success: true, log: out, error: nil }
      else
        { success: false, log: "", error: err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip }
      end
    rescue Hive::GhError => e
      { success: false, log: "", error: e.message }
    end

    def tail_clip(text, byte_cap)
      text = text.to_s
      return text if text.bytesize <= byte_cap

      elided = text.bytesize - byte_cap
      tail = text.byteslice(-byte_cap, byte_cap).to_s
      tail.scrub!("")
      "\n...[truncated, #{elided} bytes elided]\n#{tail}"
    end

    def lookup_merged_pr(worktree_path, branch, cfg: nil, head_oid: nil)
      lookup_prs_for_branch(worktree_path, branch, cfg: cfg).find do |p|
        p["state"] == "MERGED" && (head_oid.nil? || p["headRefOid"].to_s == head_oid.to_s)
      end
    end

    def pr_frontmatter(path)
      return {} unless File.exist?(path)

      content = File.read(path)
      return {} unless content =~ /\A---\s*\n(.*?)\n---\s*\n/m

      parsed = YAML.safe_load(Regexp.last_match(1)) || {}
      parsed.is_a?(Hash) ? parsed : {}
    rescue Psych::Exception => e
      warn "hive: pr.md frontmatter unparseable (#{e.class}: #{e.message}); treating as empty"
      {}
    end

    # Scan the agent-authored state-file plus the remote PR body for
    # credential patterns. Returns a ScanResult. fetch_failed=true
    # signals the caller to fail loud rather than treat as clean.
    def scan_pr_for_secrets(state_file:, pr_url:, cfg: nil)
      sources = [ File.read(state_file) ]
      local_hits = sources.flat_map { |s| Hive::SecretPatterns.scan(s) }

      if pr_url.to_s.empty?
        return ScanResult.new(
          hits: local_hits,
          fetch_failed: false,
          fetch_error: nil
        )
      end

      out, err, status = capture3("gh", "pr", "view", pr_url, "--json", "body", "-q", ".body", cfg: cfg)
      unless status.success?
        return ScanResult.new(
          hits: local_hits,
          fetch_failed: true,
          fetch_error: err.to_s.strip.empty? ? out : err.strip
        )
      end

      sources << out unless out.empty?
      ScanResult.new(
        hits: sources.flat_map { |s| Hive::SecretPatterns.scan(s) },
        fetch_failed: false,
        fetch_error: nil
      )
    rescue Hive::GhError => e
      ScanResult.new(hits: local_hits || [], fetch_failed: true, fetch_error: e.message)
    end

    def network_timeout_sec(cfg = nil)
      value = cfg&.dig("gh", "network_timeout_sec")
      value.is_a?(Integer) && value.positive? ? value : NETWORK_TIMEOUT_SEC
    end

    def capture3(*cmd, chdir: nil, cfg: nil, timeout_sec: nil)
      timeout_sec ||= network_timeout_sec(cfg)
      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe
      env = { "GIT_TERMINAL_PROMPT" => "0", "GIT_SSH_COMMAND" => "ssh -o BatchMode=yes" }
      spawn_options = { out: stdout_w, err: stderr_w }
      spawn_options[:chdir] = chdir if chdir
      pid = Process.spawn(env, *cmd, **spawn_options)
      stdout_w.close
      stderr_w.close
      stdout_reader = Thread.new { stdout_r.read }
      stderr_reader = Thread.new { stderr_r.read }

      status = wait_with_deadline(pid, timeout_sec, cmd)
      [ stdout_reader.value, stderr_reader.value, status ]
    rescue SystemCallError => e
      raise Hive::GhError, "failed to run #{cmd.join(' ')}: #{e.message}"
    ensure
      [ stdout_w, stderr_w, stdout_r, stderr_r ].each do |io|
        io.close if io && !io.closed?
      rescue IOError
        nil
      end
    end

    def wait_with_deadline(pid, timeout_sec, cmd)
      deadline = Time.now + timeout_sec
      loop do
        waited = Process.waitpid2(pid, Process::WNOHANG)
        return waited[1] if waited

        if Time.now >= deadline
          terminate_process(pid)
          raise Hive::GhError, "network operation exceeded #{timeout_sec}s while running #{cmd.join(' ')}"
        end
        sleep POLL_INTERVAL_SEC
      end
    end

    def terminate_process(pid)
      Process.kill("TERM", pid)
      deadline = Time.now + 1
      loop do
        waited = Process.waitpid2(pid, Process::WNOHANG)
        return waited[1] if waited
        break if Time.now >= deadline

        sleep POLL_INTERVAL_SEC
      end
      Process.kill("KILL", pid)
      Process.waitpid2(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def with_network_timeout(timeout_sec: NETWORK_TIMEOUT_SEC, &block)
      yield
    rescue Timeout::Error
      raise Hive::GhError, "network operation exceeded #{timeout_sec}s"
    end
  end
end
