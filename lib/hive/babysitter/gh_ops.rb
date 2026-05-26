require "time"
require "hive/gh"

module Hive
  module Babysitter
    module GhOps
      GIVE_UP_LABEL = "babysitter/needs-human".freeze

      module_function

      def force_push_with_lease(worktree, branch, cfg:, dry_run:)
        return result(true, "[dry-run] git push skipped", "") if dry_run

        out, err, status = Hive::Gh.capture3(
          "git", "push", "--force-with-lease", "origin", "HEAD:#{branch}",
          chdir: worktree,
          cfg: cfg
        )
        result(status.success?, out, err)
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
        stamped = stamp_comment(body)
        return result(true, "[dry-run] gh pr comment skipped", "") if dry_run
        return result(true, "recent give-up comment already exists", "") if recent_give_up_comment?(worktree, pr_number, cfg: cfg)

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

      def recent_give_up_comment?(worktree, pr_number, cfg:)
        out, _err, status = Hive::Gh.capture3(
          "gh", "pr", "view", pr_number.to_s, "--json", "comments",
          chdir: worktree,
          cfg: cfg
        )
        return false unless status.success?

        marker = give_up_marker
        doc = JSON.parse(out)
        Array(doc["comments"]).any? { |entry| entry.is_a?(Hash) && entry["body"].to_s.include?(marker) }
      rescue JSON::ParserError
        false
      end

      def stamp_comment(body)
        "#{body}\n\n#{give_up_marker}"
      end

      def give_up_marker(now: Time.now.utc)
        "<!-- hive-babysitter:give-up:#{now.strftime('%Y%m%d%H')} -->"
      end

      def result(success, stdout, stderr)
        Hive::Gh::PushResult.new(success: success, stdout: stdout.to_s, stderr: stderr.to_s)
      end
    end
  end
end
