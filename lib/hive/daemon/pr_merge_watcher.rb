require "open3"
require "json"
require "yaml"
require "time"
require "hive/workflows"

module Hive
  module Daemon
    # For tasks at the finalize stage with `:complete`, periodically polls
    # `gh pr view <url> --json state` and tells the dispatcher to fire
    # `hive archive <slug>` once the PR is `MERGED`.
    #
    # Lives in its own object so the main dispatcher tick stays cheap
    # and the polling cadence is independent (default 5 min vs the
    # dispatcher's 30s) — gh CLI calls are slower and rate-limited.
    #
    # State is in-memory:
    #   @pending: Hash<[project, slug], { pr_url, last_polled_at,
    #                                     last_state, failure_count,
    #                                     enqueued_at, hive_state_path,
    #                                     stage }>
    class PrMergeWatcher
      # Derived from the workflow verb map so the artifacts-stage renumber
      # (or any future stage shuffle) re-points the archive command without
      # editing this file. Building the format string at class-load time is
      # safe: `Hive::Workflows::VERBS` is frozen at require time.
      ARCHIVE_FROM_STAGE = Hive::Workflows::VERBS.fetch("archive").fetch(:source).freeze
      ARCHIVE_VERB_TEMPLATE = "hive archive %<slug>s --from #{ARCHIVE_FROM_STAGE} " \
                              "--project %<project>s --json".freeze
      MERGED_PR_RECOVERABLE_ERROR_REASONS = %w[
        git_status_failed
        claude_launch_failed
      ].freeze

      # Backoff schedule for consecutive `gh` failures (network /
      # auth / rate limit). After exhaustion, the watcher drops the
      # entry — operator must `gh auth login` and run `hive archive`
      # manually.
      GH_BACKOFF_SCHEDULE = [ 60, 300, 900 ].freeze
      GH_MAX_FAILURES = GH_BACKOFF_SCHEDULE.size + 2

      def initialize(poll_interval_sec: 300, gh_bin: ENV.fetch("HIVE_GH_BIN", "gh"))
        @poll_interval_sec = poll_interval_sec
        @gh_bin = gh_bin
        @pending = {}
        # Buffer of `{project:, slug:, pr_url:, failure_count:, last_error:}`
        # entries that hit GH_MAX_FAILURES during the most recent #tick.
        # The dispatcher reads this after every tick to emit
        # `:merge_watcher_dropped` logger events — without it, exhausted
        # entries vanished silently and the operator had no signal that
        # the watcher had given up on a merged PR.
        @last_tick_dropped = []
      end

      # Drops that hit GH_MAX_FAILURES during the most recent #tick.
      # Cleared and repopulated on each tick.
      attr_reader :last_tick_dropped

      def enqueue(project:, slug:, task_folder:, hive_state_path: nil, stage: ARCHIVE_FROM_STAGE,
                  error_reason: nil)
        key = [ project, slug ]
        return if @pending.key?(key) # idempotent
        error_reason = normalize_error_reason(error_reason)

        pr_url = read_pr_url(task_folder)
        return if pr_url.nil? || pr_url.empty?

        @pending[key] = {
          pr_url: pr_url,
          last_polled_at: nil,
          next_eligible_at: nil,
          last_state: nil,
          failure_count: 0,
          enqueued_at: Time.now,
          hive_state_path: hive_state_path,
          stage: stage,
          task_folder: task_folder,
          error_reason: error_reason
        }
      end

      # Returns an Array of dispatch hashes — one per task whose PR has
      # become MERGED since the last tick. Caller (Dispatcher) is
      # responsible for actually spawning `hive archive ...` via the
      # supervisor + concurrency controller.
      #
      # Each dispatch hash:
      #   { project:, slug:, stage:, command:, state_file_mtime:,
      #     hive_state_path: }
      def tick(now: Time.now)
        archives = []
        keys_to_drop = []
        @last_tick_dropped = []

        @pending.each do |key, entry|
          # Cadence: respect both the regular poll interval AND any
          # per-entry backoff deadline set after a previous failure.
          # PR-40 follow-up review C3 — without this, GH_BACKOFF_SCHEDULE
          # was advisory only and the watcher hammered `gh` at the
          # regular cadence under outage / rate-limit.
          last = entry[:last_polled_at]
          next if last && (now - last) < @poll_interval_sec

          deadline = entry[:next_eligible_at]
          next if deadline && now < deadline

          state, error = poll_state(entry[:pr_url])
          entry[:last_polled_at] = now

          if error
            entry[:failure_count] += 1
            if entry[:failure_count] >= GH_MAX_FAILURES
              keys_to_drop << key
              project, slug = key
              @last_tick_dropped << {
                project: project, slug: slug,
                pr_url: entry[:pr_url],
                failure_count: entry[:failure_count],
                last_error: error
              }
            else
              # Schedule the next eligible poll using the backoff
              # schedule (60 → 300 → 900 s). Index is failure_count - 1
              # so the first failure waits 60s, the second 300s, etc.
              # Past the schedule's tail we keep the last value until
              # GH_MAX_FAILURES drops the entry.
              idx = [ entry[:failure_count] - 1, GH_BACKOFF_SCHEDULE.size - 1 ].min
              entry[:next_eligible_at] = now + GH_BACKOFF_SCHEDULE[idx]
            end
            next
          end

          # Successful poll resets failure counter and any pending backoff.
          entry[:failure_count] = 0
          entry[:next_eligible_at] = nil
          entry[:last_state] = state

          case state
          when "MERGED"
            project, slug = key
            archives << {
              project: project, slug: slug, stage: entry[:stage],
              command: archive_command(slug: slug, project: project,
                                       error_reason: entry[:error_reason]),
              state_file_mtime: nil,
              hive_state_path: entry[:hive_state_path],
              error_reason: entry[:error_reason]
            }
            keys_to_drop << key
          when "CLOSED"
            # PR was closed without merge. Operator decides what to do
            # (reopen on GitHub or `hive approve --to <stage> --force`
            # backward); the watcher steps out.
            keys_to_drop << key
          end
          # OPEN → keep watching
        end

        keys_to_drop.each { |k| @pending.delete(k) }
        archives
      end

      # Drop an entry by hand (e.g., operator merged outside the daemon
      # or wants to stop watching). Public for the dispatcher to clear
      # after a successful archive dispatch.
      def drop(project:, slug:)
        @pending.delete([ project, slug ])
      end

      def pending_count
        @pending.size
      end

      def watching?(project:, slug:)
        @pending.key?([ project, slug ])
      end

      def state_for(project:, slug:)
        @pending.dig([ project, slug ], :last_state)
      end

      private

      # Read `pr_url` from the task's `pr.md` frontmatter. Falls back
      # to nil on any parse failure — the dispatcher logs and skips.
      def read_pr_url(task_folder)
        pr_md = File.join(task_folder, "pr.md")
        return nil unless File.exist?(pr_md)

        content = File.read(pr_md)
        # Frontmatter is the first --- delimited block.
        if content =~ /\A---\s*\n(.*?)\n---\s*\n/m
          frontmatter = YAML.safe_load(Regexp.last_match(1)) rescue nil
          return frontmatter["pr_url"] if frontmatter.is_a?(Hash) && frontmatter["pr_url"]
        end
        nil
      end

      def normalize_error_reason(reason)
        reason = reason.to_s
        return nil if reason.empty?
        return reason if MERGED_PR_RECOVERABLE_ERROR_REASONS.include?(reason)

        nil
      end

      def archive_command(slug:, project:, error_reason: nil)
        command = format(ARCHIVE_VERB_TEMPLATE, slug: slug, project: project)
        return command unless error_reason

        "#{command} --recover-merged-error-reason #{error_reason}"
      end

      # Returns [state, error]. state is one of "OPEN" / "MERGED" /
      # "CLOSED" / nil; error is non-nil when the gh call failed.
      def poll_state(pr_url)
        out, err, status = Open3.capture3(@gh_bin, "pr", "view", pr_url, "--json", "state")
        unless status.success?
          return [ nil, "gh pr view exit #{status.exitstatus}: #{err.strip}" ]
        end

        doc = JSON.parse(out)
        [ doc["state"], nil ]
      rescue JSON::ParserError => e
        [ nil, "malformed JSON from gh pr view: #{e.message}" ]
      rescue StandardError => e
        [ nil, "#{e.class}: #{e.message}" ]
      end
    end
  end
end
