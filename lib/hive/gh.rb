require "json"
require "timeout"
require "uri"
require "yaml"
require "hive/git_ref"
require "hive/gh/repository_identity"
require "hive/managed_git"
require "hive/secret_patterns"

module Hive
  module Gh
    NETWORK_TIMEOUT_SEC = 60
    POLL_INTERVAL_SEC = 0.05

    # Leading YAML frontmatter block of a hive-authored pr.md. Capture group
    # 1 is the YAML body (used by #pr_frontmatter); #pr_body strips the whole
    # match. One definition so the two readers can't drift.
    FRONTMATTER_DELIMITER = /\A---\s*\n(.*?)\n---\s*\n/m

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

    # Immutable value object (Ruby 3.4 Data.define) so `pr_metadata` stays the
    # single validated constructor and the result is tamper-proof downstream.
    # Keyword construction + field readers are unchanged for consumers.
    PrMetadata = Data.define(:number, :url, :base_ref_name, :head_ref_oid, :is_cross_repository, :state)

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

    def ensure_authenticated!(cfg = nil, host: nil, timeout_sec: nil)
      args = [ "gh", "auth", "status" ]
      args.push("--hostname", RepositoryIdentity.validated_github_host(host)) if host
      out, err, status = capture3(*args, cfg: cfg, timeout_sec: timeout_sec)
      return if status.success?

      raise Hive::GhError, "gh not authenticated (`gh auth login`):\n#{err.empty? ? out : err}"
    end

    # Push the branch and return a PushResult. Callers that want to
    # exit on failure can do so explicitly; finalize prefers to write
    # a structured marker.
    def push_branch(worktree_path, branch, cfg: nil, force: false,
                    expected_remote_oid: nil, expected_remote_absent: false,
                    remote: "origin", set_upstream: true)
      branch = validated_branch_name(branch)
      remote = validated_remote_target(remote)
      args = [ "git", "-C", worktree_path, "push" ]
      args << "-u" if set_upstream
      # --force-with-lease (not --force): a concurrent third-party update to
      # the branch aborts the push instead of being clobbered.
      if expected_remote_oid && expected_remote_absent
        raise Hive::GhError, "remote branch cannot require both an OID and absence"
      elsif expected_remote_oid
        oid = expected_remote_oid.to_s
        unless oid.match?(/\A[0-9a-f]{40,64}\z/i)
          raise Hive::GhError, "expected remote branch OID is invalid"
        end
        args << "--force-with-lease=refs/heads/#{branch}:#{oid.downcase}"
      elsif expected_remote_absent
        args << "--force-with-lease=refs/heads/#{branch}:"
      elsif force
        args << "--force-with-lease"
      end
      args.push(remote, branch)
      out, err, status = capture3(*args, cfg: cfg)
      PushResult.new(success: status.success?, stdout: out, stderr: err)
    rescue Hive::GhError => e
      PushResult.new(success: false, stdout: "", stderr: e.message)
    end

    # Hard-fail wrapper for callers that have no recovery path (open-pr).
    def push_branch!(worktree_path, branch, cfg: nil,
                     expected_remote_oid: nil, expected_remote_absent: false,
                     remote: "origin", set_upstream: true)
      result = push_branch(
        worktree_path, branch, cfg: cfg, expected_remote_oid: expected_remote_oid,
        expected_remote_absent: expected_remote_absent, remote: remote,
        set_upstream: set_upstream
      )
      return if result.success?

      raise Hive::GhError, "git push failed: #{result.stderr.strip.empty? ? result.stdout : result.stderr}"
    end

    def remote_branch_oid(worktree_path, branch, cfg: nil, remote: "origin", managed: false)
      name = validated_branch_name(branch)
      remote = validated_remote_target(remote)

      ref = "refs/heads/#{name}"
      out, err, status = if managed
        Hive::ManagedGit.capture3(worktree_path, "ls-remote", "--heads", remote, ref)
      else
        capture3("git", "-C", worktree_path, "ls-remote", "--heads", remote, ref, cfg: cfg)
      end
      unless status.success?
        raise Hive::GhError,
              "git ls-remote failed: #{err.to_s.strip.empty? ? out : err}"
      end
      lines = out.lines.map(&:strip).reject(&:empty?)
      return nil if lines.empty?
      unless lines.one?
        raise Hive::GhError, "git ls-remote returned multiple records for #{ref}"
      end

      oid, returned_ref = lines.first.split(/\s+/, 2)
      unless returned_ref == ref && oid.to_s.match?(/\A[0-9a-f]{40,64}\z/i)
        raise Hive::GhError, "git ls-remote returned an invalid record for #{ref}"
      end

      oid.downcase
    end

    # Publish one immutable, already-scanned commit without naming a mutable
    # local branch. This is intentionally separate from #push_branch: managed
    # draft-PR handoffs never use force, leases, upstream mutation, or a branch
    # source that can move between validation and process spawn.
    def push_exact_oid(worktree_path, head_oid, branch, cfg: nil, remote: "origin")
      oid = head_oid.to_s.downcase
      unless oid.match?(/\A[0-9a-f]{40,64}\z/)
        raise Hive::GhError, "exact push OID is invalid"
      end
      name = validated_branch_name(branch)
      target = validated_remote_target(remote)
      refspec = "#{oid}:refs/heads/#{name}"
      out, err, status = Hive::ManagedGit.capture3(
        worktree_path, "push", target, refspec
      )
      PushResult.new(success: status.success?, stdout: out, stderr: err)
    rescue Hive::GhError => e
      PushResult.new(success: false, stdout: "", stderr: e.message)
    end

    # One explicit draft-PR creation attempt. The body is passed by restrictive
    # tempfile, never argv, and the file is unlinked by Tempfile on every exit
    # path including command failure, timeout, and interruption unwinding.
    def create_draft_pr(worktree_path, repository:, host:, head:, base:, title:, body:, cfg: nil)
      require "tempfile"

      target = RepositoryIdentity.github_repository_target(repository, host)
      Tempfile.create([ "hive-draft-pr-", ".md" ], mode: File::RDWR, perm: 0o600) do |file|
        file.write(body)
        file.flush
        args = [
          "gh", "pr", "create", "--repo", target, "--draft",
          "--head", validated_branch_name(head),
          "--base", validated_branch_name(base),
          "--title", title.to_s,
          "--body-file", file.path
        ]
        capture3(*args, chdir: worktree_path, cfg: cfg)
      end
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
    def lookup_prs_for_branch(worktree_path, branch, repository: nil, host: nil, cfg: nil)
      # `gh -R` accepts a `owner/repo` slug but not a worktree path;
      # `--repo` likewise. `gh` resolves the remote from cwd's git
      # config, so route through chdir. Earlier passes flagged the
      # inconsistency with the `git -C <path>` style used elsewhere
      # in this module; the difference is load-bearing (gh has no
      # `-C` flag), not stylistic. Kept here with a comment so the
      # next reader doesn't "fix" it.
      args = [
        "gh", "pr", "list", "--head", branch, "--state", "all", "--json",
        "url,number,state,isDraft,headRefName,headRefOid,body,baseRefName,baseRefOid,headRepository"
      ]
      if repository || host
        unless repository && host
          raise Hive::GhError, "repository and host must be provided together for pull-request lookup"
        end

        args.push("--repo", RepositoryIdentity.github_repository_target(repository, host))
      end
      out, err, status = capture3(*args, chdir: worktree_path, cfg: cfg)
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

    # `chdir` scopes `gh pr view` to a specific repo checkout. Ad-hoc review
    # passes the resolved project root so `hive review --pr N --project NAME`
    # run from another repo queries the right PR instead of cwd's repo.
    def pr_metadata(number, cfg: nil, chdir: nil)
      ensure_authenticated!(cfg)
      fields = "number,url,baseRefName,headRefOid,isCrossRepository,state"
      out, err, status = capture3("gh", "pr", "view", number.to_s, "--json", fields, cfg: cfg, chdir: chdir)
      unless status.success?
        raise Hive::GhError, "`gh pr view #{number}` failed: #{err.to_s.strip.empty? ? out : err.strip}"
      end

      doc = JSON.parse(out)
      raise Hive::GhError, "`gh pr view #{number}` returned #{doc.class}; expected Hash" unless doc.is_a?(Hash)

      PrMetadata.new(
        number: doc["number"].to_i,
        url: doc["url"].to_s,
        base_ref_name: doc["baseRefName"].to_s,
        head_ref_oid: doc["headRefOid"].to_s,
        is_cross_repository: doc["isCrossRepository"] == true,
        state: doc["state"].to_s
      )
    rescue JSON::ParserError => e
      raise Hive::GhError, "`gh pr view #{number}` returned unparseable JSON: #{e.message}"
    end

    def validated_branch_name(branch)
      Hive::GitRef.validate_branch_name(branch)
    rescue ArgumentError
      raise Hive::GhError, "remote branch name is invalid"
    end
    private_class_method :validated_branch_name

    def validated_remote_target(remote)
      value = remote.to_s
      if value.empty? || value.start_with?("-") || value.match?(/[\0\r\n]/)
        raise Hive::GhError, "git remote target is invalid"
      end

      value
    end
    private_class_method :validated_remote_target

    def pr_state(pr_url, cfg: nil)
      out, err, status = capture3("gh", "pr", "view", pr_url.to_s, "--json", "state", cfg: cfg)
      unless status.success?
        raise Hive::GhError, "`gh pr view #{pr_url}` failed: #{err.to_s.strip.empty? ? out : err.strip}"
      end

      doc = JSON.parse(out)
      raise Hive::GhError, "`gh pr view #{pr_url}` returned #{doc.class}; expected Hash" unless doc.is_a?(Hash)

      doc["state"].to_s
    rescue JSON::ParserError => e
      raise Hive::GhError, "`gh pr view #{pr_url}` returned unparseable JSON: #{e.message}"
    end

    # Bounded, repository-scoped transport for TaskClosure. The closure
    # service canonicalizes every identity before it reaches this boundary;
    # these helpers still validate the host/repository/OID so no caller can
    # turn an evidence reference into an arbitrary URL fetch or gh argv.
    def closure_pr_facts(host:, repository:, number:, default_branch: nil, cfg: nil)
      host = RepositoryIdentity.validated_github_host(host)
      repository = RepositoryIdentity.validated_repository_slug(repository)
      number = Integer(number)
      raise Hive::GhError, "pull request number must be positive" unless number.positive?

      target = RepositoryIdentity.github_repository_target(repository, host)
      fields = "number,url,state,mergedAt,mergeCommit,baseRefName"
      out, err, status = capture3(
        "gh", "pr", "view", number.to_s, "--repo", target, "--json", fields,
        cfg: cfg, max_stdout_bytes: 128 * 1024
      )
      unless status.success?
        raise Hive::GhError,
              "`gh pr view #{repository}##{number}` failed: #{err.to_s.strip.empty? ? out : err.strip}"
      end
      doc = JSON.parse(out)
      raise Hive::GhError, "pull request lookup returned #{doc.class}; expected Hash" unless doc.is_a?(Hash)
      unless doc["number"].to_i == number
        raise Hive::GhError, "pull request lookup returned a different number"
      end
      merge_oid = if doc["mergeCommit"].is_a?(Hash)
        doc["mergeCommit"]["oid"]
      else
        doc["mergeCommit"]
      end
      default_branch ||= closure_default_branch(
        host: host, repository: repository, cfg: cfg
      )
      reachable = !merge_oid.to_s.empty? && closure_commit_facts(
        host: host, repository: repository, oid: merge_oid,
        default_branch: default_branch, cfg: cfg
      ).fetch("reachable_from_default")
      {
        "repository" => repository,
        "number" => number,
        "url" => doc["url"].to_s,
        "state" => doc["state"].to_s,
        "merged_at" => doc["mergedAt"].to_s,
        "merge_oid" => merge_oid.to_s.downcase,
        "base_ref_name" => doc["baseRefName"].to_s,
        "reachable_from_default" => reachable
      }
    rescue JSON::ParserError => e
      raise Hive::GhError, "pull request lookup returned unparseable JSON: #{e.message}"
    rescue ArgumentError, TypeError
      raise Hive::GhError, "pull request number must be positive"
    end

    def closure_default_branch(host:, repository:, cfg: nil)
      host = RepositoryIdentity.validated_github_host(host)
      repository = RepositoryIdentity.validated_repository_slug(repository)
      endpoint = "repos/#{repository}"
      out, err, status = capture3(
        "gh", "api", "--hostname", host, endpoint, "--jq", ".default_branch",
        cfg: cfg, max_stdout_bytes: 4 * 1024
      )
      unless status.success?
        raise Hive::GhError,
              "`gh api #{endpoint}` failed: #{err.to_s.strip.empty? ? out : err.strip}"
      end
      branch = out.to_s.strip
      if branch.empty? || branch.start_with?("-") || branch.match?(/[\0\r\n\s]/)
        raise Hive::GhError, "repository default branch is invalid"
      end
      branch
    end

    def closure_commit_facts(host:, repository:, oid:, default_branch:, cfg: nil)
      host = RepositoryIdentity.validated_github_host(host)
      repository = RepositoryIdentity.validated_repository_slug(repository)
      oid = oid.to_s.downcase
      unless oid.match?(/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/)
        raise Hive::GhError, "closure evidence requires a full immutable commit OID"
      end
      branch = default_branch.to_s
      if branch.empty? || branch.start_with?("-") || branch.match?(/[\0\r\n\s]/)
        raise Hive::GhError, "repository default branch is invalid"
      end

      commit_endpoint = "repos/#{repository}/commits/#{oid}"
      out, err, status = capture3(
        "gh", "api", "--hostname", host, commit_endpoint, "--jq", ".sha",
        cfg: cfg, max_stdout_bytes: 4 * 1024
      )
      unless status.success?
        raise Hive::GhError,
              "`gh api #{commit_endpoint}` failed: #{err.to_s.strip.empty? ? out : err.strip}"
      end
      observed_oid = out.to_s.strip.downcase
      unless observed_oid == oid
        raise Hive::GhError, "commit lookup returned a different immutable OID"
      end

      compare_endpoint = "repos/#{repository}/compare/#{oid}...#{branch}"
      comparison, compare_err, compare_status = capture3(
        "gh", "api", "--hostname", host, compare_endpoint, "--jq", ".status",
        cfg: cfg, max_stdout_bytes: 4 * 1024
      )
      unless compare_status.success?
        raise Hive::GhError,
              "`gh api #{compare_endpoint}` failed: " \
              "#{compare_err.to_s.strip.empty? ? comparison : compare_err.strip}"
      end
      compare_state = comparison.to_s.strip.downcase
      {
        "oid" => observed_oid,
        "default_branch" => branch,
        "comparison" => compare_state,
        # Comparing base=OID to head=default means `ahead` or `identical`
        # proves the immutable commit is reachable from current default.
        "reachable_from_default" => %w[ahead identical].include?(compare_state)
      }
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
        mergeStateStatus
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

    def repo_name_with_owner(worktree_path, cfg: nil)
      repository_identity(worktree_path, cfg: cfg).fetch("repository")
    end

    def repository_identity(worktree_path, cfg: nil, timeout_sec: nil, managed: false)
      repository_identity_from_remote(
        origin_push_url(
          worktree_path, cfg: cfg, timeout_sec: timeout_sec, managed: managed
        )
      )
    end

    def origin_push_url(worktree_path, cfg: nil, timeout_sec: nil, managed: false)
      out, err, status = if managed
        Hive::ManagedGit.capture3(
          worktree_path, "remote", "get-url", "--push", "--all", "origin"
        )
      else
        capture3(
          "git", "-C", worktree_path, "remote", "get-url", "--push", "--all", "origin",
          cfg: cfg, timeout_sec: timeout_sec
        )
      end
      unless status.success?
        raise Hive::GhError,
              "`git remote get-url --push --all origin` failed in #{worktree_path}: " \
              "#{err.to_s.strip.empty? ? out : err.strip}"
      end
      urls = out.lines.map(&:strip).reject(&:empty?)
      unless urls.one?
        raise Hive::GhError, "origin push URL lookup returned #{urls.size} records"
      end

      urls.first
    end

    def repository_identity_from_remote(remote_url)
      value = remote_url.to_s.strip
      scp = value.match(/\A(?:[^@\/]+@)?([^:\/]+):\/?([^\/]+\/[^\/]+?)\z/)
      if scp && !value.match?(/\A[a-z][a-z0-9+.-]*:\/\//i)
        return remote_identity(scp[1], scp[2])
      end

      uri = URI.parse(value)
      unless %w[http https ssh git].include?(uri.scheme.to_s.downcase) && uri.host
        raise Hive::GhError, "origin push URL is not a supported GitHub remote"
      end
      credentials = uri.userinfo.to_s
      unsafe_credentials = if %w[http https git].include?(uri.scheme.to_s.downcase)
        !credentials.empty?
      else
        credentials.include?(":")
      end
      if unsafe_credentials || uri.query || uri.fragment
        raise Hive::GhError, "origin push URL contains unsupported credentials or suffixes"
      end

      remote_identity(uri.host, uri.path.to_s.sub(%r{\A/}, ""))
    rescue URI::InvalidURIError => e
      raise Hive::GhError, "origin push URL is invalid: #{e.message}"
    end

    def remote_identity(host, repository)
      slug = repository.to_s.sub(/\.git\z/i, "")
      {
        "repository" => RepositoryIdentity.validated_repository_slug(slug),
        "host" => RepositoryIdentity.validated_github_host(host)
      }
    end
    private_class_method :remote_identity


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
      return {} unless content =~ FRONTMATTER_DELIMITER

      parsed = YAML.safe_load(Regexp.last_match(1)) || {}
      parsed.is_a?(Hash) ? parsed : {}
    rescue Psych::Exception => e
      warn "hive: pr.md frontmatter unparseable (#{e.class}: #{e.message}); treating as empty"
      {}
    end

    # Scan the agent-authored state-file plus the remote PR body for
    # credential patterns. A missing local file is the normal first-entry
    # shape for open-pr, before its agent has authored pr.md; remote scanning
    # must still proceed in that case. Other local read failures propagate.
    # Returns a ScanResult. fetch_failed=true signals the caller to fail loud
    # rather than treat a remote-fetch failure as clean.
    def scan_pr_for_secrets(state_file:, pr_url:, cfg: nil)
      sources = []
      sources << File.read(state_file) if File.exist?(state_file)
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

    def capture3(*cmd, chdir: nil, cfg: nil, timeout_sec: nil, max_stdout_bytes: nil,
                 stdout_path: nil)
      timeout_sec = normalized_timeout(timeout_sec || network_timeout_sec(cfg))
      stdout_limit = max_stdout_bytes.nil? ? nil : Integer(max_stdout_bytes)
      if stdout_limit && stdout_limit.negative?
        raise ArgumentError, "max_stdout_bytes must be non-negative"
      end
      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe
      env = { "GIT_TERMINAL_PROMPT" => "0", "GIT_SSH_COMMAND" => "ssh -o BatchMode=yes" }
      # A dedicated process group lets the deadline cover helpers that inherit
      # stdout/stderr after the direct gh process exits. Otherwise waitpid can
      # succeed while reader threads block forever on a descendant-held pipe.
      spawn_options = { out: stdout_w, err: stderr_w, pgroup: true }
      spawn_options[:chdir] = chdir if chdir
      pid = Process.spawn(env, *cmd, **spawn_options)
      stdout_w.close
      stderr_w.close
      stdout_reader = Thread.new do
        Thread.current.report_on_exception = false
        read_capture_stream(
          stdout_r,
          max_bytes: stdout_limit,
          output_path: stdout_path,
          on_limit: lambda do
            signal_process_group("KILL", pid)
          rescue Errno::ESRCH
            nil
          end
        )
      end
      stderr_reader = Thread.new { read_capture_stream(stderr_r) }

      status = wait_with_deadline(
        pid, timeout_sec, cmd, readers: [ stdout_reader, stderr_reader ]
      )
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

    def wait_with_deadline(pid, timeout_sec, cmd, readers: [])
      deadline = monotonic_now + timeout_sec
      status = nil
      loop do
        waited = Process.waitpid2(pid, Process::WNOHANG) unless status
        status = waited[1] if waited
        return status if status && readers.none?(&:alive?)

        if monotonic_now >= deadline
          terminate_process_group(pid)
          raise Hive::GhError, "network operation exceeded #{timeout_sec}s while running #{cmd.join(' ')}"
        end
        sleep POLL_INTERVAL_SEC
      end
    end

    def read_capture_stream(io, max_bytes: nil, on_limit: nil, output_path: nil)
      output = String.new(encoding: Encoding::BINARY)
      bytes = 0
      sink = if output_path
        File.open(output_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600)
      end
      begin
        loop do
          chunk = io.readpartial(16 * 1024)
          bytes += chunk.bytesize
          if max_bytes && bytes > max_bytes
            on_limit&.call
            raise Hive::GhError, "command output exceeds the #{max_bytes}-byte safety ceiling"
          end
          sink ? sink.write(chunk) : output << chunk
        end
      rescue EOFError, IOError
        sink ? "" : output
      ensure
        sink&.close
      end
    end

    def terminate_process_group(pid)
      signal_process_group("TERM", pid)
      deadline = monotonic_now + 1
      while process_group_alive?(pid) && monotonic_now < deadline
        reap_process(pid, nonblock: true)
        sleep POLL_INTERVAL_SEC
      end
      signal_process_group("KILL", pid) if process_group_alive?(pid)
      reap_process(pid, nonblock: false)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def signal_process_group(signal, pid)
      Process.kill(signal, -Integer(pid))
    end

    def process_group_alive?(pid)
      Process.kill(0, -Integer(pid))
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def reap_process(pid, nonblock:)
      Process.waitpid2(pid, nonblock ? Process::WNOHANG : 0)
    rescue Errno::ECHILD
      nil
    end

    def terminate_process(pid)
      Process.kill("TERM", pid)
      deadline = monotonic_now + 1
      loop do
        waited = Process.waitpid2(pid, Process::WNOHANG)
        return waited[1] if waited
        break if monotonic_now >= deadline

        sleep POLL_INTERVAL_SEC
      end
      Process.kill("KILL", pid)
      Process.waitpid2(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def normalized_timeout(value)
      timeout = Float(value)
      unless timeout.finite? && timeout.positive?
        raise Hive::GhError, "network timeout must be positive"
      end

      timeout
    rescue TypeError, ArgumentError
      raise Hive::GhError, "network timeout must be positive"
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def with_network_timeout(timeout_sec: NETWORK_TIMEOUT_SEC, &block)
      yield
    rescue Timeout::Error
      raise Hive::GhError, "network operation exceeded #{timeout_sec}s"
    end
  end
end
