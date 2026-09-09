require "fileutils"
require "pathname"
require "hive/runtime_control_plane/dispatch_repository"
require "hive/lock"
require "hive/task_meta"

module Hive
  module WorkflowPackage
    # One-way cutover for tasks pinned to an older selected Honeycomb
    # generation or configuration. Runtime execution supports only the selected
    # generation; this is the sole boundary allowed to read an old descriptor.
    #
    # Stage names are the durable migration key. Package releases may insert or
    # reorder stages, but a stage that owns retained tasks must keep its semantic
    # name until those tasks have migrated.
    class TaskMigrator
      Result = Data.define(:task_count, :moved_count, :pathspecs, :warnings)
      Operation = Data.define(
        :source, :destination, :slug, :workflow, :from_pin, :to_pin,
        :from_state_file, :to_state_file
      )

      class Prepared
        attr_reader :operations

        def initialize(migrator, operations, locks)
          @migrator = migrator
          @operations = operations
          @locks = locks
          @closed = false
          @applied = false
        end

        def apply(&commit)
          raise Hive::ConcurrentRunError.new("managed workflow migration reservation is closed") if @closed
          raise Hive::ConcurrentRunError.new("managed workflow migration reservation was already applied") if @applied

          @applied = true
          @migrator.send(:apply_prepared, @operations, &commit)
        ensure
          close
        end

        def cleanup(result)
          raise Hive::ConcurrentRunError.new("managed workflow migration was not applied") unless @applied

          @migrator.send(:cleanup_unreferenced, @operations, result)
        end

        def close
          return if @closed

          @closed = true
          @migrator.send(:release_locks, @locks, @operations)
        end
      end

      def initialize(hive_state_path, store:, cfg:, workflow: nil, target_selection: nil,
                     recovery_pruner: nil)
        @hive_state_path = File.expand_path(hive_state_path)
        @stages_path = File.join(@hive_state_path, "stages")
        @store = store
        @cfg = cfg
        @workflow_filter = workflow&.to_s
        @target_selection = target_selection
        if @target_selection && !@workflow_filter
          raise ArgumentError, "target_selection requires a workflow filter"
        end
        @project_name = cfg.fetch("project_name", File.basename(File.dirname(@hive_state_path)))
        @recovery_pruner = recovery_pruner || lambda do |project, slug|
          Hive::RuntimeControlPlane::DispatchRepository.new(
            database: Hive::Lock.task_lease_repository.database
          ).remove_nonterminal_for_task(
            project: project, slug: slug
          )
        end
      end

      def prepare
        operations = build_plan
        preflight_destinations!(operations)
        locks = acquire_locks!(operations)
        revalidate_tasks!(operations)
        Prepared.new(self, operations.freeze, locks)
      rescue StandardError
        release_locks(locks || {}, operations || [])
        raise
      end

      def call(&commit)
        prepared = prepare
        result = prepared.apply(&commit)
        prepared.cleanup(result)
      ensure
        prepared&.close
      end

      private

      def build_plan
        selections = {}
        workflows = {}
        task_folders.filter_map do |folder|
          read = Hive::TaskMeta.read_for_admission(folder)
          unless read.status == :ok
            raise Hive::ConfigError,
                  "managed workflow migration cannot safely read #{Hive::TaskMeta.path(folder)}: " \
                  "#{read.error || read.status}"
          end

          meta = read.data
          provenance = %i[
            workflow_commit workflow_manifest_digest workflow_configuration_digest
          ]
          next unless provenance.any? { |key| meta[key] }
          next if @workflow_filter && meta[:workflow] && meta[:workflow] != @workflow_filter
          unless meta[:workflow] && meta[:workflow_commit] && meta[:workflow_manifest_digest]
            raise Hive::ConfigError,
                  "managed task #{File.basename(folder)} has incomplete workflow provenance; " \
                  "repair meta.yml and rerun hive migrate"
          end

          selection = selections.fetch(meta[:workflow]) do
            selections[meta[:workflow]] = target_selection(meta[:workflow]) ||
                                          @store.selected(meta[:workflow], cfg: @cfg)
          end
          unless selection
            raise Hive::ConfigError,
                  "managed workflow #{meta[:workflow].inspect} is not selected; " \
                  "cannot migrate task #{File.basename(folder)}"
          end

          to_pin = pin_from_selection(selection)
          from_pin = pin_from_meta(meta)
          next if from_pin == to_pin

          old_workflow = load_workflow(workflows, meta[:workflow], from_pin)
          current_workflow = load_workflow(workflows, meta[:workflow], to_pin)
          stage_dir = File.basename(File.dirname(folder))
          old_stage = old_workflow.stage_for_dir(stage_dir)
          unless old_stage
            raise Hive::ConfigError,
                  "managed task #{File.basename(folder)} is at #{stage_dir.inspect}, which is not " \
                  "present in its pinned workflow; repair the task folder and rerun hive migrate"
          end
          current_stage = current_workflow.stage_named(old_stage.name)
          unless current_stage
            raise Hive::ConfigError,
                  "managed workflow #{meta[:workflow].inspect} removed semantic stage " \
                  "#{old_stage.name.inspect} while task #{File.basename(folder)} still uses it; " \
                  "restore that stage name or archive/reset the task, then rerun hive migrate"
          end

          Operation.new(
            source: folder,
            destination: File.join(@stages_path, current_stage.dir, File.basename(folder)),
            slug: File.basename(folder),
            workflow: meta[:workflow],
            from_pin: from_pin.freeze,
            to_pin: to_pin.freeze,
            from_state_file: old_stage.state_file,
            to_state_file: current_stage.state_file
          )
        end
      end

      def target_selection(name)
        return unless @target_selection && name.to_s == @workflow_filter

        @target_selection
      end

      def load_workflow(cache, name, pin)
        key = [ name, pin.values_at(
          :workflow_commit, :workflow_manifest_digest, :workflow_configuration_digest
        ) ]
        cache.fetch(key) do
          cache[key] = @store.workflow(
            name,
            pin.fetch(:workflow_commit),
            pin.fetch(:workflow_manifest_digest),
            configuration_digest: pin[:workflow_configuration_digest],
            cfg: @cfg
          )
        end
      end

      def preflight_destinations!(operations)
        operations.group_by(&:destination).each do |destination, targets|
          next if targets.length == 1

          raise Hive::DestinationCollision.new(
            "cannot migrate managed tasks: multiple tasks target #{destination}", path: destination
          )
        end
        collision = operations.find do |operation|
          operation.source != operation.destination && File.exist?(operation.destination)
        end
        if collision
          raise Hive::DestinationCollision.new(
            "cannot migrate managed task #{collision.slug}; destination already exists at " \
            "#{collision.destination}",
            path: collision.destination
          )
        end

        artifact_collision = operations.find do |operation|
          next false if operation.from_state_file == operation.to_state_file

          File.exist?(File.join(operation.source, operation.from_state_file)) &&
            File.exist?(File.join(operation.source, operation.to_state_file))
        end
        return unless artifact_collision

        path = File.join(artifact_collision.source, artifact_collision.to_state_file)
        raise Hive::DestinationCollision.new(
          "cannot migrate managed task #{artifact_collision.slug}; selected state file already exists at #{path}",
          path: path
        )
      end

      def acquire_locks!(operations)
        locks = {}
        operations.each do |operation|
          locks[operation.source] = Hive::Lock.acquire_task_lock(
            operation.source,
            operation: "managed_workflow_migration",
            create: false
          )
        end
        locks
      rescue StandardError
        release_locks(locks, operations)
        raise
      end

      def revalidate_tasks!(operations)
        operations.each do |operation|
          meta = Hive::TaskMeta.read_for_admission(operation.source)
          unless meta.status == :ok && pin_from_meta(meta.data) == operation.from_pin
            raise Hive::ConcurrentRunError.new(
              "managed task #{operation.slug} changed while its migration was being prepared"
            )
          end
        end
      end

      def revalidate_selections!(operations)
        operations.each do |operation|
          selected = if @store.respond_to?(:inspect_selected)
            @store.inspect_selected(operation.workflow, cfg: @cfg)
          else
            @store.selected(operation.workflow, cfg: @cfg)
          end
          unless selected && pin_from_selection(selected) == operation.to_pin
            raise Hive::ConcurrentRunError.new(
              "managed workflow #{operation.workflow.inspect} selection changed during migration"
            )
          end
        end
      end

      def apply_prepared(operations)
        revalidate_tasks!(operations)
        revalidate_selections!(operations)
        mutated = []
        operations.each do |operation|
          snapshot = Hive::TaskMeta.snapshot(operation.source)
          FileUtils.mkdir_p(File.dirname(operation.destination))
          FileUtils.mv(operation.source, operation.destination) if operation.source != operation.destination
          mutation = { operation: operation, snapshot: snapshot, artifact_moved: false }
          mutated << mutation
          if operation.from_state_file != operation.to_state_file
            from = File.join(operation.destination, operation.from_state_file)
            to = File.join(operation.destination, operation.to_state_file)
            if File.exist?(from)
              FileUtils.mkdir_p(File.dirname(to))
              FileUtils.mv(from, to)
              mutation[:artifact_moved] = true
            end
          end
          Hive::TaskMeta.rewrite(operation.destination, operation.to_pin)
        end

        result = result_for(operations)
        yield result if block_given?
        warnings = prune_recovery_requests(operations)
        result.with(warnings: warnings.freeze)
      rescue StandardError
        rollback!(mutated || [])
        raise
      end

      def result_for(operations)
        Result.new(
          task_count: operations.length,
          moved_count: operations.count { |operation| operation.source != operation.destination },
          pathspecs: operations.flat_map { |operation| pathspecs_for(operation) }.uniq.sort.freeze,
          warnings: [].freeze
        )
      end

      def rollback!(mutated)
        mutated.reverse_each do |mutation|
          operation = mutation.fetch(:operation)
          begin
            if mutation[:artifact_moved]
              from = File.join(operation.destination, operation.to_state_file)
              to = File.join(operation.destination, operation.from_state_file)
              FileUtils.mv(from, to) if File.exist?(from)
            end
            FileUtils.mv(operation.destination, operation.source) if
              operation.source != operation.destination && File.exist?(operation.destination)
            Hive::TaskMeta.restore(operation.source, mutation.fetch(:snapshot))
          rescue StandardError => error
            warn "hive: managed workflow migration rollback failed for #{operation.slug}: " \
                 "#{error.class}: #{error.message}"
          end
        end
      end

      def release_locks(locks, operations)
        operations.reverse_each do |operation|
          lock = locks[operation.source]
          next unless lock

          folder = File.directory?(operation.destination) ? operation.destination : operation.source
          Hive::Lock.release_task_lock(folder, lock_id: lock.fetch("lock_id"))
        end
      end

      def prune_recovery_requests(operations)
        warnings = []
        operations.each do |operation|
          @recovery_pruner.call(@project_name, operation.slug)
        rescue StandardError => error
          warnings << "recovery cleanup for #{operation.slug} failed: #{error.class}: #{error.message}"
        end
        warnings.each { |message| warn "hive: managed workflow migration: #{message}" }
        warnings
      end

      def cleanup_unreferenced(operations, result)
        cleanup_warnings = []
        operations.map(&:workflow).uniq.each do |workflow|
          @store.cleanup_unreferenced(workflow)
        rescue StandardError => error
          cleanup_warnings <<
            "unreferenced #{workflow} cleanup failed: #{error.class}: #{error.message}"
        end
        cleanup_warnings.each { |message| warn "hive: managed workflow migration: #{message}" }
        result.with(warnings: (result.warnings + cleanup_warnings).uniq.freeze)
      end

      def task_folders
        Dir.glob(File.join(@stages_path, "*", "*", Hive::TaskMeta::FILENAME)).sort.map do |path|
          File.dirname(path)
        end
      end

      def pin_from_meta(meta)
        {
          workflow_commit: meta[:workflow_commit],
          workflow_manifest_digest: meta[:workflow_manifest_digest],
          workflow_configuration_digest: meta[:workflow_configuration_digest]
        }
      end

      def pin_from_selection(selection)
        {
          workflow_commit: selection.fetch("source_commit"),
          workflow_manifest_digest: selection.fetch("manifest_digest"),
          workflow_configuration_digest: selection.fetch("configuration_digest")
        }
      end

      def pathspecs_for(operation)
        [ operation.source, operation.destination ].map do |path|
          Pathname.new(path).relative_path_from(Pathname.new(@hive_state_path)).to_s
        end
      end
    end
  end
end
