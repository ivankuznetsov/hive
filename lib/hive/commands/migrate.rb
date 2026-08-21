require "fileutils"
require "open3"
require "time"
require "yaml"
require "hive/atomic_file"
require "hive/config"
require "hive/display_name/generator"
require "hive/git_ops"
require "hive/lock"
require "hive/markers"
require "hive/paths"
require "hive/process_kill"
require "hive/recovery"
require "hive/recovery/migration"
require "hive/repository_identity"
require "hive/stages"
require "hive/task"
require "hive/task_counter"
require "hive/task_meta"
require "hive/workflow_package/managed_store"
require "hive/workflow_package/mutation_lock"
require "hive/workflow_package/task_migrator"
require "hive/workflows"

module Hive
  module Commands
    class Migrate
      # Each entry maps a legacy stage-directory name to its CURRENT
      # canonical name in `Hive::Stages::DIRS`. When the canonical layout
      # shifts (e.g. the 7-artifacts insertion), every entry must re-point
      # at the new index so a long-dormant project still migrates onto the
      # current layout in a single `hive migrate` pass — chaining is not
      # supported (see `Migrate::STAGE_RENAMES` consistency tests).
      STAGE_RENAMES = {
        "5-review" => "6-review", # not-a-stage-ref: legacy migration table
        "6-pr" => "8-finalize", # not-a-stage-ref: legacy migration table
        "7-done" => "9-done", # not-a-stage-ref: legacy migration table
        "7-finalize" => "8-finalize", # not-a-stage-ref: legacy migration table
        "8-done" => "9-done" # not-a-stage-ref: legacy migration table
      }.freeze

      # Legacy `pr` budget/timeout keys are read-through-fallback in
      # Stages::Finalize for one version; this map rewrites them onto
      # the canonical names so the shim has a removal path. New keys
      # win on collision (the canonical was the one the user actually
      # tuned post-migration).
      CONFIG_KEY_RENAMES = {
        %w[budget_usd pr] => %w[budget_usd finalize],
        %w[timeout_sec pr] => %w[timeout_sec finalize]
      }.freeze
      RETIRED_PATROL_CONFIG_KEYS = %w[
        max_tokens_per_cycle
        max_tokens_per_day
        max_tokens_per_agent
        max_agent_spawns_per_cycle
        max_architecture_review_spawns_per_day
        max_architecture_unmetered_spawns_per_day
        max_budget_usd_per_agent
        architecture_budget_multiplier
        fix_budget_multiplier
      ].freeze
      RETIRED_REFACTOR_PATROL_CONFIG_KEYS = %w[min_leverage_score].freeze
      ROOT_REVIEWERS_LINE = /\A(?:reviewers|["']reviewers["'])\s*:/.freeze
      REVIEW_BLOCK_LINE = /\A(?:review|["']review["'])\s*:\s*(?:#.*)?(?:\r?\n)?\z/.freeze

      # Task-folder names follow this slug pattern (see Task::PATH_RE).
      # Any entry under a legacy stage directory that doesn't look like a
      # task slug is left in place — never silently mv'd into the new
      # stage dir. Re-exported here for back-compat with existing callers;
      # `Hive::Stages::SLUG_RE` is the single source of truth shared with
      # `Hive::Commands::Status#detect_legacy_stage_dirs`.
      SLUG_RE = Hive::Stages::SLUG_RE

      def self.restart_daemon_if_running!
        new.send(:restart_daemon_if_running!)
      end

      def initialize(project_path = Dir.pwd, display_name_generator: Hive::DisplayName::Generator,
                     managed_store_factory: Hive::WorkflowPackage::ManagedStore.method(:new),
                     config_loader: Hive::Config.method(:load),
                     global_migration: Hive::Recovery::Migration.method(:ensure!),
                     daemon_restarter: nil)
        @project_path = File.expand_path(project_path)
        @display_name_generator = display_name_generator
        @managed_store_factory = managed_store_factory
        @config_loader = config_loader
        @global_migration = global_migration
        @daemon_restarter = daemon_restarter
      end

      def call
        hive_state = File.join(@project_path, ".hive-state")
        stages = File.join(hive_state, "stages")
        raise Hive::InvalidTaskPath, "not a hive project: #{hive_state}" unless Dir.exist?(stages)

        @global_migration.call
        moved = []
        config_changed = false
        restart_requested = false
        backfilled_count = 0
        recovery_marker_count = 0
        workflow_task_count = 0
        workflow_moved_count = 0
        plan_review_requirement_count = 0
        no_move_message = nil
        begin
          plan = build_migration_plan(stages)
          preflight_collisions!(plan)
          # Retired Patrol keys must be removed before Config.load: the current
          # runtime deliberately has no read-through compatibility for them.
          # Commit this independently valid forward migration before preparing
          # managed tasks, so a later project-specific failure cannot leave a
          # rewritten config uncommitted or require the old schema to recover.
          Hive::Lock.with_commit_lock(hive_state) do
            config_changed = rewrite_legacy_config_keys(hive_state)
            commit_migration(
              hive_state, [], config_only: true
            ) if config_changed
          end
          # Request the restart immediately after the independently committed
          # config rewrite. MigrateAll injects a coalescing restarter; a
          # standalone migration uses the normal best-effort daemon restart.
          # Either path must run before later project-specific work can fail.
          if config_changed
            (@daemon_restarter || method(:restart_daemon_if_running!)).call
            restart_requested = true
          end
          store = @managed_store_factory.call(hive_state)
          project_config = @config_loader.call(@project_path)
          migrator = Hive::WorkflowPackage::TaskMigrator.new(
            hive_state, store: store, cfg: project_config
          )
          prepared = migrator.prepare
          Hive::Workflows::Project.load!(
            @project_path, config: project_config, hive_state_path: hive_state
          )
          workflow_generation = Hive::Task.capture_workflow_generation(
            @project_path, config: project_config
          )
          workflow_migration = nil
          with_store_mutation_lock(store) do
            Hive::Lock.with_commit_lock(hive_state) do
              workflow_migration = prepared.apply do |preview|
                # The managed plan, destinations, task locks, and selected
                # generations are validated before this first legacy write.
                # A removed semantic stage or live managed task therefore
                # cannot leave config or ordinary task folders half-migrated.
                plan.each { |op| FileUtils.mv(op[:src], op[:dst]) }
                moved.concat(plan.map { |op| [ op[:old_stage], op[:new_stage], op[:entry] ] })
                workflow_task_count = preview.task_count
                workflow_moved_count = preview.moved_count

                ensure_current_stage_dirs(stages)
                backfilled_count = backfill_task_ids(stages)
                recovery_marker_count = backfill_recovery_marker_ids(
                  stages, managed_store: store, cfg: project_config,
                  workflow_generation: workflow_generation
                )
                recovery_marker_count += migrate_attributed_dirty_execute_waits(
                  stages, cfg: project_config
                )
                plan_review_requirement_count = backfill_plan_review_requirements(stages)

                if moved.any? || backfilled_count.positive? ||
                   recovery_marker_count.positive? || workflow_task_count.positive? ||
                   plan_review_requirement_count.positive?
                  commit_migration(
                    hive_state, moved, config_only: false,
                    backfilled_count: backfilled_count,
                    recovery_marker_count: recovery_marker_count,
                    workflow_task_count: workflow_task_count,
                    plan_review_requirement_count: plan_review_requirement_count
                  )
                end

                if moved.empty? && (config_changed || backfilled_count.positive? ||
                   recovery_marker_count.positive? || workflow_task_count.positive? ||
                   plan_review_requirement_count.positive?)
                  no_move_message = migration_no_move_message(
                    config_changed: config_changed,
                    backfilled_count: backfilled_count,
                    recovery_marker_count: recovery_marker_count,
                    workflow_task_count: workflow_task_count,
                    workflow_moved_count: workflow_moved_count,
                    plan_review_requirement_count: plan_review_requirement_count
                  )
                elsif moved.empty? && already_migrated?(stages)
                  no_move_message = "hive: migrate found nothing to move (target stage directories look already-migrated)"
                elsif moved.empty?
                  no_move_message = "hive: migrate found nothing to move"
                end
              end
            end
          end
          workflow_migration = prepared.cleanup(workflow_migration)
          commit_managed_workflow_cleanup(hive_state, prepared.operations) if workflow_task_count.positive?
        ensure
          prepared&.close
        end

        display_name_count = backfill_display_names(stages)
        if display_name_count.positive?
          Hive::Lock.with_commit_lock(hive_state) do
            commit_display_name_backfill(hive_state, display_name_count)
          end
        end
        repository_identity = backfill_registered_repository_identity

        if moved.empty?
          puts no_move_message
        else
          puts migration_complete_message(
            moved,
            backfilled_count: backfilled_count,
            recovery_marker_count: recovery_marker_count,
            workflow_task_count: workflow_task_count,
            workflow_moved_count: workflow_moved_count,
            plan_review_requirement_count: plan_review_requirement_count
          )
        end
        if display_name_count.positive?
          puts "hive: migrate backfilled #{display_name_count} display name#{display_name_count == 1 ? '' : 's'}"
        end
        if repository_identity
          puts "hive: migrate backfilled registered repository identity #{repository_identity}"
        end
        if !restart_requested && (config_changed || moved.any? ||
           workflow_task_count.positive? || plan_review_requirement_count.positive?)
          (@daemon_restarter || method(:restart_daemon_if_running!)).call
        end
        moved
      end

      private

      def backfill_registered_repository_identity
        project = Hive::Config.registered_projects.find do |entry|
          same_project_path?(entry["path"], @project_path)
        end
        return nil unless project
        return nil unless project["repository_identity"].to_s.empty?

        identity = Hive::RepositoryIdentity.current(@project_path)
        return nil unless identity

        Hive::Config.register_project(
          name: project.fetch("name"),
          path: project.fetch("path"),
          repository_identity: identity
        )
        identity
      end

      def same_project_path?(candidate, expected)
        return true if File.expand_path(candidate.to_s) == expected

        File.realpath(candidate.to_s) == File.realpath(expected)
      rescue SystemCallError
        false
      end

      def build_migration_plan(stages)
        ops = []
        STAGE_RENAMES.each do |old_stage, new_stage|
          old_dir = File.join(stages, old_stage)
          new_dir = File.join(stages, new_stage)
          next unless Dir.exist?(old_dir)

          Dir.children(old_dir).sort.each do |entry|
            # Skip any non-slug entry (including .gitkeep, .DS_Store,
            # stray .lock, etc.). Only task-folder slugs migrate.
            next unless Hive::Stages.task_slug?(entry)

            src = File.join(old_dir, entry)
            next unless File.directory?(src)
            # Managed workflows own their stage topology. Moving one through
            # the coding-workflow rename table can corrupt a perfectly valid
            # package stage that happens to share a legacy coding directory.
            # TaskMigrator resolves these folders through their pinned and
            # selected descriptors instead.
            next if Hive::TaskMeta.read(src)[:workflow_commit]

            ops << {
              old_stage: old_stage, new_stage: new_stage, entry: entry,
              src: src, dst: File.join(new_dir, entry)
            }
          end
        end
        ops
      end

      def preflight_collisions!(plan)
        # First: detect duplicate destinations *within* the plan itself.
        # STAGE_RENAMES maps multiple legacy stages to the same canonical
        # target (e.g., both `6-pr` and `7-finalize` map to `8-finalize`).
        # If a project has the same slug under two source stages,
        # File.exist? on the not-yet-created destination misses the
        # conflict — both ops pass preflight, the second FileUtils.mv
        # silently nests the source folder inside the existing dst
        # (`8-finalize/<slug>/<slug>/`), and PATH_RE cannot re-parse it.
        # Group by destination and raise on any plan-internal duplicate
        # before any mv runs.
        plan.group_by { |op| op[:dst] }.each do |dst, ops|
          next if ops.size == 1

          sources = ops.map { |op| "#{op[:old_stage]}/#{op[:entry]}" }.join(", ")
          raise Hive::DestinationCollision.new(
            "cannot migrate: multiple legacy stages target the same destination #{dst} " \
            "(sources: #{sources}); resolve by moving or renaming one of the source folders before rerunning",
            path: dst
          )
        end

        collisions = plan.select { |op| File.exist?(op[:dst]) }
        return if collisions.empty?

        first = collisions.first
        raise Hive::DestinationCollision.new(
          "cannot migrate #{collisions.size} task#{collisions.size == 1 ? '' : 's'}; " \
          "destination already exists for #{first[:old_stage]}/#{first[:entry]} at #{first[:dst]}",
          path: first[:dst]
        )
      end

      def ensure_current_stage_dirs(stages)
        Hive::Stages::DIRS.each do |stage|
          dir = File.join(stages, stage)
          FileUtils.mkdir_p(dir)
          gitkeep = File.join(dir, ".gitkeep")
          FileUtils.touch(gitkeep) unless File.exist?(gitkeep)
        end
      end

      def backfill_task_ids(stages)
        folders = task_folders(stages)
        max_id = folders.map { |folder| Hive::TaskMeta.read(folder)[:id] }.compact.max
        Hive::TaskCounter.seed_at_least!(max_id + 1) if max_id

        targets = folders.select { |folder| Hive::TaskMeta.read(folder)[:id].nil? }
        targets.sort_by! { |folder| [ idea_created_at(folder) || Time.at(2**31 - 1), File.basename(folder) ] }

        targets.each do |folder|
          Hive::TaskMeta.update_id(folder, Hive::TaskCounter.next!)
        end
        targets.size
      end

      # `plan-review/` is task-local, so its absence alone cannot distinguish
      # a genuine pre-feature execute task from a post-feature task whose
      # review evidence was removed before a raw folder move. Stamp every
      # built-in coding task that has not yet entered execute. New tasks receive
      # the same bit at creation; tasks already at execute or later deliberately
      # remain eligible for the legacy adoption receipt.
      def backfill_plan_review_requirements(stages)
        cfg = @config_loader.call(@project_path)
        default_workflow = cfg.fetch("default_workflow", "coding").to_s
        task_folders(stages).count do |folder|
          stage_index = File.basename(File.dirname(folder)).split("-", 2).first.to_i
          next false unless stage_index.between?(1, 3)

          metadata = Hive::TaskMeta.read_for_admission(folder)
          next false unless metadata.ok?

          workflow = metadata.data[:workflow] || default_workflow
          next false unless Hive::Workflows.coding_id?(workflow)
          next false if Hive::TaskMeta.plan_review_required?(folder)

          Hive::TaskMeta.rewrite(folder, plan_review_required: true)
          true
        end
      end

      # Recovery v2 requires every recoverable marker generation to carry a
      # durable random identity. Older projects may have ERROR/REVIEW_ERROR
      # markers written before marker_id existed. Migrate them once, under the
      # project commit lock, so runtime recovery can reject id-less markers
      # instead of carrying a permanent compatibility identity algorithm.
      def backfill_recovery_marker_ids(
        stages, managed_store: nil, cfg: {}, workflow_generation: nil
      )
        task_folders(stages).count do |folder|
          state_file = recovery_state_file(
            folder, managed_store: managed_store, cfg: cfg,
            workflow_generation: workflow_generation
          )
          next false unless state_file

          marker = Hive::Markers.current(state_file)
          next false unless Hive::Recovery.recoverable_marker?(marker.name)
          next false unless marker.attrs["marker_id"].to_s.empty?

          Hive::Markers.upgrade_recovery_marker_id(state_file, observed: marker)
        end
      end

      # One-version bridge for execute markers written by pre-autonomy Hive.
      # Current execute code writes attributed dirty agent work as ERROR
      # directly, so keeping this rewrite in every daemon tick would turn a
      # finite state migration into permanent scheduler vocabulary.
      def migrate_attributed_dirty_execute_waits(stages, cfg:)
        execute_dir = File.join(stages, "4-execute") # coding-scoped: legacy coding migration
        return 0 unless Dir.exist?(execute_dir)

        default_workflow = cfg.fetch("default_workflow", "coding")
        Dir.children(execute_dir).sort.count do |entry|
          next false unless Hive::Stages.task_slug?(entry)

          folder = File.join(execute_dir, entry)
          next false unless File.directory?(folder)
          metadata = Hive::TaskMeta.read(folder)
          workflow = metadata[:workflow] || default_workflow
          next false unless Hive::Workflows.coding_id?(workflow)

          state_file = Hive::Task.new(folder).state_file
          marker = Hive::Markers.current(state_file)
          next false unless marker.name == :execute_waiting
          next false unless marker.attrs["reason"].to_s == "dirty_worktree"
          next false if marker.attrs["attempt_id"].to_s.empty?

          Hive::Markers.set(
            state_file, :error,
            marker.attrs.merge(
              "reason" => "dirty_worktree",
              "recovered_from" => "execute_waiting"
            )
          )
          true
        end
      end

      def recovery_state_file(folder, managed_store: nil, cfg: {}, workflow_generation: nil)
        read = Hive::TaskMeta.read_for_admission(folder)
        if managed_store && read.status == :ok && read.data[:workflow_commit]
          meta = read.data
          workflow = managed_store.workflow(
            meta.fetch(:workflow),
            meta.fetch(:workflow_commit),
            meta.fetch(:workflow_manifest_digest),
            configuration_digest: meta[:workflow_configuration_digest],
            cfg: cfg,
            verify_profiles: false
          )
          stage = workflow.stage_for_dir(File.basename(File.dirname(folder)))
          return File.join(folder, stage.state_file) if stage

          return nil
        end

        # Runtime task loading without an immutable generation reads managed
        # selections and would re-enter the mutation lock held by migrate.
        Hive::Task.new(folder, workflow_generation: workflow_generation).state_file
      rescue Hive::InvalidTaskPath, Hive::ConfigError
        # An unknown or incomplete workflow cannot identify its authoritative
        # state file safely. Preserve it unchanged; recovery remains blocked
        # until the workflow is restored and migrate can be rerun.
        nil
      end

      def with_store_mutation_lock(store, &block)
        return yield unless store.respond_to?(:workflows_dir)

        Hive::WorkflowPackage::MutationLock.with_lock(store.workflows_dir, &block)
      end

      def backfill_display_names(stages)
        cfg = Hive::Config.load(@project_path)
        targets = task_folders(stages).select { |folder| Hive::TaskMeta.read(folder)[:display_name].nil? }

        targets.count do |folder|
          name = @display_name_generator.new(Hive::Task.new(folder), cfg: cfg, commit: false).call
          !name.to_s.strip.empty?
        end
      end

      def task_folders(stages)
        return [] unless Dir.exist?(stages)

        Dir.children(stages).sort.flat_map do |stage|
          stage_dir = File.join(stages, stage)
          next [] unless File.directory?(stage_dir)

          Dir.children(stage_dir).sort.filter_map do |entry|
            next unless Hive::Stages.task_slug?(entry)

            folder = File.join(stage_dir, entry)
            folder if File.directory?(folder)
          end
        end
      end

      def idea_created_at(folder)
        path = File.join(folder, "idea.md")
        return nil unless File.exist?(path)

        data = frontmatter(File.read(path))
        raw = data["created_at"] || data[:created_at]
        return raw if raw.is_a?(Time)

        Time.parse(raw.to_s)
      rescue StandardError
        nil
      end

      def frontmatter(contents)
        return {} unless contents.start_with?("---\n")

        body = contents.lines[1..]
        stop = body&.index { |line| line.match?(/\A---\s*\z/) }
        return {} unless stop

        YAML.safe_load(body.first(stop).join) || {}
      rescue StandardError
        {}
      end

      def commit_migration(hive_state, moved, config_only: false, backfilled_count: 0,
                           recovery_marker_count: 0,
                           workflow_task_count: 0,
                           plan_review_requirement_count: 0)
        ops = Hive::GitOps.new(@project_path)
        ops.run_git!("-C", hive_state, "add", "-A")
        _out, _err, status = Open3.capture3("git", "-C", hive_state, "diff", "--cached", "--quiet")
        return if status.success?

        message = migrate_commit_message(
          moved, config_only: config_only, backfilled_count: backfilled_count,
          recovery_marker_count: recovery_marker_count,
          workflow_task_count: workflow_task_count,
          plan_review_requirement_count: plan_review_requirement_count
        )
        ops.run_git!("-C", hive_state, "commit", "-m", message)
      rescue Hive::GitError => e
        # The mv operations already succeeded — the on-disk layout is
        # the new one — but git couldn't commit the change (missing
        # git, dirty index, hook failure, EACCES, etc.). Without this
        # rescue, a subsequent `hive migrate` sees `already_migrated?`
        # return true (because legacy dirs are absent) and is a no-op,
        # so the moves never get committed unless the operator notices
        # and runs the right git commands manually. Print a concrete
        # one-liner recovery hint and swallow the error so the rest of
        # `Migrate#call` (daemon restart, completion message) still
        # runs against the consistent on-disk layout. ce-code-review
        # P2 #21.
        message = migrate_commit_message(
          moved, config_only: config_only, backfilled_count: backfilled_count,
          recovery_marker_count: recovery_marker_count,
          workflow_task_count: workflow_task_count,
          plan_review_requirement_count: plan_review_requirement_count
        )
        warn "hive: migrate completed the on-disk mv operations but " \
             "could not commit them to the hive-state git history: " \
             "#{e.class}: #{e.message}"
        warn "hive: recover with:  git -C #{hive_state} add -A && " \
             "git -C #{hive_state} commit -m '#{message}'"
      end

      def commit_display_name_backfill(hive_state, display_name_count)
        ops = Hive::GitOps.new(@project_path)
        ops.run_git!("-C", hive_state, "add", "-A")
        _out, _err, status = Open3.capture3("git", "-C", hive_state, "diff", "--cached", "--quiet")
        return if status.success?

        ops.run_git!("-C", hive_state, "commit", "-m",
                     "hive: migrate display names (#{display_name_count} task#{display_name_count == 1 ? '' : 's'})")
      rescue Hive::GitError => e
        warn "hive: migrate generated display names but could not commit them " \
             "to the hive-state git history: #{e.class}: #{e.message}"
        warn "hive: recover with:  git -C #{hive_state} add -A && " \
             "git -C #{hive_state} commit -m 'hive: migrate display names " \
             "(#{display_name_count} task#{display_name_count == 1 ? '' : 's'})'"
      end

      def commit_managed_workflow_cleanup(hive_state, operations)
        names = operations.map(&:workflow).uniq.sort
        return if names.empty?

        Hive::Lock.with_commit_lock(hive_state) do
          Hive::GitOps.new(@project_path).hive_commit(
            stage_name: "workflows", slug: "migration-cleanup",
            action: "cleaned unreferenced generations",
            pathspecs: names.map { |name| File.join("workflows", name) }
          )
        end
      rescue Hive::GitError => error
        warn "hive: managed workflow cleanup could not be committed: #{error.message}"
      end

      def migrate_commit_message(moved, config_only:, backfilled_count: 0,
                                 recovery_marker_count: 0,
                                 workflow_task_count: 0,
                                 plan_review_requirement_count: 0)
        if moved.empty? && recovery_marker_count.positive? &&
           backfilled_count.zero? && workflow_task_count.zero? &&
           plan_review_requirement_count.zero? &&
           !config_only
          "hive: migrate recovery markers (#{recovery_marker_count} task#{recovery_marker_count == 1 ? '' : 's'})"
        elsif moved.empty? && workflow_task_count.positive? &&
              backfilled_count.zero? && recovery_marker_count.zero? &&
              plan_review_requirement_count.zero? &&
              !config_only
          "hive: migrate managed workflow tasks " \
            "(#{workflow_task_count} task#{workflow_task_count == 1 ? '' : 's'})"
        elsif moved.empty? && backfilled_count.positive? && !config_only &&
              recovery_marker_count.zero? && workflow_task_count.zero? &&
              plan_review_requirement_count.zero?
          "hive: migrate task ids (#{backfilled_count} task#{backfilled_count == 1 ? '' : 's'})"
        elsif moved.empty? && plan_review_requirement_count.positive? &&
              backfilled_count.zero? && recovery_marker_count.zero? &&
              workflow_task_count.zero? && !config_only
          "hive: migrate plan review requirements " \
            "(#{plan_review_requirement_count} task#{plan_review_requirement_count == 1 ? '' : 's'})"
        elsif config_only && moved.empty? && recovery_marker_count.zero? &&
              workflow_task_count.zero? && plan_review_requirement_count.zero?
          "hive: migrate config keys (no tasks moved)"
        elsif moved.empty?
          parts = []
          parts << "#{backfilled_count} ids" if backfilled_count.positive?
          parts << "#{recovery_marker_count} recovery markers" if recovery_marker_count.positive?
          if workflow_task_count.positive?
            parts << "#{workflow_task_count} managed workflow tasks"
          end
          if plan_review_requirement_count.positive?
            parts << "#{plan_review_requirement_count} plan review requirements"
          end
          "hive: migrate project state (#{parts.join(', ')})"
        else
          "hive: migrate stage directories (#{moved.size} task#{moved.size == 1 ? '' : 's'})"
        end
      end

      def migration_complete_message(moved, backfilled_count:,
                                     recovery_marker_count:,
                                     workflow_task_count:,
                                     workflow_moved_count:,
                                     plan_review_requirement_count: 0)
        parts = [ "#{moved.size} task#{moved.size == 1 ? '' : 's'} moved" ]
        if backfilled_count.positive?
          parts << "#{backfilled_count} id#{backfilled_count == 1 ? '' : 's'} backfilled"
        end
        if recovery_marker_count.positive?
          parts << "#{recovery_marker_count} recovery marker" \
                   "#{recovery_marker_count == 1 ? '' : 's'} upgraded"
        end
        if workflow_task_count.positive?
          detail = workflow_moved_count.positive? ?
            " (#{workflow_moved_count} stage#{workflow_moved_count == 1 ? '' : 's'} moved)" : ""
          parts << "#{workflow_task_count} managed workflow task" \
                   "#{workflow_task_count == 1 ? '' : 's'} migrated#{detail}"
        end
        if plan_review_requirement_count.positive?
          requirement_label = plan_review_requirement_count == 1 ? "requirement" : "requirements"
          parts << "#{plan_review_requirement_count} plan review #{requirement_label} added"
        end
        "hive: migrate complete (#{parts.join(', ')})"
      end

      def migration_no_move_message(config_changed:, backfilled_count:,
                                    recovery_marker_count: 0,
                                    workflow_task_count: 0,
                                    workflow_moved_count: 0,
                                    plan_review_requirement_count: 0)
        actions = []
        actions << "rewrote legacy config keys" if config_changed
        if backfilled_count.positive?
          actions << "backfilled #{backfilled_count} task id#{backfilled_count == 1 ? '' : 's'}"
        end
        if recovery_marker_count.positive?
          actions << "upgraded #{recovery_marker_count} recovery marker#{recovery_marker_count == 1 ? '' : 's'}"
        end
        if workflow_task_count.positive?
          detail = workflow_moved_count.positive? ?
            " (#{workflow_moved_count} stage#{workflow_moved_count == 1 ? '' : 's'} moved)" : ""
          actions << "migrated #{workflow_task_count} managed workflow task" \
                     "#{workflow_task_count == 1 ? '' : 's'}#{detail}"
        end
        if plan_review_requirement_count.positive?
          requirement_label = plan_review_requirement_count == 1 ? "requirement" : "requirements"
          actions << "added #{plan_review_requirement_count} plan review #{requirement_label}"
        end
        "hive: migrate #{actions.join(' and ')}"
      end

      # Rewrite legacy `pr` budget/timeout keys onto the canonical
      # `finalize` names so the read-through fallback in Stages::Finalize
      # has a removal path. Idempotent and a no-op when the legacy keys
      # don't exist.
      def rewrite_legacy_config_keys(hive_state)
        path = File.join(hive_state, "config.yml")
        return false unless File.exist?(path)

        content = File.read(path)
        changed = false
        content, rewritten = rewrite_retired_patrol_policy(content, path)
        changed ||= rewritten
        content, rewritten = rewrite_legacy_root_reviewers(content, path)
        changed ||= rewritten
        CONFIG_KEY_RENAMES.each do |from, to|
          section, key = from
          dst_section, dst_key = to
          next unless section == dst_section

          content, rewritten = rewrite_section_key(content, section, key, dst_key)
          changed ||= rewritten
        end
        if changed
          mode = File.stat(path).mode & 0o777
          Hive::AtomicFile.write(path, content, mode: mode)
          Hive::AtomicFile.fsync_directory(File.dirname(path))
        end
        changed
      end

      def rewrite_legacy_root_reviewers(content, path)
        lines = content.lines
        root_idx = lines.index { |line| ROOT_REVIEWERS_LINE.match?(line) }
        return [ content, false ] unless root_idx

        parsed = YAML.safe_load(content) || {}
        review_present = parsed.key?("review")
        normalized = Hive::Config.normalize_legacy_project_config(parsed, path, emit_warning: false)
        Hive::Config.build_project_config(@project_path, path, normalized)

        root_start_idx = root_idx
        while root_start_idx.positive? && lines[root_start_idx - 1].match?(/\A#/)
          root_start_idx -= 1
        end
        end_idx = ((root_idx + 1)...lines.length).find do |idx|
          line = lines[idx]
          !line.strip.empty? && line.match?(/\A\S/)
        end || lines.length
        root_block = lines.slice!(root_start_idx...end_idx)
        indented_root_block = root_block.map do |line|
          line.strip.empty? ? line : "  #{line}"
        end

        if review_present
          review_idx = lines.index { |line| REVIEW_BLOCK_LINE.match?(line) }
          unless review_idx
            raise Hive::ConfigError,
                  "cannot automatically migrate top-level `reviewers` in #{path} because " \
                  "`review` is not written as a block mapping; move the value to " \
                  "`review.reviewers` manually"
          end
          lines.insert(review_idx + 1, *indented_root_block)
        else
          lines.insert(root_start_idx, "review:\n", *indented_root_block)
        end

        [ lines.join, true ]
      rescue Psych::Exception => e
        raise Hive::ConfigError, "config.yml at #{path} is not valid YAML: #{e.message}"
      end

      # Remove retired Patrol allowance/leverage policy without retaining a
      # compatibility reader. Block-style YAML is edited in place to preserve
      # unrelated comments and formatting. Rare flow-style/quoted layouts
      # normalize only a target top-level section after proving which section
      # the block-preserving rewrite could not represent.
      def rewrite_retired_patrol_policy(content, path)
        parsed = YAML.safe_load(content) || {}
        unless parsed.is_a?(Hash)
          raise Hive::ConfigError, "config.yml at #{path} must be a hash"
        end

        target = parsed
        changed_sections = delete_retired_patrol_values!(target)
        return [ content, false ] if changed_sections.empty?

        rewritten = content
        RETIRED_PATROL_CONFIG_KEYS.each do |key|
          rewritten = remove_block_mapping_key(rewritten, [ "patrol" ], key)
        end
        RETIRED_REFACTOR_PATROL_CONFIG_KEYS.each do |key|
          rewritten = remove_block_mapping_key(rewritten, [ "refactor_patrol" ], key)
        end
        rewritten = remove_block_mapping_key(
          rewritten, [ "refactor_patrol", "issue_filing" ], "min_leverage_score"
        )
        rewritten = remove_block_mapping(rewritten, [ "refactor_patrol", "leverage" ])

        reparsed = YAML.safe_load(rewritten) || {}
        changed_sections.each do |section|
          next if reparsed[section] == target[section]

          rewritten = normalize_retired_patrol_section(
            rewritten, section, target.fetch(section), path
          )
          reparsed = YAML.safe_load(rewritten) || {}
        end
        unless reparsed == target
          raise Hive::ConfigError,
                "cannot automatically migrate retired Patrol policy in #{path} " \
                "without rewriting unrelated config"
        end
        [ rewritten, true ]
      rescue Psych::Exception => e
        raise Hive::ConfigError, "config.yml at #{path} is not valid YAML: #{e.message}"
      end

      def delete_retired_patrol_values!(config)
        changed_sections = []
        patrol = config["patrol"]
        if patrol.is_a?(Hash)
          patrol_changed = false
          RETIRED_PATROL_CONFIG_KEYS.each do |key|
            next unless patrol.key?(key)

            patrol.delete(key)
            patrol_changed = true
          end
          changed_sections << "patrol" if patrol_changed
        end

        refactor = config["refactor_patrol"]
        return changed_sections unless refactor.is_a?(Hash)

        refactor_changed = false
        RETIRED_REFACTOR_PATROL_CONFIG_KEYS.each do |key|
          next unless refactor.key?(key)

          refactor.delete(key)
          refactor_changed = true
        end
        issue_filing = refactor["issue_filing"]
        if issue_filing.is_a?(Hash) && issue_filing.key?("min_leverage_score")
          issue_filing.delete("min_leverage_score")
          refactor_changed = true
        end
        if refactor.key?("leverage")
          refactor.delete("leverage")
          refactor_changed = true
        end
        changed_sections << "refactor_patrol" if refactor_changed
        changed_sections
      end

      def normalize_retired_patrol_section(content, section, value, path)
        document = Psych.parse(content)
        mapping = document&.root
        unless mapping.is_a?(Psych::Nodes::Mapping)
          raise Hive::ConfigError, "config.yml at #{path} must be a hash"
        end

        pair = mapping.children.each_slice(2).find do |key_node, _value_node|
          key_node.is_a?(Psych::Nodes::Scalar) && key_node.value == section &&
            key_node.start_column.zero?
        end
        unless pair
          raise Hive::ConfigError,
                "cannot locate top-level `#{section}` in #{path} for migration"
        end

        key_node, value_node = pair
        lines = content.lines
        end_idx = value_node.end_line
        end_idx += 1 unless value_node.end_column.zero?
        end_idx = [ end_idx, key_node.start_line + 1 ].max
        while end_idx > key_node.start_line + 1 &&
              lines[end_idx - 1]&.match?(/\A\s*(?:#.*)?(?:\r?\n)?\z/)
          end_idx -= 1
        end

        replacement = { section => value }.to_yaml.lines.drop(1)
        lines[key_node.start_line...end_idx] = replacement
        lines.join
      end

      def remove_block_mapping_key(content, mapping_path, key)
        lines = content.lines
        range = block_mapping_range(lines, mapping_path)
        return content unless range

        start_idx, end_idx, parent_indent = range
        child_indent = direct_child_indent(lines, start_idx, end_idx, parent_indent)
        return content unless child_indent

        pattern = mapping_key_pattern(key, child_indent, value_required: true)
        index = (start_idx...end_idx).find { |idx| pattern.match?(lines[idx]) }
        return content unless index

        entry_end = index + 1
        while entry_end < end_idx
          line = lines[entry_end]
          if line.strip.empty? || line.lstrip.start_with?("#")
            entry_end += 1
            next
          end

          indent = line[/\A */].size
          break if indent < child_indent
          break if indent == child_indent && !line.lstrip.start_with?("-")

          entry_end += 1
        end
        while entry_end > index + 1 &&
              lines[entry_end - 1]&.match?(/\A\s*(?:#.*)?(?:\r?\n)?\z/)
          entry_end -= 1
        end
        lines.slice!(index...entry_end)
        lines.join
      end

      def remove_block_mapping(content, mapping_path)
        lines = content.lines
        range = block_mapping_range(lines, mapping_path)
        return content unless range

        start_idx, end_idx, = range
        lines.slice!(start_idx...end_idx)
        lines.join
      end

      def block_mapping_range(lines, mapping_path)
        start_idx = 0
        end_idx = lines.length
        parent_indent = -1

        mapping_path.each do |key|
          child_indent = direct_child_indent(lines, start_idx, end_idx, parent_indent)
          return nil unless child_indent

          pattern = mapping_key_pattern(key, child_indent, value_required: false)
          index = (start_idx...end_idx).find { |idx| pattern.match?(lines[idx]) }
          return nil unless index

          parent_indent = child_indent
          start_idx = index
          end_idx = mapping_end_index(lines, index, parent_indent, end_idx)
        end
        [ start_idx, end_idx, parent_indent ]
      end

      def direct_child_indent(lines, start_idx, end_idx, parent_indent)
        first = start_idx
        first += 1 if parent_indent >= 0
        indents = (first...end_idx).filter_map do |idx|
          line = lines[idx]
          next if line.strip.empty? || line.lstrip.start_with?("#")

          indent = line[/\A */].length
          indent if indent > parent_indent
        end
        indents.min
      end

      def mapping_end_index(lines, index, indent, outer_end)
        ((index + 1)...outer_end).find do |idx|
          line = lines[idx]
          next false if line.strip.empty? || line.lstrip.start_with?("#")

          line[/\A */].length <= indent
        end || outer_end
      end

      def mapping_key_pattern(key, indent, value_required:)
        value = value_required ? "[^\\r\\n]*(?:\\r?\\n)?" : "(?:#.*)?(?:\\r?\\n)?"
        /\A {#{indent}}(?:#{Regexp.escape(key)}|["']#{Regexp.escape(key)}["']):\s*#{value}\z/
      end

      def rewrite_section_key(content, section, legacy_key, canonical_key)
        lines = content.lines
        section_idx = lines.index { |line| line =~ /^(\s*)#{Regexp.escape(section)}:\s*(?:#.*)?$/ }
        return [ content, false ] unless section_idx

        section_indent = Regexp.last_match(1).length
        end_idx = lines.length
        ((section_idx + 1)...lines.length).each do |idx|
          line = lines[idx]
          next if line.strip.empty? || line.lstrip.start_with?("#")

          indent = line[/\A */].length
          if indent <= section_indent
            end_idx = idx
            break
          end
        end

        range = ((section_idx + 1)...end_idx)
        legacy_idx = range.find { |idx| lines[idx] =~ /^(\s*)#{Regexp.escape(legacy_key)}:(.*)$/ }
        return [ content, false ] unless legacy_idx

        canonical_exists = range.any? { |idx| lines[idx] =~ /^\s*#{Regexp.escape(canonical_key)}:/ }
        if canonical_exists
          lines.delete_at(legacy_idx)
        else
          lines[legacy_idx] = lines[legacy_idx].sub(/^(\s*)#{Regexp.escape(legacy_key)}:/, "\\1#{canonical_key}:")
        end
        [ lines.join, true ]
      end

      # True when every legacy stage dir is absent and every target
      # stage dir exists — i.e. an idempotent rerun of an already-
      # complete migration.
      def already_migrated?(stages)
        STAGE_RENAMES.all? { |old, new_dir| !Dir.exist?(File.join(stages, old)) && Dir.exist?(File.join(stages, new_dir)) }
      end

      # When `hive migrate` reshuffles the stage layout, an already-
      # running daemon still has stage-derived constants (including the
      # merge reconciler's supported PR-bearing stages) frozen at class-load
      # time from the OLD `Workflows::VERBS`. Restarting the daemon process
      # is the only way to refresh those constants (SIGHUP only re-reads YAML
      # config, not Ruby constants).
      #
      # Best-effort: skip when no daemon pid file, no live process, or
      # `HIVE_MIGRATE_SKIP_DAEMON_RESTART` is set. On Linux with
      # systemd-user available, restart via systemctl. Anywhere else,
      # print a load-bearing warning so the operator restarts manually.
      def restart_daemon_if_running!
        return if ENV["HIVE_MIGRATE_SKIP_DAEMON_RESTART"] == "1"

        pid = read_daemon_pid
        return if pid.nil? || !daemon_alive?(pid)

        if systemctl_available?
          ok = system("systemctl", "--user", "restart", "hive-daemon",
                      out: File::NULL, err: File::NULL)
          if ok
            puts "hive: restarted hive-daemon (pid #{pid}) so its in-memory stage layout matches the migrated on-disk layout"
            return
          end

          warn "hive: migrate detected a running hive-daemon (pid #{pid}) but " \
               "`systemctl --user restart hive-daemon` failed; restart the daemon " \
               "manually before its next archive dispatch (e.g., `hive daemon stop && hive daemon start`)"
          return
        end

        warn "hive: migrate detected a running hive-daemon (pid #{pid}); restart it " \
             "manually so its in-memory stage layout refreshes from the new Hive::Workflows::VERBS " \
             "(e.g., `hive daemon stop && hive daemon start`)"
      end

      def read_daemon_pid
        pid_file = File.join(Hive::Paths.config_home, ".daemon.pid")
        return nil unless File.exist?(pid_file)

        payload = YAML.safe_load(File.read(pid_file)) rescue nil
        pid = payload.is_a?(Hash) ? payload["pid"] : payload
        pid.is_a?(Integer) && pid.positive? ? pid : nil
      rescue SystemCallError
        nil
      end

      def daemon_alive?(pid)
        Hive::ProcessKill.pid_alive?(pid)
      end

      def systemctl_available?
        system("systemctl", "--user", "--version",
               out: File::NULL, err: File::NULL)
      rescue SystemCallError
        false
      end
    end
  end
end
