require "json"
require "time"
require "set"
require "hive/config"
require "hive/gh"
require "hive/markers"
require "hive/stages"
require "hive/workflows"
require "hive/worktree"
require "hive/babysitter/events"
require "hive/babysitter/status_writer"
require "hive/babysitter/pr_fixer"

module Hive
  module Babysitter
    module ProjectTick
      module_function

      EXECUTION_LOCK_NAME = "babysitter-execution.lock".freeze
      OUTCOME_CLASSES = {
        eligible: :runnable, capacity_deferred: :runnable,
        give_up: :operator, fork_pr: :operator, rebase_conflict: :operator,
        failure: :retry, timeout: :retry, budget_exhausted: :retry,
        pipeline_owned: :pipeline_owned, inflight: :inflight,
        success: :observed, rebased: :observed, already_green: :observed,
        noop: :observed, dry_run: :observed
      }.freeze

      def run(project_entry, dry_run:, logger:, inflight:, admission_open: -> { true },
              observe_only: false, detailed: false)
        started = Time.now
        unless admission_open?(admission_open)
          return report(empty_summary.merge(interrupted: true), detailed)
        end

        # Re-read config here (rather than accepting the dispatcher's cached
        # cfg) so a per-tick edit to babysitter.* takes effect on the next
        # tick without restarting the daemon.
        cfg = Hive::Config.load(project_entry.fetch("path"))
        unless cfg.dig("babysitter", "enabled") == true
          logger.event(:project_skipped, project: project_entry["name"], reason: "babysitter_disabled") unless
            observe_only
          return report(empty_summary, detailed)
        end

        prs = Hive::Gh.list_open_prs(project_entry.fetch("path"), cfg: cfg)
        unless observe_only
          Hive::Babysitter::Events.emit(
            project: project_entry,
            action: "list-prs",
            outcome: "success",
            duration_ms: duration_ms(started),
            count: prs.size
          )
        end
        return report(empty_summary.merge(interrupted: true), detailed) unless
          admission_open?(admission_open)

        owned_branches = pipeline_owned_branches(project_entry)
        observations = []
        eligible = select_prs(
          prs, project_entry, cfg, inflight, owned_branches,
          observations: observations, limit: false, emit_events: !observe_only
        )
        limit = cfg.dig("babysitter", "max_concurrent_prs").to_i
        selected = eligible.first(limit)
        summary = empty_summary
        summary[:prs].concat(observations)
        eligible.drop(limit).each do |pr|
          unless detailed || observe_only
            summary[:prs] << pr_result(pr, :capacity_deferred)
            next
          end

          outcome, status, error = observe_pr(pr, project_entry, cfg)
          record_observation_error(
            summary, error, project_entry: project_entry, pr: pr,
            logger: logger, emit_events: !observe_only
          ) if error
          outcome = :capacity_deferred if outcome == :eligible
          summary[:prs] << pr_result(pr, outcome, status: status)
        end
        if observe_only
          selected.each do |pr|
            outcome, status, error = observe_pr(pr, project_entry, cfg)
            record_observation_error(
              summary, error, project_entry: project_entry, pr: pr,
              logger: logger, emit_events: false
            ) if error
            summary[:prs] << pr_result(pr, outcome, status: status)
          end
          return report(summary, detailed)
        end
        interrupted = false
        selected.each do |pr|
          unless admission_open?(admission_open)
            interrupted = true
            break
          end

          status = nil
          outcome =
            begin
              Hive::Babysitter::PrFixer.run(
                pr,
                project_entry,
                cfg,
                dry_run: dry_run,
                logger: logger,
                inflight: inflight,
                admission_open: admission_open,
                detail_sink: ->(value) { status = value }
              )
            rescue Hive::GhError => e
              record_observation_error(
                summary, e, project_entry: project_entry, pr: pr,
                logger: logger, emit_events: true
              )
              :failure
            rescue StandardError => e
              Hive::Babysitter::Events.emit(
                project: project_entry,
                pr: pr["number"],
                action: "agent-fix",
                outcome: "failure",
                message: "#{e.class}: #{e.message}"
              )
              logger.event(:fatal,
                           project: project_entry["name"],
                           pr: pr["number"],
                           message: "PrFixer raised: #{e.class}: #{e.message}")
              :failure
            end

          if outcome == :shutdown
            interrupted = true
            break
          end

          summary[:total] += 1
          summary[:prs] << pr_result(pr, outcome, status: status)
          case outcome
          when :success, :rebased then summary[:fixed] += 1
          when :already_green, :noop, :dry_run then summary[:untouched] += 1
          when :give_up, :failure, :timeout, :budget_exhausted, :fork_pr, :rebase_conflict then summary[:needs_human] += 1
          end
        end
        summary[:interrupted] = interrupted

        unless interrupted
          Hive::Babysitter::StatusWriter.append(
            project: project_entry,
            pr_count: summary[:total],
            fixed: summary[:fixed],
            untouched: summary[:untouched],
            needs_human: summary[:needs_human]
          )
        end
        report(summary, detailed)
      rescue Hive::GhError => e
        unless observe_only
          Hive::Babysitter::Events.emit(
            project: project_entry,
            action: "list-prs",
            outcome: "gh-error",
            duration_ms: duration_ms(started),
            message: e.message
          )
          logger.event(:fatal, project: project_entry["name"], message: "gh pr list failed: #{e.message}")
        end
        report(
          empty_summary.merge(error: { code: "github_observation_failed", message: e.message }),
          detailed
        )
      end

      def empty_summary
        { total: 0, fixed: 0, untouched: 0, needs_human: 0, prs: [],
          error: nil, interrupted: false }
      end

      def outcome_class(outcome)
        OUTCOME_CLASSES.fetch(outcome.to_sym)
      rescue KeyError
        raise ArgumentError, "unknown babysitter outcome #{outcome.inspect}"
      end

      def report(summary, detailed)
        return summary if detailed

        summary.slice(:total, :fixed, :untouched, :needs_human)
      end

      def admission_open?(predicate)
        predicate.call == true
      rescue StandardError
        false
      end

      def observe_pr(pr, project_entry, cfg)
        outcome, status = Hive::Babysitter::PrFixer.observe(pr, project_entry, cfg)
        [ outcome, status, nil ]
      rescue Hive::GhError => error
        [ :failure, nil, error ]
      end

      def record_observation_error(summary, error, project_entry:, pr:, logger:, emit_events:)
        summary[:error] ||= {
          code: "github_observation_failed", message: error.message
        }
        return unless emit_events

        Hive::Babysitter::Events.emit(
          project: project_entry, pr: pr["number"], action: "list-prs",
          outcome: "gh-error", message: error.message
        )
        logger.event(
          :fatal, project: project_entry["name"], pr: pr["number"],
          message: "PR observation failed: #{error.message}"
        )
      end

      def select_prs(prs, project_entry, cfg, inflight, owned_branches = Set.new,
                     observations: nil, limit: true, emit_events: true)
        ignored = Array(cfg.dig("babysitter", "labels_ignore")).map { |label| label.to_s.downcase }
        prs.filter_map do |pr|
          number = pr["number"]
          # hive-state (git) is the source of truth for ownership: a PR whose
          # branch an active pipeline task still drives must be left alone. The
          # task's worktree is pinned to its own base, so a babysitter rebase +
          # force-push would strand it and the finalize push gate would loop on
          # unpushed_commits. This holds even after finalize flips the PR from
          # draft to ready (the draft flag below only protects pre-finalize).
          if owned_branches.include?(pr["headRefName"].to_s)
            Hive::Babysitter::Events.emit(
              project: project_entry,
              pr: number,
              action: "skipped",
              outcome: "pipeline_owned"
            ) if emit_events
            observations&.push(pr_result(pr, :pipeline_owned))
            next
          end

          if pr["isDraft"] == true
            Hive::Babysitter::Events.emit(
              project: project_entry,
              pr: number,
              action: "skipped",
              outcome: "draft_pr"
            ) if emit_events
            next
          end

          labels = Array(pr["labels"]).filter_map { |entry| entry.is_a?(Hash) ? entry["name"] : entry }
          if (labels.map { |label| label.to_s.downcase } & ignored).any?
            Hive::Babysitter::Events.emit(
              project: project_entry,
              pr: number,
              action: "skipped",
              outcome: "label_ignored"
            ) if emit_events
            next
          end
          if inflight.include?(inflight_key(project_entry, number))
            observations&.push(pr_result(pr, :inflight))
            next
          end

          pr
        end.then { |candidates| fair_order(candidates, project_entry) }.then do |rows|
          limit ? rows.first(cfg.dig("babysitter", "max_concurrent_prs").to_i) : rows
        end
      end

      # Round-robin across open PRs: never-attempted PRs first, then the least
      # recently attempted, then merge-state priority and age. Ordering by
      # priority and age alone let the same persistently red PRs win every
      # tick (one was "fixed" 13 times in six hours) while newer PRs starved.
      def fair_order(candidates, project_entry)
        attempted = last_attempt_times(project_entry)
        candidates.sort_by do |pr|
          [ attempted.fetch(pr["number"].to_i, EPOCH), selection_priority(pr), parse_time(pr["updatedAt"]) ]
        end
      end

      EPOCH = Time.at(0).utc
      ATTEMPT_ACTIONS = %w[agent-fix rebase force-push].freeze
      ATTEMPT_LOG_TAIL_BYTES = 512 * 1024

      # Last fix attempt per PR, from the tail of this project's babysitter
      # event log. A missing or unreadable log means no history.
      def last_attempt_times(project_entry)
        path = File.join(project_entry.fetch("hive_state_path"), "babysitter", "events.jsonl")
        return {} unless File.file?(path)

        tail = File.open(path, "rb") do |file|
          file.seek([ file.size - ATTEMPT_LOG_TAIL_BYTES, 0 ].max)
          file.read
        end
        tail.each_line.with_object({}) do |line, times|
          record = JSON.parse(line)
          next unless record.is_a?(Hash) && ATTEMPT_ACTIONS.include?(record["action"]) && record["pr"]

          times[record["pr"].to_i] = parse_time(record["ts"])
        rescue JSON::ParserError
          next
        end
      rescue SystemCallError, IOError
        {}
      end

      def pr_result(pr, outcome, status: nil)
        result = {
          number: pr.fetch("number").to_i, outcome: outcome.to_sym,
          head_sha: pr["headRefOid"], head_ref: pr["headRefName"], url: pr["url"]
        }
        result[:wait] = "checks_pending" if outcome_class(outcome) == :observed &&
          checks_pending?(status)
        result
      end

      def checks_pending?(status)
        Array(status && status["statusCheckRollup"]).any? do |check|
          next false unless check.is_a?(Hash)

          %w[QUEUED PENDING IN_PROGRESS].include?(check["status"].to_s.upcase) ||
            %w[PENDING EXPECTED].include?(check["state"].to_s.upcase)
        end
      end

      # Branches owned by a task still moving through the pipeline — read from
      # hive-state (the `hive/state` branch) rather than inferred from the PR's
      # GitHub draft flag. Scans every non-terminal stage's task folders and
      # collects each worktree.yml `branch`. A missing/malformed pointer is
      # skipped so a single bad task never aborts the scan (and the babysitter
      # then simply doesn't skip that PR — same as before this guard).
      def pipeline_owned_branches(project_entry)
        hive_state = project_entry["hive_state_path"].to_s
        hive_state = File.join(project_entry.fetch("path"), ".hive-state") if hive_state.empty?

        active_stage_dirs.each_with_object(Set.new) do |stage_dir, branches|
          Dir.glob(File.join(hive_state, "stages", stage_dir, "*")).each do |task_folder|
            next if finalized_awaiting_merge?(stage_dir, task_folder)

            branch = task_branch(task_folder)
            branches << branch if branch
          end
        end
      end

      # Stage dirs a task can still be actively driven from: every stage that
      # has a further pipeline verb (i.e. all but the terminal done stage).
      # Derived from the workflow descriptor so a stage renumber can't strand it.
      def active_stage_dirs
        Hive::Stages::DIRS.select { |stage_dir| Hive::Workflows.verb_advancing_from(stage_dir) }
      end

      # A coding task whose finalize already completed only waits for its PR to
      # merge: the daemon polls (ready_to_archive) and never pushes again, and
      # archive handles a merged PR whatever its branch state. Leaving it
      # "owned" stranded a PR whose CI went red after main moved, since the
      # pipeline no longer acts and the babysitter deferred to it.
      FINALIZE_STAGE_DIR = "8-finalize".freeze # coding-scoped: finalized coding PRs await merge only
      FINALIZE_STATE_FILE = "pr.md".freeze

      def finalized_awaiting_merge?(stage_dir, task_folder)
        return false unless stage_dir == FINALIZE_STAGE_DIR

        state_file = File.join(task_folder, FINALIZE_STATE_FILE)
        File.file?(state_file) && Hive::Markers.current(state_file).name == :complete
      rescue StandardError
        false
      end

      # The branch a task's worktree.yml records, or nil when the task has no
      # worktree yet (pre-execute) or the pointer is missing/unreadable.
      def task_branch(task_folder)
        return nil unless File.directory?(task_folder)

        pointer = Hive::Worktree.read_pointer(task_folder)
        branch = pointer && pointer["branch"].to_s.strip
        branch.nil? || branch.empty? ? nil : branch
      rescue StandardError
        nil
      end

      def selection_priority(pr)
        case pr["mergeStateStatus"].to_s.upcase
        when "DIRTY", "BLOCKED", "UNSTABLE"
          0
        when "BEHIND", "UNKNOWN"
          1
        else
          2
        end
      end

      def inflight_key(project_entry, pr_number)
        [ project_entry.fetch("name"), pr_number.to_i ]
      end

      def parse_time(value)
        Time.parse(value.to_s)
      rescue ArgumentError
        Time.at(0)
      end

      def duration_ms(started)
        ((Time.now - started) * 1000).to_i
      end
    end
  end
end
