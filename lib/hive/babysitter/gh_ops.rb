require "time"
require "hive/gh"

module Hive
  module Babysitter
    module GhOps
      GIVE_UP_LABEL = "babysitter/needs-human".freeze

      # Outcome of an auto-rebase attempt. `status` is one of :success
      # (fetch + rebase clean), :conflict (rebase failed and was aborted —
      # left for a human), or :failure (some other git error, e.g. the
      # fetch failed). `success?` and `conflict?` keep call sites readable.
      RebaseResult = Struct.new(:status, :stdout, :stderr, keyword_init: true) do
        def success?
          status == :success
        end

        def conflict?
          status == :conflict
        end
      end

      module_function

      # Force-push the worktree's HEAD to origin/<branch>. When `expected_oid`
      # is given (the PR head's current OID), use the explicit lease form
      # `--force-with-lease=<branch>:<oid>` — this protects against clobbering
      # a concurrent push WITHOUT needing a local remote-tracking ref for the
      # branch (the bare `--force-with-lease` form fails with "stale info"
      # when no such ref exists). When absent, fall back to the bare form.
      def force_push_with_lease(worktree, branch, cfg:, dry_run:, expected_oid: nil)
        return result(true, "[dry-run] git push skipped", "") if dry_run

        lease = expected_oid.to_s.empty? ? "--force-with-lease" : "--force-with-lease=#{branch}:#{expected_oid}"
        out, err, status = Hive::Gh.capture3(
          "git", "push", lease, "origin", "HEAD:#{branch}",
          chdir: worktree,
          cfg: cfg
        )
        result(status.success?, out, err)
      end

      # Rebase the worktree's HEAD onto origin/<base_ref> so a green-but-
      # BEHIND PR becomes up-to-date with its base. Fetches the base first
      # (a stale local origin/<base> would rebase onto the wrong commit).
      # A rebase that hits conflicts is aborted (best-effort) and reported
      # as :conflict so the caller leaves it for a human rather than
      # force-pushing a half-rebased branch.
      def rebase_onto_base(worktree, base_ref, cfg:, dry_run:)
        return rebase_result(:success, "[dry-run] git rebase skipped", "") if dry_run

        fetch_out, fetch_err, fetch_status = Hive::Gh.capture3(
          "git", "fetch", "origin", base_ref,
          chdir: worktree,
          cfg: cfg
        )
        return rebase_result(:failure, fetch_out, fetch_err) unless fetch_status.success?

        out, err, status = Hive::Gh.capture3(
          "git", "rebase", "origin/#{base_ref}",
          chdir: worktree,
          cfg: cfg
        )
        return rebase_result(:success, out, err) if status.success?

        abort_out, abort_err, _abort_status = Hive::Gh.capture3(
          "git", "rebase", "--abort",
          chdir: worktree,
          cfg: cfg
        )
        rebase_result(:conflict, "#{out}\n#{abort_out}", "#{err}\n#{abort_err}")
      end

      def add_label(worktree, pr_number, label, cfg:, dry_run:)
        return result(true, "[dry-run] gh pr edit --add-label skipped", "") if dry_run
        return result(true, "already labelled", "") if pr_has_label?(worktree, pr_number, label, cfg: cfg)

        out, err, status = Hive::Gh.capture3(
          "gh", "pr", "edit", pr_number.to_s, "--add-label", label,
          chdir: worktree,
          cfg: cfg
        )
        result(status.success?, out, err)
      end

      def post_pr_comment(worktree, pr_number, body, cfg:, dry_run:)
        return result(true, "[dry-run] gh pr comment skipped", "") if dry_run
        return result(true, "recent give-up comment already exists", "") if recent_give_up_comment?(worktree, pr_number, cfg: cfg)

        stamped = stamp_comment(body)
        out, err, status = Hive::Gh.capture3(
          "gh", "pr", "comment", pr_number.to_s, "--body", stamped,
          chdir: worktree,
          cfg: cfg
        )
        result(status.success?, out, err)
      end

      def rerun_ci(worktree, run_id, cfg:, dry_run:)
        return result(true, "[dry-run] gh run rerun skipped", "") if dry_run

        out, err, status = Hive::Gh.capture3(
          "gh", "run", "rerun", run_id.to_s,
          chdir: worktree,
          cfg: cfg
        )
        result(status.success?, out, err)
      end

      def pr_has_label?(worktree, pr_number, label, cfg:)
        out, _err, status = Hive::Gh.capture3(
          "gh", "pr", "view", pr_number.to_s, "--json", "labels",
          chdir: worktree,
          cfg: cfg
        )
        return false unless status.success?

        doc = JSON.parse(out)
        Array(doc["labels"]).any? { |entry| entry.is_a?(Hash) && entry["name"].to_s.casecmp(label).zero? }
      rescue JSON::ParserError
        false
      end

      GIVE_UP_WINDOW_SEC = 3600
      GIVE_UP_MARKER_PREFIX = "<!-- hive-babysitter:give-up:".freeze
      GIVE_UP_MARKER_SUFFIX = " -->".freeze
      GIVE_UP_MARKER_REGEX = /<!-- hive-babysitter:give-up:(?<ts>[^ ]+) -->/

      def recent_give_up_comment?(worktree, pr_number, cfg:, now: Time.now.utc)
        out, _err, status = Hive::Gh.capture3(
          "gh", "pr", "view", pr_number.to_s, "--json", "comments",
          chdir: worktree,
          cfg: cfg
        )
        return false unless status.success?

        doc = JSON.parse(out)
        cutoff = now - GIVE_UP_WINDOW_SEC
        Array(doc["comments"]).any? do |entry|
          next false unless entry.is_a?(Hash)

          marker_ts = extract_give_up_marker_timestamp(entry["body"].to_s)
          marker_ts && marker_ts >= cutoff
        end
      rescue JSON::ParserError
        false
      end

      def stamp_comment(body, now: Time.now.utc)
        "#{body}\n\n#{give_up_marker(now: now)}"
      end

      def give_up_marker(now: Time.now.utc)
        "#{GIVE_UP_MARKER_PREFIX}#{now.iso8601}#{GIVE_UP_MARKER_SUFFIX}"
      end

      def extract_give_up_marker_timestamp(body)
        match = body.match(GIVE_UP_MARKER_REGEX)
        return nil unless match

        Time.iso8601(match[:ts])
      rescue ArgumentError
        nil
      end

      def result(success, stdout, stderr)
        Hive::Gh::PushResult.new(success: success, stdout: stdout.to_s, stderr: stderr.to_s)
      end

      def rebase_result(status, stdout, stderr)
        RebaseResult.new(status: status, stdout: stdout.to_s, stderr: stderr.to_s)
      end
    end
  end
end
