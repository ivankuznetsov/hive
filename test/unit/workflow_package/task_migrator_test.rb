require "test_helper"
require "hive/workflow_package/task_migrator"

class WorkflowPackageTaskMigratorTest < Minitest::Test
  include HiveTestHelper

  FakeStore = Struct.new(:selection, :workflows, :cleaned, keyword_init: true) do
    def selected(_name, cfg:)
      selection
    end

    def workflow(name, commit, manifest_digest, configuration_digest:, cfg:)
      workflows.fetch([ name, commit, manifest_digest, configuration_digest ])
    end

    def cleanup_unreferenced(name)
      cleaned << name
      []
    end
  end

  def test_moves_tasks_by_stable_semantic_stage_and_repins_the_current_generation
    with_tmp_dir do |dir|
      old = workflow("review" => 4, "architecture" => 5)
      current = workflow("review" => 6, "architecture" => 7)
      store = store_for(old:, current:)
      source = task_folder(dir, "4-review", old_pin)
      pruned = []

      result = migrator(dir, store, pruner: ->(project, slug) { pruned << [ project, slug ] }).call

      destination = File.join(dir, "stages", "6-review", File.basename(source))
      refute File.exist?(source)
      assert File.directory?(destination)
      assert_equal current_pin, Hive::TaskMeta.read(destination).slice(
        :workflow_commit, :workflow_manifest_digest, :workflow_configuration_digest
      )
      assert_equal 1, result.task_count
      assert_equal 1, result.moved_count
      assert_equal [ [ "demo-project", File.basename(source) ] ], pruned
      assert_equal [ "demo" ], store.cleaned
    end
  end

  def test_repins_same_named_stage_without_moving_the_folder
    with_tmp_dir do |dir|
      old = workflow("certificate" => 6)
      current = workflow("certificate" => 6)
      store = store_for(old:, current:)
      folder = task_folder(dir, "6-certificate", old_pin)

      result = migrator(dir, store).call

      assert_equal 1, result.task_count
      assert_equal 0, result.moved_count
      assert_equal current_pin, Hive::TaskMeta.read(folder).slice(
        :workflow_commit, :workflow_manifest_digest, :workflow_configuration_digest
      )
    end
  end

  def test_rejects_a_removed_semantic_stage_before_mutating_any_task
    with_tmp_dir do |dir|
      old = workflow("review" => 4)
      current = workflow("publish" => 4)
      store = store_for(old:, current:)
      folder = task_folder(dir, "4-review", old_pin)
      before = File.binread(File.join(folder, "meta.yml"))

      error = assert_raises(Hive::ConfigError) { migrator(dir, store).call }

      assert_includes error.message, "semantic stage \"review\""
      assert_includes error.message, "hive migrate"
      assert_equal before, File.binread(File.join(folder, "meta.yml"))
      assert File.directory?(folder)
      assert_empty store.cleaned
    end
  end

  def test_live_task_lock_blocks_the_whole_migration_without_partial_repinning
    with_tmp_dir do |dir|
      old = workflow("review" => 4)
      current = workflow("review" => 6)
      store = store_for(old:, current:)
      first = task_folder(dir, "4-review", old_pin, slug: "first-task-260812-aaaa")
      second = task_folder(dir, "4-review", old_pin, slug: "second-task-260812-bbbb")
      lock = Hive::Lock.acquire_task_lock(second, operation: "test", create: false)

      assert_raises(Hive::ConcurrentRunError) { migrator(dir, store).call }

      assert File.directory?(first)
      assert File.directory?(second)
      assert_equal old_pin, Hive::TaskMeta.read(first).slice(
        :workflow_commit, :workflow_manifest_digest, :workflow_configuration_digest
      )
      assert_equal old_pin, Hive::TaskMeta.read(second).slice(
        :workflow_commit, :workflow_manifest_digest, :workflow_configuration_digest
      )
      assert_empty store.cleaned
    ensure
      Hive::Lock.release_task_lock(second, lock_id: lock.fetch("lock_id")) if lock
    end
  end

  def test_incomplete_managed_provenance_fails_instead_of_being_skipped
    with_tmp_dir do |dir|
      current = workflow("review" => 6)
      store = store_for(old: current, current: current)
      folder = File.join(dir, "stages", "6-review", "broken-task-260812-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"), <<~YAML)
        id: 42
        slug: #{File.basename(folder)}
        workflow: demo
        workflow_commit: #{"a" * 40}
      YAML

      error = assert_raises(Hive::ConfigError) { migrator(dir, store).call }

      assert_match(/incomplete workflow provenance/, error.message)
      assert_equal "a" * 40, Hive::TaskMeta.read(folder).fetch(:workflow_commit)
      assert_empty store.cleaned
    end
  end

  def test_is_idempotent_after_all_tasks_use_the_selected_generation
    with_tmp_dir do |dir|
      current = workflow("review" => 6)
      store = store_for(old: current, current: current)
      task_folder(dir, "6-review", current_pin)

      result = migrator(dir, store).call

      assert_equal 0, result.task_count
      assert_equal 0, result.moved_count
      assert_empty result.pathspecs
      assert_empty store.cleaned
    end
  end

  def test_rolls_back_every_task_when_a_later_metadata_rewrite_fails
    with_tmp_dir do |dir|
      old = workflow("review" => 4, state_files: { "review" => "review-v1.md" })
      current = workflow("review" => 6, state_files: { "review" => "review-v2.md" })
      store = store_for(old:, current:)
      first = task_folder(dir, "4-review", old_pin, slug: "first-task-260812-aaaa")
      second = task_folder(dir, "4-review", old_pin, slug: "second-task-260812-bbbb")
      [ first, second ].each do |folder|
        FileUtils.mv(File.join(folder, "review.md"), File.join(folder, "review-v1.md"))
      end
      pruned = []
      original = Hive::TaskMeta.method(:rewrite)
      calls = 0

      error = assert_raises(Errno::ENOSPC) do
        with_replaced_singleton_method(Hive::TaskMeta, :rewrite, lambda { |folder, attrs|
          calls += 1
          raise Errno::ENOSPC, folder if calls == 2

          original.call(folder, attrs)
        }) do
          migrator(dir, store, pruner: ->(project, slug) { pruned << [ project, slug ] }).call
        end
      end

      assert_match(/second-task/, error.message)
      [ first, second ].each do |folder|
        assert File.directory?(folder)
        assert_equal "evidence\n", File.read(File.join(folder, "review-v1.md"))
        refute File.exist?(File.join(folder, "review-v2.md"))
        assert_equal old_pin, Hive::TaskMeta.read(folder).slice(
          :workflow_commit, :workflow_manifest_digest, :workflow_configuration_digest
        )
      end
      refute File.exist?(File.join(dir, "stages", "6-review", File.basename(first)))
      refute File.exist?(File.join(dir, "stages", "6-review", File.basename(second)))
      assert_empty pruned
      assert_empty store.cleaned
    end
  end

  def test_scoped_migration_ignores_incomplete_provenance_owned_by_another_workflow
    with_tmp_dir do |dir|
      current = workflow("review" => 6)
      store = store_for(old: current, current: current)
      folder = File.join(dir, "stages", "6-review", "other-task-260812-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"), <<~YAML)
        id: 42
        slug: #{File.basename(folder)}
        workflow: other
        workflow_commit: #{"a" * 40}
      YAML

      result = Hive::WorkflowPackage::TaskMigrator.new(
        dir, store: store, cfg: { "project_name" => "demo-project" },
        workflow: "demo", recovery_pruner: ->(*) { 0 }
      ).call

      assert_equal 0, result.task_count
      assert_equal "a" * 40, Hive::TaskMeta.read(folder).fetch(:workflow_commit)
    end
  end

  def test_renames_the_stage_artifact_when_the_semantic_stage_keeps_its_name
    with_tmp_dir do |dir|
      old = workflow("review" => 4, state_files: { "review" => "review-v1.md" })
      current = workflow("review" => 6, state_files: { "review" => "review-v2.md" })
      store = store_for(old:, current:)
      source = task_folder(dir, "4-review", old_pin)
      FileUtils.mv(File.join(source, "review.md"), File.join(source, "review-v1.md"))

      migrator(dir, store).call

      destination = File.join(dir, "stages", "6-review", File.basename(source))
      assert_equal "evidence\n", File.read(File.join(destination, "review-v2.md"))
      refute File.exist?(File.join(destination, "review-v1.md"))
    end
  end

  def test_rejects_invalid_target_selection_and_unreadable_or_unselected_tasks
    with_tmp_dir do |dir|
      assert_raises(ArgumentError) do
        Hive::WorkflowPackage::TaskMigrator.new(
          dir, store: Object.new, cfg: {}, target_selection: {}
        )
      end

      current = workflow("review" => 6)
      store = store_for(old: current, current: current)
      folder = task_folder(dir, "6-review", old_pin)
      unreadable = Struct.new(:status, :error).new(:invalid, "bad metadata")
      original = Hive::TaskMeta.method(:read_for_admission)
      with_replaced_singleton_method(Hive::TaskMeta, :read_for_admission, lambda { |path|
        path == folder ? unreadable : original.call(path)
      }) do
        error = assert_raises(Hive::ConfigError) { migrator(dir, store).call }
        assert_includes error.message, "cannot safely read"
      end

      store.selection = nil
      error = assert_raises(Hive::ConfigError) { migrator(dir, store).call }
      assert_includes error.message, "is not selected"
    end
  end

  def test_rejects_a_task_folder_missing_from_its_pinned_workflow
    with_tmp_dir do |dir|
      old = workflow("review" => 4)
      current = workflow("review" => 6)
      store = store_for(old:, current:)
      task_folder(dir, "5-review", old_pin)

      error = assert_raises(Hive::ConfigError) { migrator(dir, store).call }

      assert_includes error.message, "not present in its pinned workflow"
    end
  end

  def test_preflight_rejects_duplicate_destinations_and_existing_artifacts
    with_tmp_dir do |dir|
      command = migrator(dir, store_for(old: workflow("review" => 4), current: workflow("review" => 6)))
      source = File.join(dir, "stages", "4-review", "task")
      destination = File.join(dir, "stages", "6-review", "task")
      operation = operation_for(source:, destination:)

      assert_raises(Hive::DestinationCollision) do
        command.send(:preflight_destinations!, [ operation, operation ])
      end

      FileUtils.mkdir_p(destination)
      assert_raises(Hive::DestinationCollision) do
        command.send(:preflight_destinations!, [ operation ])
      end
      FileUtils.rm_rf(destination)

      FileUtils.mkdir_p(source)
      File.write(File.join(source, "review-v1.md"), "old\n")
      File.write(File.join(source, "review-v2.md"), "new\n")
      assert_raises(Hive::DestinationCollision) do
        command.send(
          :preflight_destinations!,
          [ operation.with(from_state_file: "review-v1.md", to_state_file: "review-v2.md") ]
        )
      end
    end
  end

  def test_revalidation_rejects_changed_task_and_selection
    with_tmp_dir do |dir|
      old = workflow("review" => 4)
      current = workflow("review" => 6)
      store = store_for(old:, current:)
      folder = task_folder(dir, "4-review", old_pin)
      operation = operation_for(
        source: folder,
        destination: File.join(dir, "stages", "6-review", File.basename(folder))
      )
      command = migrator(dir, store)

      Hive::TaskMeta.rewrite(folder, current_pin)
      assert_raises(Hive::ConcurrentRunError) do
        command.send(:revalidate_tasks!, [ operation ])
      end

      store.selection = {
        "source_commit" => old_pin.fetch(:workflow_commit),
        "manifest_digest" => old_pin.fetch(:workflow_manifest_digest),
        "configuration_digest" => old_pin.fetch(:workflow_configuration_digest)
      }
      assert_raises(Hive::ConcurrentRunError) do
        command.send(:revalidate_selections!, [ operation ])
      end
    end
  end

  def test_defensive_failures_are_reported_as_migration_warnings
    with_tmp_dir do |dir|
      old = workflow("review" => 4)
      current = workflow("review" => 6)
      store = store_for(old:, current:)
      task_folder(dir, "4-review", old_pin)
      store.define_singleton_method(:cleanup_unreferenced) { |_name| raise Errno::EIO, "cleanup" }

      result = nil
      _out, err = capture_io do
        result = migrator(dir, store, pruner: ->(*) { raise Errno::ENOSPC, "queue" }).call
      end

      assert_equal 2, result.warnings.length
      assert_includes err, "recovery cleanup"
      assert_includes err, "unreferenced demo cleanup"
    end
  end

  def test_rollback_warning_preserves_the_original_failure
    with_tmp_dir do |dir|
      operation = operation_for(
        source: File.join(dir, "stages", "4-review", "task"),
        destination: File.join(dir, "stages", "4-review", "task")
      )
      command = migrator(dir, store_for(old: workflow("review" => 4), current: workflow("review" => 6)))

      _out, err = capture_io do
        with_replaced_singleton_method(Hive::TaskMeta, :restore, ->(*) { raise Errno::EIO, "restore" }) do
          command.send(:rollback!, [ { operation: operation, snapshot: {}, artifact_moved: false } ])
        end
      end

      assert_includes err, "rollback failed for task"
    end
  end

  private

  def migrator(hive_state, store, pruner: ->(*) { 0 })
    prepare_test_runtime_project(
      File.dirname(hive_state), state_root_path: hive_state
    )
    Hive::WorkflowPackage::TaskMigrator.new(
      hive_state,
      store: store,
      cfg: { "project_name" => "demo-project" },
      recovery_pruner: pruner
    )
  end

  def store_for(old:, current:)
    FakeStore.new(
      selection: {
        "source_commit" => current_pin.fetch(:workflow_commit),
        "manifest_digest" => current_pin.fetch(:workflow_manifest_digest),
        "configuration_digest" => current_pin.fetch(:workflow_configuration_digest)
      },
      workflows: {
        [ "demo", *old_pin.values_at(
          :workflow_commit, :workflow_manifest_digest, :workflow_configuration_digest
        ) ] => old,
        [ "demo", *current_pin.values_at(
          :workflow_commit, :workflow_manifest_digest, :workflow_configuration_digest
        ) ] => current
      },
      cleaned: []
    )
  end

  def workflow(stages = nil, state_files: {}, **named_stages)
    stages ||= named_stages
    by_index = stages.to_h { |name, index| [ index, name ] }
    Hive::Workflow.new(
      id: :demo,
      stages: (1..by_index.keys.max).map do |index|
        name = by_index.fetch(index, "placeholder-#{index}")
        Hive::Workflow::Stage.new(
          name: name, index: index,
          state_file: state_files.fetch(name, "#{name}.md"), kind: :agent
        )
      end
    )
  end

  def task_folder(hive_state, stage, pin, slug: "managed-task-260812-abcd")
    prepare_test_runtime_project(
      File.dirname(hive_state), state_root_path: hive_state
    )
    folder = File.join(hive_state, "stages", stage, slug)
    Hive::TaskMeta.write(
      folder,
      id: Digest::SHA256.hexdigest(slug)[0, 12].to_i(16),
      slug: slug,
      display_name: "Managed task",
      depends_on: "source-task-260811-abcd",
      workflow: "demo",
      base_branch: "launch",
      **pin
    )
    File.write(File.join(folder, "#{stage.split('-', 2).last}.md"), "evidence\n")
    folder
  end

  def old_pin
    {
      workflow_commit: "a" * 40,
      workflow_manifest_digest: "b" * 64,
      workflow_configuration_digest: "c" * 64
    }
  end

  def current_pin
    {
      workflow_commit: "d" * 40,
      workflow_manifest_digest: "e" * 64,
      workflow_configuration_digest: "f" * 64
    }
  end

  def operation_for(source:, destination:)
    Hive::WorkflowPackage::TaskMigrator::Operation.new(
      source: source,
      destination: destination,
      slug: "task",
      workflow: "demo",
      from_pin: old_pin,
      to_pin: current_pin,
      from_state_file: "review.md",
      to_state_file: "review.md"
    )
  end
end
