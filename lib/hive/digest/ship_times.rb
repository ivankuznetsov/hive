require "open3"
require "time"
require "hive/git_ops"

module Hive
  module Digest
    class ShipTimes
      PRIMARY_ACTION = "pr_finalized".freeze
      FALLBACK_ACTION = "archived".freeze

      def shipped_at(hive_state_path:, slug:)
        commits = log_commits(hive_state_path: hive_state_path, slug: slug)
        selected = select_commit(commits, slug)
        selected && Time.parse(selected.fetch(:committed_at))
      end

      private

      def log_commits(hive_state_path:, slug:)
        # `slug` is passed as its own argv element (not interpolated into the
        # `--grep=<slug>` token) so static analysers don't read it as a shell
        # injection: this is array-form Open3 (no shell) and `-F` makes the grep
        # a fixed string, so `slug` can neither inject a command nor a regex.
        out, err, status = Open3.capture3(
          "git", "-C", hive_state_path, "log", Hive::GitOps::HIVE_BRANCH,
          "--format=%cI%x00%s", "-F", "--grep", slug
        )
        unless status.success?
          raise Hive::GitError,
                "git log #{Hive::GitOps::HIVE_BRANCH} failed for #{slug}: #{err.strip.empty? ? out : err}"
        end

        out.each_line.filter_map do |line|
          committed_at, subject = line.chomp.split("\0", 2)
          next if committed_at.to_s.empty? || subject.to_s.empty?
          next unless subject.include?("/#{slug} ")

          { committed_at: committed_at, subject: subject }
        end
      end

      def select_commit(commits, slug)
        matching_action(commits, slug, PRIMARY_ACTION) ||
          matching_action(commits, slug, FALLBACK_ACTION) ||
          matching_approval_to_done(commits, slug)
      end

      def matching_action(commits, slug, action)
        # Match the newest commit whose subject ends with "/<slug> <action>".
        # The previous exact-match `"hive: 9-done/<slug> <action>"` tie-break
        # was dead for the PRIMARY pr_finalized action — those commits are
        # written by the 8-finalize stage, never 9-done — and redundant for
        # the archived fallback (the end_with? match already resolves it).
        suffix = "/#{slug} #{action}"
        commits.find { |entry| entry[:subject].end_with?(suffix) }
      end

      def matching_approval_to_done(commits, slug)
        commits.find do |entry|
          subject = entry[:subject]
          subject.include?("/#{slug} ") && subject.include?("approve") && subject.include?("-> 9-done")
        end
      end
    end
  end
end
