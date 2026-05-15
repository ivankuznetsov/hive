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

    # Look up an OPEN pull request for `branch`. Returns:
    #   - the PR hash when an OPEN PR exists for this branch
    #   - nil when `gh pr list` succeeds and reports no OPEN PR
    # Raises Hive::GhError when `gh pr list` itself fails or returns
    # unparseable JSON — the caller can't safely decide between
    # "no PR exists" and "remote unavailable" without this signal,
    # and silently falling through opens a second PR for the same
    # branch on retry (Plan R5).
    #
    # CLOSED/MERGED PRs are explicitly NOT returned: a stale URL
    # would propagate into pr.md and downstream `gh pr edit` /
    # `gh pr ready` calls would target a dead PR.
    #
    # The returned hash may omit `isDraft` on older/future gh JSON
    # shapes. Stage code treats a missing key as draft for forward
    # compatibility; only an explicit false means "already ready".
    def lookup_existing_pr(worktree_path, branch, cfg: nil)
      # `gh -R` accepts a `owner/repo` slug but not a worktree path;
      # `--repo` likewise. `gh` resolves the remote from cwd's git
      # config, so route through chdir. Earlier passes flagged the
      # inconsistency with the `git -C <path>` style used elsewhere
      # in this module; the difference is load-bearing (gh has no
      # `-C` flag), not stylistic. Kept here with a comment so the
      # next reader doesn't "fix" it.
      out, err, status = capture3("gh", "pr", "list", "--head", branch,
                                  "--state", "all", "--json", "url,number,state,isDraft",
                                  chdir: worktree_path, cfg: cfg)
      unless status.success?
        raise Hive::GhError, "`gh pr list` failed for branch #{branch}: #{err.to_s.strip.empty? ? out : err.strip}"
      end

      list = JSON.parse(out)
      unless list.is_a?(Array)
        raise Hive::GhError, "`gh pr list` returned #{list.class} for branch #{branch}; expected Array"
      end
      list.find { |p| p["state"] == "OPEN" }
    rescue JSON::ParserError => e
      raise Hive::GhError, "`gh pr list` returned unparseable JSON for branch #{branch}: #{e.message}"
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
