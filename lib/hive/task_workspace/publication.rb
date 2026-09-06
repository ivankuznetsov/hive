require "json"
require "yaml"
require "hive/git_ref"
require "hive/gh"
require "hive/invoked_binary"
require "hive/secret_patterns"
require "hive/task_workspace"
require "hive/task_workspace/publication_cache"
require "hive/worktree"

module Hive
  module TaskWorkspace
    # Read-only publication projection. Local commands are fixed, bounded Git
    # reads; remote facts come only from an injected cache and this class never
    # fetches, pushes, or calls GitHub.
    class Publication
      OID_RE = /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/.freeze
      POLL_INTERVAL = 0.02
      Status = Data.define(:success?, :exitstatus)

      def initialize(task:, expected_repository: nil, expected_root: nil,
                     cache: nil, limits: Limits.new, pointer_reader: nil,
                     runner: nil, deadline: nil,
                     monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @task = task
        @expected_repository = canonical_repository(expected_repository)
        @expected_root = expected_root || Hive::Worktree.canonical_root(task.project_root)
        @cache = cache
        @limits = limits
        @pointer_reader = pointer_reader
        @runner = runner || method(:run_command)
        @monotonic_clock = monotonic_clock
        @started_at = @monotonic_clock.call
        @deadline = [
          @started_at + @limits.fetch(:local_git_deadline_seconds), deadline
        ].compact.min
        @remaining_bytes = @limits.fetch(:local_git_bytes)
      end

      def call
        diagnostics = []
        pointer = read_pointer(diagnostics)
        unless pointer
          return panel(
            state: "unavailable", local: unavailable_local,
            pr: missing_pr, remote: unavailable_remote("identity_unavailable"),
            publication_state: "worktree_unavailable", diagnostics: diagnostics,
            refresh_identity: nil
          )
        end

        local = observe_local(pointer, diagnostics)
        pr = read_pr(pointer, diagnostics)
        refresh_identity = refresh_identity(pointer, local, pr, diagnostics)
        remote = if @cache && refresh_identity
          @cache.read(refresh_identity)
        else
          unavailable_remote(@cache ? "identity_unavailable" : "not_observed")
        end
        state = panel_state(pointer, local, pr, remote, diagnostics)
        panel(
          state: state, local: local, pr: pr, remote: remote,
          publication_state: publication_state(local, pr, remote),
          diagnostics: diagnostics + Array(remote["diagnostics"]),
          refresh_identity: refresh_identity
        )
      rescue StandardError => e
        panel(
          state: "unavailable", local: unavailable_local,
          pr: missing_pr, remote: unavailable_remote("projection_failed"),
          publication_state: "unavailable",
          diagnostics: [ diagnostic("projection_failed", e.class.name) ],
          refresh_identity: nil
        )
      end

      private

      def read_pointer(diagnostics)
        raw = if @pointer_reader
          @pointer_reader.call
        else
          read_pointer_file
        end
        raw = raw.to_h.transform_keys(&:to_s)
        expected_path = Hive::Worktree.realpath_or_expand(
          File.join(@expected_root, @task.slug.to_s)
        )
        path = Hive::Worktree.validate_pointer_path(raw["path"], @expected_root)
        branch = Hive::GitRef.validate_branch_name(raw["branch"])
        unless path == expected_path && branch == @task.slug.to_s
          diagnostics << diagnostic("pointer_identity_mismatch")
          return nil
        end

        base_branch = valid_branch_or_nil(raw["base_branch"])
        base_oid = valid_oid_or_nil(raw["base_oid"] || raw["execute_base_head"])
        repository = canonical_repository(raw["repository"])
        strict = base_branch && base_oid && repository && @expected_repository &&
                 repository == @expected_repository
        if @expected_repository && repository && repository != @expected_repository
          diagnostics << diagnostic("repository_mismatch")
          return nil
        end
        diagnostics << diagnostic("registered_repository_missing") unless @expected_repository
        unless strict
          diagnostics << diagnostic("legacy_pointer_partial")
        end
        {
          "path" => path, "branch" => branch,
          "base_branch" => base_branch, "base_oid" => base_oid,
          "repository" => repository || @expected_repository,
          "identity_state" => strict ? "current" : "partial"
        }
      rescue SourceError => e
        diagnostics << e.diagnostic
        nil
      rescue Hive::WorktreeError, ArgumentError, TypeError => e
        diagnostics << diagnostic("pointer_invalid", e.class.name)
        nil
      end

      def read_pointer_file
        result = BoundedReader.new(root: @task.folder).read(
          "worktree.yml", max_bytes: Hive::Worktree::STRICT_POINTER_MAX_BYTES
        )
        raise SourceError.new(source: "worktree_receipt", reason: "pointer_truncated") if
          result.truncated || result.binary

        duplicate_keys = result.content.lines.filter_map do |line|
          line[/\A([A-Za-z_][A-Za-z0-9_]*):(?:\s|$)/, 1]
        end.tally.select { |_key, count| count > 1 }.keys
        unless duplicate_keys.empty?
          raise SourceError.new(source: "worktree_receipt", reason: "pointer_duplicate_keys")
        end
        parsed = YAML.safe_load(
          result.content, permitted_classes: [], permitted_symbols: [], aliases: false
        )
        unless parsed.is_a?(Hash) && parsed["path"] && parsed["branch"]
          raise SourceError.new(source: "worktree_receipt", reason: "pointer_shape_invalid")
        end
        parsed
      rescue Psych::Exception
        raise SourceError.new(source: "worktree_receipt", reason: "pointer_yaml_invalid")
      end

      def observe_local(pointer, diagnostics)
        path = pointer.fetch("path")
        project_common = git_value(@task.project_root, [ "rev-parse", "--git-common-dir" ])
        worktree_common = git_value(path, [ "rev-parse", "--git-common-dir" ])
        registered = git_value(@task.project_root, [ "worktree", "list", "--porcelain" ])
                     .lines.filter_map do |line|
          line.delete_prefix("worktree ").strip if line.start_with?("worktree ")
        end.map { |candidate| Hive::Worktree.realpath_or_expand(candidate) }
        resolved_project_common = Hive::Worktree.realpath_or_expand(
          File.expand_path(project_common, @task.project_root)
        )
        resolved_worktree_common = Hive::Worktree.realpath_or_expand(
          File.expand_path(worktree_common, path)
        )
        unless resolved_project_common == resolved_worktree_common && registered.include?(path)
          raise SourceError.new(source: "local_git", reason: "worktree_ownership_mismatch")
        end

        head = valid_oid_or_nil(git_value(path, [ "rev-parse", "--verify", "HEAD" ]))
        raise SourceError.new(source: "local_git", reason: "head_invalid") unless head

        branch = git_value(path, [ "branch", "--show-current" ]).strip
        if branch != pointer.fetch("branch")
          diagnostics << diagnostic("branch_mismatch")
        end
        dirty = !git_value(path, [ "status", "--porcelain=v1", "--untracked-files=all" ]).empty?
        observed_base_oid = observe_base_ref(path, pointer["base_branch"], diagnostics)
        base_state = observe_base(path, pointer["base_oid"], head, diagnostics)
        commits = observe_commits(path, pointer["base_oid"], head, diagnostics)
        push = observe_tracking(path, pointer.fetch("branch"), head, diagnostics)
        {
          "state" => diagnostics.any? { |row| row["source"] == "local_git" } ? "partial" : "current",
          "repository" => pointer["repository"],
          "branch" => branch.empty? ? nil : branch,
          "expected_branch" => pointer.fetch("branch"),
          "base_branch" => pointer["base_branch"],
          "base_oid" => pointer["base_oid"],
          "observed_base_oid" => observed_base_oid,
          "head_oid" => head,
          "base_state" => base_state,
          "dirty" => dirty,
          "commits" => commits,
          "commits_truncated" => commits.length >= @limits.fetch(:local_git_commits),
          "push" => push
        }
      rescue SourceError => e
        diagnostics << e.diagnostic
        unavailable_local
      end

      def observe_base_ref(path, base_branch, diagnostics)
        return nil unless base_branch

        out, _err, status, _metadata = git_capture(
          path, [ "rev-parse", "--verify", "--quiet", base_branch ], allow_exit: [ 0, 1 ]
        )
        return nil if status.exitstatus == 1

        oid = valid_oid_or_nil(out.strip)
        diagnostics << diagnostic("base_ref_invalid", nil, source: "local_git") unless oid
        oid
      rescue SourceError => e
        diagnostics << e.diagnostic
        nil
      end

      def observe_base(path, base_oid, head, diagnostics)
        return "unavailable" unless base_oid

        _out, _err, status, _metadata = git_capture(
          path, [ "merge-base", "--is-ancestor", base_oid, head ], allow_exit: [ 0, 1 ]
        )
        return "ancestor" if status.exitstatus == 0
        "divergent"
      end

      def observe_commits(path, base_oid, head, diagnostics)
        return [] unless base_oid && head

        format = "%H%x00%h%x00%s%x00%cI%x1e"
        raw = git_value(
          path,
          [ "log", "--no-show-signature", "--format=#{format}",
            "-n", @limits.fetch(:local_git_commits).to_s, "#{base_oid}..#{head}", "--" ]
        )
        raw.split("\x1e").filter_map do |record|
          oid, short, subject, committed_at = record.sub(/\A\n/, "").split("\0", 4)
          next unless valid_oid_or_nil(oid)

          {
            "oid" => oid.downcase, "short_oid" => short.to_s[0, 16],
            "subject" => safe_text(subject, 512),
            "committed_at" => valid_time_or_nil(committed_at.to_s.strip)
          }
        end
      rescue SourceError => e
        diagnostics << e.diagnostic
        []
      end

      def observe_tracking(path, branch, head, diagnostics)
        ref = "refs/remotes/origin/#{branch}"
        out, _err, status, _metadata = git_capture(
          path, [ "rev-parse", "--verify", "--quiet", ref ], allow_exit: [ 0, 1 ]
        )
        return { "state" => "not_observed", "tracking_oid" => nil,
                 "ahead" => nil, "behind" => nil } if status.exitstatus == 1

        tracking = valid_oid_or_nil(out.strip)
        unless tracking
          diagnostics << diagnostic("tracking_ref_invalid", nil, source: "local_git")
          return { "state" => "unavailable", "tracking_oid" => nil,
                   "ahead" => nil, "behind" => nil }
        end
        counts = git_value(path, [ "rev-list", "--left-right", "--count", "#{tracking}...#{head}" ])
        behind, ahead = counts.split.map { |value| Integer(value, exception: false) }
        unless behind && ahead
          diagnostics << diagnostic("tracking_counts_invalid", nil, source: "local_git")
          return { "state" => "unavailable", "tracking_oid" => tracking,
                   "ahead" => nil, "behind" => nil }
        end
        state = if ahead.zero? && behind.zero?
          "pushed"
        elsif ahead.positive? && behind.zero?
          "unpushed"
        elsif ahead.zero? && behind.positive?
          "behind"
        else
          "divergent"
        end
        { "state" => state, "tracking_oid" => tracking, "ahead" => ahead, "behind" => behind }
      rescue SourceError => e
        diagnostics << e.diagnostic
        { "state" => "unavailable", "tracking_oid" => nil, "ahead" => nil, "behind" => nil }
      end

      def read_pr(pointer, diagnostics)
        path = File.join(@task.folder.to_s, "pr.md")
        return missing_pr unless File.exist?(path)

        result = BoundedReader.new(root: @task.folder).read(
          "pr.md", max_bytes: @limits.fetch(:github_pr_text_bytes)
        )
        diagnostics << cap_diagnostic(
          "github_pr_text_bytes", @limits.fetch(:github_pr_text_bytes), result.bytes
        ) if result.truncated
        if result.binary
          diagnostics << diagnostic("pr_document_binary")
          return missing_pr.merge("state" => "unavailable")
        end
        source = result.content
        frontmatter, body = parse_pr_document(source, diagnostics)
        url = frontmatter["pr_url"] || frontmatter["url"]
        parsed = Hive::Gh.parse_pull_request_url(url)
        repository = parsed && "#{parsed.fetch('host')}/#{parsed.fetch('repository')}"
        number = parsed && parsed.fetch("number")
        declared_number = Integer(frontmatter["pr_number"], exception: false)
        head = valid_oid_or_nil(
          frontmatter["head_oid"] || frontmatter["head_sha"] || frontmatter["headRefOid"]
        )
        conflicts = []
        conflicts << "repository" if repository && pointer["repository"] && repository != pointer["repository"]
        conflicts << "number" if declared_number && number && declared_number != number
        diagnostics.concat(conflicts.map { |field| diagnostic("pr_#{field}_mismatch") })
        title = frontmatter["title"].to_s.strip
        title = body[/^#\s+(.+)$/, 1].to_s.strip if title.empty?
        state = if conflicts.any?
          "conflicting"
        elsif parsed
          result.truncated ? "partial" : "current"
        else
          "partial"
        end
        diagnostics << diagnostic("pr_identity_missing") unless parsed
        {
          "state" => state,
          "reference" => "pr.md",
          "url" => parsed && parsed.fetch("url"),
          "repository" => repository,
          "number" => number,
          "declared_head_oid" => head,
          "title" => safe_text(title, 4 * 1024),
          "body" => safe_text(body, @limits.fetch(:github_pr_text_bytes)),
          "truncated" => result.truncated,
          "conflicts" => conflicts
        }
      rescue SourceError => e
        diagnostics << e.diagnostic
        missing_pr.merge("state" => "unavailable")
      end

      def parse_pr_document(source, diagnostics)
        match = source.match(Hive::Gh::FRONTMATTER_DELIMITER)
        return [ {}, source ] unless match

        keys = match[1].lines.filter_map do |line|
          line[/\A([A-Za-z_][A-Za-z0-9_]*):(?:\s|$)/, 1]
        end
        if keys.tally.any? { |_key, count| count > 1 }
          diagnostics << diagnostic("pr_frontmatter_duplicate_keys")
          return [ {}, source.sub(match[0], "") ]
        end
        parsed = YAML.safe_load(
          match[1], permitted_classes: [], permitted_symbols: [], aliases: false
        )
        unless parsed.is_a?(Hash)
          diagnostics << diagnostic("pr_frontmatter_invalid")
          return [ {}, source.sub(match[0], "") ]
        end
        [ parsed.transform_keys(&:to_s), source.sub(match[0], "") ]
      rescue Psych::Exception
        diagnostics << diagnostic("pr_frontmatter_invalid")
        [ {}, source.sub(match[0], "") ]
      end

      def refresh_identity(pointer, local, pr, diagnostics)
        return nil unless pointer["identity_state"] == "current"
        return nil unless local["state"] == "current" && local["head_oid"]
        return nil unless pr["state"] == "current" && pr["number"] && pr["repository"]
        return nil unless pointer["repository"] == pr["repository"]

        {
          "repository" => pointer.fetch("repository"),
          "number" => pr.fetch("number"),
          "expected_head" => local.fetch("head_oid")
        }
      ensure
        if pr["state"] == "conflicting"
          diagnostics << diagnostic("refresh_identity_conflicting")
        end
      end

      def panel_state(pointer, local, pr, remote, diagnostics)
        return "conflicting" if pr["state"] == "conflicting" ||
                                local["base_state"] == "divergent" ||
                                local.dig("push", "state") == "divergent" ||
                                remote.dig("observation", "head_matches") == false ||
                                remote_base_conflicting?(pointer, remote)
        return "unavailable" if local["state"] == "unavailable"
        return "stale" if remote["state"] == "stale" && diagnostics.empty?
        return "current" if pointer["identity_state"] == "current" &&
                            local["state"] == "current" && pr["state"] == "current" &&
                            remote["state"] == "current" && diagnostics.empty?

        "partial"
      end

      def publication_state(local, pr, remote)
        return "local_unavailable" if local["state"] == "unavailable"
        return "local_divergent" if local["base_state"] == "divergent" ||
                                    local.dig("push", "state") == "divergent"
        return "not_configured" if pr["state"] == "missing"
        return "identity_conflicting" if pr["state"] == "conflicting"
        return "local_unpushed" if local.dig("push", "state") == "unpushed"
        return "local_behind" if local.dig("push", "state") == "behind"
        unless remote["observation"]
          remote_reason = Array(remote["diagnostics"]).first&.fetch("reason", nil)
          return "remote_rate_limited" if remote_reason == "rate_limited"
          return "remote_unauthenticated" if remote_reason == "unauthenticated"
          return "remote_pr_missing" if remote_reason == "pull_request_missing"
          return "remote_failed" if remote["refresh_state"] == "failed"

          return "not_observed"
        end

        observation = remote.fetch("observation")
        return "remote_head_divergent" if observation["head_matches"] == false
        if local["base_branch"] && observation["base_branch"].to_s != "" &&
           observation["base_branch"].to_s != local["base_branch"].to_s
          return "remote_base_divergent"
        end
        return "merged_head_deleted" if observation["state"] == "MERGED" &&
                                        observation["head_branch_present"] == false
        return "remote_branch_deleted" if observation["head_branch_present"] == false
        return "merged" if observation["state"] == "MERGED"
        return "closed" if observation["state"] == "CLOSED"
        return "remote_partial" if observation["state"] == "UNKNOWN"
        return "draft" if observation["is_draft"]

        checks = Array(observation["checks"])
        return "checks_partial" if observation["checks_truncated"]
        return "checks_failing" if checks.any? do |check|
          %w[FAILURE CANCELLED TIMED_OUT ACTION_REQUIRED STARTUP_FAILURE STALE].include?(
            check["conclusion"].to_s.upcase
          )
        end
        return "checks_pending" if checks.any? do |check|
          !%w[COMPLETED SUCCESS NEUTRAL SKIPPED].include?(
            check["status"].to_s.upcase
          ) || check["conclusion"].to_s.empty?
        end
        return "review_required" if observation["review_decision"] == "REVIEW_REQUIRED"
        return "changes_requested" if observation["review_decision"] == "CHANGES_REQUESTED"

        "open"
      end

      def remote_base_conflicting?(pointer, remote)
        observed = remote.dig("observation", "base_branch")
        pointer["base_branch"] && observed && !observed.empty? && observed != pointer["base_branch"]
      end

      def panel(state:, local:, pr:, remote:, publication_state:, diagnostics:,
                refresh_identity:)
        {
          "state" => state,
          "records" => [
            { "kind" => "local", "value" => local },
            { "kind" => "pull_request", "value" => pr },
            { "kind" => "remote", "value" => remote }
          ],
          "local" => local, "pull_request" => pr, "remote" => remote,
          "publication_state" => publication_state,
          "refresh" => {
            "eligible" => !refresh_identity.nil?,
            "reason" => refresh_identity ? nil : "identity_unavailable",
            "identity" => refresh_identity
          },
          "diagnostics" => diagnostics.uniq,
          "truncated" => diagnostics.any? { |row| row["reason"] == "limit_exhausted" }
        }
      end

      def git_value(path, args)
        out, _err, _status, _metadata = git_capture(path, args)
        safe_text(out, out.bytesize)
      end

      def git_capture(path, args, allow_exit: [ 0 ])
        remaining_time = @deadline - @monotonic_clock.call
        if remaining_time <= 0
          raise SourceError.new(
            source: "local_git", reason: "limit_exhausted",
            details: {
              "cap" => "local_git_deadline_seconds",
              "limit" => @limits.fetch(:local_git_deadline_seconds)
            }
          )
        end
        if @remaining_bytes <= 0
          raise SourceError.new(
            source: "local_git", reason: "limit_exhausted",
            details: {
              "cap" => "local_git_bytes", "limit" => @limits.fetch(:local_git_bytes),
              "observed_bytes" => @limits.fetch(:local_git_bytes)
            }
          )
        end
        git = Hive::InvokedBinary.which("git")
        raise SourceError.new(source: "local_git", reason: "git_missing") unless git

        argv = [
          git, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
          "-c", "diff.external=", "-c", "core.pager=cat", "-c", "log.showSignature=false",
          "-C", path, *args
        ]
        out, err, status, metadata = @runner.call(
          argv, timeout_sec: remaining_time,
          max_bytes: @remaining_bytes
        )
        observed = out.to_s.bytesize + err.to_s.bytesize
        if observed > @remaining_bytes || metadata.to_h.values_at(
          :stdout_truncated, :stderr_truncated
        ).any?
          @remaining_bytes = 0
          raise SourceError.new(
            source: "local_git", reason: "limit_exhausted",
            details: {
              "cap" => "local_git_bytes", "limit" => @limits.fetch(:local_git_bytes),
              "observed_bytes" => observed
            }
          )
        end
        @remaining_bytes -= observed
        unless allow_exit.include?(status.exitstatus)
          raise SourceError.new(
            source: "local_git", reason: "git_failed",
            message: scrub_paths("git exited #{status.exitstatus}: #{safe_text(err, 4 * 1024)}")
          )
        end
        [ out.to_s, err.to_s, status, metadata ]
      rescue SourceError
        raise
      rescue StandardError => e
        raise SourceError.new(source: "local_git", reason: "git_failed", message: e.class.name)
      end

      def run_command(argv, timeout_sec:, max_bytes:)
        stdout_r, stdout_w = IO.pipe
        stderr_r, stderr_w = IO.pipe
        stderr_limit = max_bytes > 1 ? [ 16 * 1024, [ max_bytes / 4, 1 ].max ].min : 0
        stdout_limit = max_bytes - stderr_limit
        pid = Process.spawn(
          {
            "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL,
            "GIT_OPTIONAL_LOCKS" => "0", "GIT_TERMINAL_PROMPT" => "0",
            "GIT_PAGER" => "cat", "LC_ALL" => "C",
            "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil,
            "BUNDLE_BIN_PATH" => nil, "BUNDLER_SETUP" => nil,
            "BUNDLER_VERSION" => nil, "RUBYGEMS_GEMDEPS" => nil,
            "GEM_HOME" => nil, "GEM_PATH" => nil
          },
          *argv, pgroup: true, in: File::NULL, out: stdout_w, err: stderr_w
        )
        stdout_w.close
        stderr_w.close
        out_reader = Thread.new { read_stream(stdout_r, stdout_limit) }
        err_reader = Thread.new { read_stream(stderr_r, stderr_limit) }
        status = wait_for_process(pid, timeout_sec, [ out_reader, err_reader ])
        out, out_truncated = out_reader.value
        err, err_truncated = err_reader.value
        [
          out, err, Status.new(success?: status.success?, exitstatus: status.exitstatus),
          { stdout_truncated: out_truncated, stderr_truncated: err_truncated }
        ]
      rescue Errno::ENOENT
        raise SourceError.new(source: "local_git", reason: "git_missing")
      ensure
        [ stdout_w, stderr_w, stdout_r, stderr_r ].each do |io|
          io&.close unless io&.closed?
        rescue IOError
          nil
        end
      end

      def read_stream(io, max_bytes)
        bytes = +"".b
        truncated = false
        loop do
          chunk = io.readpartial(16 * 1024)
          available = max_bytes - bytes.bytesize
          bytes << chunk.byteslice(0, available) if available.positive?
          truncated ||= chunk.bytesize > [ available, 0 ].max
        end
      rescue EOFError, IOError
        [ bytes, truncated ]
      end

      def wait_for_process(pid, timeout_sec, readers)
        deadline = @monotonic_clock.call + timeout_sec
        status = nil
        loop do
          waited = Process.waitpid2(pid, Process::WNOHANG) unless status
          status = waited[1] if waited
          return status if status && readers.none?(&:alive?)
          break if @monotonic_clock.call >= deadline

          sleep POLL_INTERVAL
        end
        terminate_group(pid)
        raise SourceError.new(
          source: "local_git", reason: "limit_exhausted",
          details: {
            "cap" => "local_git_deadline_seconds",
            "limit" => @limits.fetch(:local_git_deadline_seconds)
          }
        )
      end

      def terminate_group(pid)
        Process.kill("TERM", -pid)
        deadline = @monotonic_clock.call + 0.5
        loop do
          waited = Process.waitpid2(pid, Process::WNOHANG)
          return waited[1] if waited
          break if @monotonic_clock.call >= deadline

          sleep POLL_INTERVAL
        end
        Process.kill("KILL", -pid)
        Process.waitpid2(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def unavailable_local
        {
          "state" => "unavailable", "repository" => @expected_repository,
          "branch" => nil, "expected_branch" => @task.slug.to_s,
          "base_branch" => nil, "base_oid" => nil, "observed_base_oid" => nil,
          "head_oid" => nil,
          "base_state" => "unavailable", "dirty" => nil, "commits" => [],
          "commits_truncated" => false,
          "push" => { "state" => "unavailable", "tracking_oid" => nil,
                      "ahead" => nil, "behind" => nil }
        }
      end

      def missing_pr
        {
          "state" => "missing", "reference" => "pr.md", "url" => nil,
          "repository" => nil, "number" => nil, "declared_head_oid" => nil,
          "title" => "", "body" => "", "truncated" => false, "conflicts" => []
        }
      end

      def unavailable_remote(reason)
        {
          "state" => "unavailable", "cache_state" => "unavailable",
          "refresh_state" => "idle", "observation" => nil,
          "observed_at" => nil, "refreshed_at" => nil, "retry_at" => nil,
          "diagnostics" => [ diagnostic(reason, nil, source: "publication_cache") ]
        }
      end

      def canonical_repository(value)
        return nil if value.to_s.strip.empty?

        host, owner, name = value.to_s.strip.downcase.split("/", 3)
        Hive::Gh::RepositoryIdentity.validated_github_host(host)
        slug = Hive::Gh::RepositoryIdentity.validated_repository_slug("#{owner}/#{name}")
        "#{host}/#{slug.downcase}"
      rescue Hive::GhError
        nil
      end

      def valid_branch_or_nil(value)
        Hive::GitRef.validate_branch_name(value)
      rescue ArgumentError
        nil
      end

      def valid_oid_or_nil(value)
        oid = value.to_s.strip.downcase
        oid.match?(OID_RE) ? oid : nil
      end

      def valid_time_or_nil(value)
        Time.iso8601(value.to_s).utc.iso8601(6)
      rescue ArgumentError
        nil
      end

      def safe_text(value, bytes)
        source = value.to_s.b.byteslice(0, [ bytes, 0 ].max).to_s
        Hive::SecretPatterns.redact(source.force_encoding(Encoding::UTF_8).scrub(""))
      end

      def scrub_paths(value)
        value.to_s.gsub(
          %r{(?<![A-Za-z0-9])(?:/[A-Za-z0-9._~+@%=-]+)+(?:/[A-Za-z0-9._~+@%=-]*)?},
          "[REDACTED:path]"
        ).gsub(%r{(?<![A-Za-z0-9])[A-Za-z]:[\\/](?:[^\s:]+[\\/]?)+}, "[REDACTED:path]")
      end

      def diagnostic(reason, message = nil, source: "publication", **details)
        {
          "source" => source, "reason" => reason,
          "message" => scrub_paths(Hive::SecretPatterns.redact(message.to_s)),
          "details" => details.transform_keys(&:to_s)
        }
      end

      def cap_diagnostic(cap, limit, observed)
        diagnostic(
          "limit_exhausted", nil, source: "publication",
          cap: cap, limit: limit, observed_bytes: observed
        ).merge("cap" => cap, "limit" => limit, "observed" => observed)
      end
    end
  end
end
