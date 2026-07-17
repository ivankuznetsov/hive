require "time"
require "set"
require "hive/config"
require "hive/gh"
require "hive/stages"
require "hive/workflows"
require "hive/worktree"
require "hive/babysitter/events"
require "hive/babysitter/job_runner"
require "hive/babysitter/job_store"
require "hive/babysitter/status_writer"
require "hive/babysitter/pr_fixer"

module Hive
  module Babysitter
    module ProjectTick
      module_function

      def run(project_entry, dry_run:, logger:, inflight:, job_store: nil)
        started = Time.now
        # Re-read config here (rather than accepting the dispatcher's cached
        # cfg) so a per-tick edit to babysitter.* takes effect on the next
        # tick without restarting the daemon.
        cfg = Hive::Config.load(project_entry.fetch("path"))
        unless cfg.dig("babysitter", "enabled") == true
          logger.event(:project_skipped, project: project_entry["name"], reason: "babysitter_disabled")
          return { total: 0, fixed: 0, untouched: 0, needs_human: 0 }
        end

        job_store ||= Hive::Babysitter::JobStore.new(project_root: project_entry.fetch("path"))
        registered_jobs = job_store.jobs
        active_jobs = registered_jobs.select { |job| job.fetch("state") == "active" }
        job_outcomes = active_jobs.map do |job|
          begin
            Hive::Babysitter::JobRunner.run(
              job: job, store: job_store, project: project_entry, cfg: cfg,
              dry_run: dry_run, logger: logger, inflight: inflight
            )
          rescue StandardError => e
            logger.event(:fatal, project: project_entry["name"], job_id: job["job_id"],
                         message: "JobRunner raised: #{e.class}: #{e.message}")
            :failure
          end
        end

        prs = Hive::Gh.list_open_prs(project_entry.fetch("path"), cfg: cfg)
        Hive::Babysitter::Events.emit(
          project: project_entry,
          action: "list-prs",
          outcome: "success",
          duration_ms: duration_ms(started),
          count: prs.size
        )

        registered_numbers = registered_jobs.map { |job| job.dig("identity", "pr_number") }.to_set
        discovery_prs = prs.reject { |pr| registered_numbers.include?(pr["number"].to_i) }
        owned_branches = pipeline_owned_branches(project_entry)
        selected = select_prs(discovery_prs, project_entry, cfg, inflight, owned_branches)
        summary = tally_job_outcomes(job_outcomes)
        summary[:total] += selected.size
        selected.each do |pr|
          outcome =
            begin
              Hive::Babysitter::PrFixer.run(
                pr,
                project_entry,
                cfg,
                dry_run: dry_run,
                logger: logger,
                inflight: inflight
              )
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

          case outcome
          when :success, :rebased then summary[:fixed] += 1
          when :already_green, :noop, :dry_run then summary[:untouched] += 1
          when :give_up, :failure, :timeout, :budget_exhausted, :fork_pr, :rebase_conflict then summary[:needs_human] += 1
          end
        end

        Hive::Babysitter::StatusWriter.append(
          project: project_entry,
          pr_count: summary[:total],
          fixed: summary[:fixed],
          untouched: summary[:untouched],
          needs_human: summary[:needs_human]
        )
        summary
      rescue Hive::GhError => e
        Hive::Babysitter::Events.emit(
          project: project_entry,
          action: "list-prs",
          outcome: "gh-error",
          duration_ms: duration_ms(started),
          message: e.message
        )
        logger.event(:fatal, project: project_entry["name"], message: "gh pr list failed: #{e.message}")
        { total: 0, fixed: 0, untouched: 0, needs_human: 0 }
      rescue Hive::Babysitter::JobStore::Error => e
        Hive::Babysitter::Events.emit(
          project: project_entry, action: "blocked", outcome: "unavailable",
          duration_ms: duration_ms(started), message: e.message.to_s.gsub(/\s+/, " ")[0, 300]
        )
        logger.event(:fatal, project: project_entry["name"], message: "babysitter job registry unavailable: #{e.message}")
        { total: 0, fixed: 0, untouched: 0, needs_human: 1 }
      end

      def select_prs(prs, project_entry, cfg, inflight, owned_branches = Set.new)
        ignored = Array(cfg.dig("babysitter", "labels_ignore")).map { |label| label.to_s.downcase }
        limit = cfg.dig("babysitter", "max_concurrent_prs").to_i
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
            )
            next
          end

          if pr["isDraft"] == true
            Hive::Babysitter::Events.emit(
              project: project_entry,
              pr: number,
              action: "skipped",
              outcome: "draft_pr"
            )
            next
          end

          labels = Array(pr["labels"]).filter_map { |entry| entry.is_a?(Hash) ? entry["name"] : entry }
          if (labels.map { |label| label.to_s.downcase } & ignored).any?
            Hive::Babysitter::Events.emit(
              project: project_entry,
              pr: number,
              action: "skipped",
              outcome: "label_ignored"
            )
            next
          end
          next if inflight.include?(inflight_key(project_entry, number))

          pr
        end.sort_by { |pr| [ selection_priority(pr), parse_time(pr["updatedAt"]) ] }.first(limit)
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

      def tally_job_outcomes(outcomes)
        summary = { total: outcomes.size, fixed: 0, untouched: 0, needs_human: 0 }
        outcomes.each do |outcome|
          case outcome
          when :head_changed then summary[:fixed] += 1
          when :needs_human, :failure then summary[:needs_human] += 1
          else summary[:untouched] += 1
          end
        end
        summary
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
