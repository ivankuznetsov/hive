require "test_helper"
require "open3"
require "rbconfig"
require "hive/commands/status"
require "hive/task"
require "hive/workflow_selection"
require "hive/workflows/project"

class WorkflowsProjectTest < Minitest::Test
  include HiveTestHelper

  def setup
    super
    Hive::Workflows::Project.reset!
  end

  def teardown
    Hive::Workflows::Project.reset!
    super
  end

  def test_load_registers_project_descriptor_and_resets_union
    with_tmp_dir do |project_root|
      write_project_workflow(project_root, "my-flow")

      Hive::Workflows::Project.load!(project_root)

      assert_equal :"my-flow", Hive::Workflows::Registry.fetch(:"my-flow").id
      assert_includes Hive::Workflows::Registry.ids, :"my-flow"
      assert_includes Hive::Workflows.all_stage_dirs, "2-work"
    end
  end

  def test_standalone_command_require_order_can_load_a_project
    script = <<~'RUBY'
      require "tmpdir"
      require "hive"
      require "hive/commands/markers"

      Dir.mktmpdir { |dir| Hive::Workflows::Project.load!(dir) }
    RUBY

    _out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script)

    assert status.success?, err
  end

  def test_load_reuses_a_resolved_project_config
    with_tmp_dir do |project_root|
      write_project_workflow(project_root, "resolved-flow")
      config = Hive::Config.load(project_root)
      Hive::Workflows::Project.reset!

      with_replaced_singleton_method(Hive::Config, :load, ->(*) { flunk "config should already be resolved" }) do
        Hive::Workflows::Project.load!(project_root, config: config)
      end

      assert_equal :"resolved-flow", Hive::Workflows::Registry.fetch(:"resolved-flow").id
    end
  end

  def test_with_active_workflows_yields_registry_and_full_stage_union_and_returns_block_value
    with_tmp_dir do |project_root|
      write_project_workflow(project_root, "project-flow", stage_name: "project-stage")
      File.write(
        File.join(project_root, ".hive-state", "config.yml"),
        { "research" => {}, "runtime-stage" => {}, "project-stage" => {} }.to_yaml
      )
      runtime = project_descriptor("runtime-flow", stage_name: "runtime-stage")

      with_registered_workflow(runtime) do
        result = Hive::Workflows::Project.with_active_workflows(project_root) do |registry, stage_names|
          assert_same Hive::Workflows::Registry, registry
          assert Hive::Workflows::Project::LOCK.mon_owned?, "the operation must hold the Monitor through the block"
          assert_includes stage_names, "research", "built-in stages remain valid"
          assert_includes stage_names, "runtime-stage", "runtime registrations remain valid"
          assert_includes stage_names, "project-stage", "accepted project stages become valid"

          :block_result
        end

        assert_equal :block_result, result
      end
    end
  end

  def test_rejected_builtin_collision_stage_is_not_part_of_strict_configuration_vocabulary
    with_tmp_dir do |project_root|
      path = write_project_workflow(project_root, "coding", stage_name: "collision-only")
      config_path = File.join(project_root, ".hive-state", "config.yml")
      File.write(config_path, { "collision-only" => { "agent" => "codex" } }.to_yaml)

      error = nil
      _out, err = capture_io do
        error = assert_raises(Hive::UnsupportedProjectConfigError) { Hive::Config.load(project_root) }
      end
      assert_includes err, path
      assert_includes err, "collides with registered workflow :coding"
      assert_includes error.message, "Unknown top-level key `collision-only`."

      operation_error = assert_raises(Hive::UnsupportedProjectConfigError) do
        Hive::Workflows::Project.with_active_workflows(project_root) { flunk "invalid config must not yield" }
      end
      assert_equal error.message, operation_error.message
      refute_includes Hive::Workflows::Registry.project_registrations.keys, :coding
    end
  end

  def test_with_active_workflows_rejects_nil_and_blank_roots_before_changing_the_overlay
    with_tmp_dir do |project_root|
      write_project_workflow(project_root, "stable-flow")
      Hive::Workflows::Project.load!(project_root)
      expected_ids = Hive::Workflows::Registry.ids

      [ nil, "", "   " ].each do |invalid_root|
        error = assert_raises(ArgumentError) do
          Hive::Workflows::Project.with_active_workflows(invalid_root) { flunk "invalid roots must not yield" }
        end
        assert_includes error.message, "project_root"
        assert_equal expected_ids, Hive::Workflows::Registry.ids
      end
    end
  end

  def test_same_root_nesting_reuses_the_view_and_different_root_adapter_entry_is_rejected_before_mutation
    with_tmp_dir do |root_a|
      with_tmp_dir do |root_b|
        write_project_workflow(root_a, "flow-a", stage_name: "alpha")
        write_project_workflow(root_b, "flow-b", stage_name: "beta")
        original = Hive::Workflows::Loader.method(:fingerprint)
        scans = 0

        with_replaced_singleton_method(Hive::Workflows::Loader, :fingerprint, lambda { |dir|
          scans += 1
          original.call(dir)
        }) do
          Hive::Workflows::Project.with_active_workflows(root_a) do |_registry, outer_stages|
            assert_equal 1, scans

            Hive::Workflows::Project.with_active_workflows(File.join(root_a, ".")) do |_inner_registry, inner_stages|
              assert_equal outer_stages, inner_stages
              assert_equal 1, scans, "same-root nesting must reuse the active view"
            end

            error = assert_raises(Hive::Workflows::Project::NestedProjectActivationError) do
              Hive::Workflows::Project.load!(root_b)
            end
            assert_includes error.message, File.expand_path(root_a)
            assert_includes error.message, File.expand_path(root_b)
            assert_includes Hive::Workflows::Registry.ids, :"flow-a"
            refute_includes Hive::Workflows::Registry.ids, :"flow-b"
            assert_includes outer_stages, "alpha"
          end

          Hive::Workflows::Project.with_active_workflows(root_b) do |_registry, stage_names|
            assert_includes stage_names, "beta"
            refute_includes stage_names, "alpha"
          end
        end
      end
    end
  end

  def test_with_active_workflows_clears_a_foreign_overlay_when_fingerprinting_aborts_and_retries_cleanly
    with_tmp_dir do |root_a|
      with_tmp_dir do |root_b|
        write_project_workflow(root_a, "flow-a")
        write_project_workflow(root_b, "flow-b")
        Hive::Workflows::Project.load!(root_a)
        failed_dir = File.join(root_b, ".hive-state", "workflows")
        fail_once = true
        yielded = false
        original = Hive::Workflows::Loader.method(:fingerprint)

        with_replaced_singleton_method(Hive::Workflows::Loader, :fingerprint, lambda { |dir|
          if dir == failed_dir && fail_once
            fail_once = false
            raise IOError, "fingerprint interrupted"
          end

          original.call(dir)
        }) do
          error = assert_raises(IOError) do
            Hive::Workflows::Project.with_active_workflows(root_b) { yielded = true }
          end
          assert_equal "fingerprint interrupted", error.message
          refute yielded
          refute_includes Hive::Workflows::Registry.ids, :"flow-a"
          refute_includes Hive::Workflows::Registry.ids, :"flow-b"

          Hive::Workflows::Project.with_active_workflows(root_b) do |_registry, stage_names|
            assert_includes stage_names, "work"
            assert_includes Hive::Workflows::Registry.ids, :"flow-b"
          end
        end
      end
    end
  end

  def test_with_active_workflows_clears_partial_registration_after_an_aborted_activation
    with_tmp_dir do |project_root|
      write_project_workflow(project_root, "first-flow", stage_name: "first")
      write_project_workflow(project_root, "second-flow", stage_name: "second")
      registrations = 0
      yielded = false
      original = Hive::Workflows::Registry.method(:register!)

      with_replaced_singleton_method(
        Hive::Workflows::Registry, :register!, lambda { |descriptor, **kwargs|
          registrations += 1 if kwargs[:project]
          raise RuntimeError, "registration interrupted" if registrations == 2

          original.call(descriptor, **kwargs)
        }
      ) do
        error = assert_raises(RuntimeError) do
          Hive::Workflows::Project.with_active_workflows(project_root) { yielded = true }
        end
        assert_equal "registration interrupted", error.message
      end

      refute yielded
      refute_includes Hive::Workflows::Registry.ids, :"first-flow"
      refute_includes Hive::Workflows::Registry.ids, :"second-flow"

      Hive::Workflows::Project.with_active_workflows(project_root) do
        assert_includes Hive::Workflows::Registry.ids, :"first-flow"
        assert_includes Hive::Workflows::Registry.ids, :"second-flow"
      end
    end
  end

  def test_config_load_accepts_active_project_stage_override_and_rejects_lookalike
    with_tmp_dir do |project_root|
      write_project_workflow(project_root, "my-flow", stage_name: "assemble")
      config_path = File.join(project_root, ".hive-state", "config.yml")
      File.write(config_path, { "assemble" => { "agent" => "codex", "timeout_sec" => 90 } }.to_yaml)

      cfg = Hive::Config.load(project_root)

      assert_equal({ "agent" => "codex", "timeout_sec" => 90 }, cfg.fetch("assemble"))
      assert_includes Hive::Workflows.all_stage_names, "assemble"

      File.write(config_path, { "assembly" => { "agent" => "codex" } }.to_yaml)
      error = assert_raises(Hive::ConfigError) { Hive::Config.load(project_root) }
      assert_includes error.message, "Unknown top-level key `assembly`."
    end
  end

  def test_project_load_scans_the_workflow_fingerprint_once_and_config_reuses_the_active_overlay
    with_tmp_dir do |project_root|
      write_project_workflow(project_root, "my-flow", stage_name: "assemble")
      config_path = File.join(project_root, ".hive-state", "config.yml")
      File.write(config_path, { "assemble" => { "agent" => "codex" } }.to_yaml)
      original = Hive::Workflows::Loader.method(:fingerprint)
      scans = 0

      with_replaced_singleton_method(Hive::Workflows::Loader, :fingerprint, lambda { |dir|
        scans += 1
        original.call(dir)
      }) do
        Hive::Workflows::Project.load!(project_root)
        assert_equal 1, scans, "one project load must perform one workflow fingerprint scan"

        Hive::Config.load(project_root)
        assert_equal 1, scans, "config validation must reuse the already-active project vocabulary"
      end
    end
  end

  def test_project_load_is_memoized_per_root
    with_tmp_dir do |project_root|
      workflows_dir = File.join(project_root, ".hive-state", "workflows")
      calls = 0
      descriptor = project_descriptor("memo-flow")

      with_replaced_singleton_method(Hive::Workflows::Loader, :workflow_dir, ->(_root, **) { workflows_dir }) do
        with_replaced_singleton_method(Hive::Workflows::Loader, :load_dir, lambda { |_dir|
          calls += 1
          { descriptor.id => descriptor }
        }) do
          Hive::Workflows::Project.load!(project_root)
          Hive::Workflows::Project.load!(project_root)
        end
      end

      assert_equal 1, calls
      assert_equal descriptor, Hive::Workflows::Registry.fetch(:"memo-flow")
    end
  end

  def test_loading_another_project_replaces_project_overlay_without_reparsing
    with_tmp_dir do |root_a|
      with_tmp_dir do |root_b|
        write_project_workflow(root_a, "flow-a", stage_name: "alpha")
        write_project_workflow(root_b, "flow-b", stage_name: "beta")

        Hive::Workflows::Project.load!(root_a)
        assert_includes Hive::Workflows::Registry.ids, :"flow-a"
        refute_includes Hive::Workflows::Registry.ids, :"flow-b"
        assert_includes Hive::Workflows.all_stage_names, "alpha"

        Hive::Workflows::Project.load!(root_b)
        assert_includes Hive::Workflows::Registry.ids, :"flow-b"
        refute_includes Hive::Workflows::Registry.ids, :"flow-a"
        assert_includes Hive::Workflows.all_stage_names, "beta"
        refute_includes Hive::Workflows.all_stage_names, "alpha"

        Hive::Workflows::Project.load!(root_a)
        assert_includes Hive::Workflows::Registry.ids, :"flow-a"
        refute_includes Hive::Workflows::Registry.ids, :"flow-b"
      end
    end
  end

  # A project descriptor whose id collides with a built-in must NOT raise out of
  # load! — that would brick the eager Project.load! in Task#initialize for
  # EVERY task in the project, including built-in coding ones. It is reported on
  # stderr with its path and skipped; the built-in coding workflow stays intact.
  def test_builtin_id_collision_is_reported_on_stderr_and_skipped_not_raised
    with_tmp_dir do |project_root|
      path = write_project_workflow(project_root, "coding")

      _out, err = capture_io { Hive::Workflows::Project.load!(project_root) }

      assert_includes err, path
      assert_includes err, "collides with registered workflow :coding"
      # The built-in coding workflow is untouched and still resolvable, so
      # coding tasks in this project keep loading.
      assert_equal :coding, Hive::Workflows::Registry.fetch(:coding).id
    end
  end

  def test_exact_legacy_bench_descriptor_cannot_override_builtin
    with_tmp_dir do |project_root|
      paths = write_legacy_bench_workflow(project_root)
      error = assert_raises(Hive::ConfigError) do
        capture_io { Hive::WorkflowSelection.fetch!("bench", project_root: project_root) }
      end
      assert_includes error.message, paths.fetch(:descriptor)
      assert_includes error.message, "collides with registered workflow :bench"
    end
  end

  def test_modified_legacy_bench_descriptor_still_surfaces_collision
    with_tmp_dir do |project_root|
      paths = write_legacy_bench_workflow(project_root)
      body = File.read(paths.fetch(:descriptor)).sub(
        "    instruction: ./bench/generate.md\n",
        "    instruction: ./bench/generate.md\n    timeout_sec: 42\n"
      )
      File.write(paths.fetch(:descriptor), body)

      error = assert_raises(Hive::ConfigError) do
        capture_io { Hive::WorkflowSelection.fetch!("bench", project_root: project_root) }
      end

      assert_includes error.message, paths.fetch(:descriptor)
      assert_includes error.message, "collides with registered workflow :bench"
    end
  end

  def test_load_tolerates_broken_project_config_for_task_fallback_paths
    with_tmp_dir do |project_root|
      FileUtils.mkdir_p(File.join(project_root, ".hive-state"))
      File.write(File.join(project_root, ".hive-state", "config.yml"), "default_workflow: [\n")
      # A descriptor sitting in the DEFAULT workflows dir must still load via the
      # fallback even though config.yml is unreadable (the fallback resolves to
      # `<root>/.hive-state/workflows`).
      write_project_workflow(project_root, "fallback-flow", stage_name: "build")

      _out, err = capture_io { Hive::Workflows::Project.load!(project_root) }

      assert_equal [ :coding, :content, :bench, :"patrol-fix", :"fallback-flow" ],
                   Hive::Workflows::Registry.ids,
                   "descriptors must load from the fallback dir when hive_state_path is unreadable"
      assert_match(/could not read hive_state_path/, err,
                   "the fallback must leave a stderr breadcrumb")
      assert_match(/falling back to/, err)
    end
  end

  def test_load_surfaces_unsupported_project_root_keys_instead_of_falling_back
    with_tmp_dir do |project_root|
      FileUtils.mkdir_p(File.join(project_root, ".hive-state"))
      File.write(File.join(project_root, ".hive-state", "config.yml"), "defualt_branch: main\n")

      error = assert_raises(Hive::ConfigError) do
        capture_io { Hive::Workflows::Project.load!(project_root) }
      end

      assert_includes error.message, "Unknown top-level key `defualt_branch`."
    end
  end

  def test_load_preserves_invalid_workflow_path_when_root_keys_are_supported
    with_tmp_dir do |project_root|
      FileUtils.mkdir_p(File.join(project_root, ".hive-state"))
      File.write(
        File.join(project_root, ".hive-state", "config.yml"),
        { "hive_state_path" => "bad\0state" }.to_yaml
      )

      error = assert_raises(ArgumentError) do
        Hive::Workflows::Project.load!(project_root)
      end

      assert_match(/null byte/, error.message)
    end
  end

  def test_workflow_dir_preserves_unsupported_project_config
    config_error = Hive::UnsupportedProjectConfigError.new("unsupported root key")

    error = with_replaced_singleton_method(
      Hive::Workflows::Loader, :workflow_dir, ->(*) { raise config_error }
    ) do
      assert_raises(Hive::UnsupportedProjectConfigError) do
        Hive::Workflows::Project.send(:workflow_dir_for, "/tmp/project")
      end
    end

    assert_same config_error, error
  end

  # The documented mid-load exception safety: load! drops @active_root to nil
  # BEFORE loading and re-sets it only after a clean load, so a load that raises
  # partway leaves @active_root nil — the next same-root load! re-attempts
  # rather than short-circuiting on a stale/empty registry.
  def test_load_reattempts_after_a_midload_raise_rather_than_serving_stale_registry
    with_tmp_dir do |project_root|
      workflows_dir = File.join(project_root, ".hive-state", "workflows")
      descriptor = project_descriptor("retry-flow")
      calls = 0

      with_replaced_singleton_method(Hive::Workflows::Loader, :workflow_dir, ->(_root, **) { workflows_dir }) do
        with_replaced_singleton_method(Hive::Workflows::Loader, :load_dir, lambda { |_dir|
          calls += 1
          raise Hive::ConfigError, "boom mid-load" if calls == 1

          { descriptor.id => descriptor }
        }) do
          assert_raises(Hive::ConfigError) { Hive::Workflows::Project.load!(project_root) }
          refute_includes Hive::Workflows::Registry.ids, :"retry-flow",
                          "the failed load must leave no overlay registered"

          Hive::Workflows::Project.load!(project_root)
          assert_includes Hive::Workflows::Registry.ids, :"retry-flow",
                          "a subsequent same-root load! must re-attempt, not short-circuit"
        end
      end

      assert_equal 2, calls, "the second load! must re-run load_dir, not serve a stale memo"
    end
  end

  # HIGH 2: the per-project overlay mutation (Registry.register! et al.) must run
  # INSIDE Project::LOCK. The web tier calls load! from both the StatusFeed
  # poller thread and per-request threads; an unsynchronized load! could clear
  # one project's overlay mid-resolve of another. Assert the registry mutation
  # observes the lock as held by the current thread (mon_owned?), proving the
  # critical section is synchronized — a deterministic alternative to a flaky
  # two-thread race.
  def test_load_mutates_registry_inside_the_lock
    with_tmp_dir do |project_root|
      write_project_workflow(project_root, "locked-flow")
      owned_during_mutation = nil

      original = Hive::Workflows::Registry.method(:register!)
      with_replaced_singleton_method(
        Hive::Workflows::Registry, :register!, lambda { |descriptor, **kwargs|
          owned_during_mutation = Hive::Workflows::Project::LOCK.mon_owned?
          original.call(descriptor, **kwargs)
        }
      ) do
        Hive::Workflows::Project.load!(project_root)
      end

      assert_equal true, owned_during_mutation,
                   "register! must run while the calling thread holds Project::LOCK"
    end
  end

  # HIGH 2: prove mutual exclusion, not just that the lock is acquired. While one
  # thread holds Project::LOCK, a second thread's load! must BLOCK (not mutate the
  # registry) until the lock is released — so a concurrent load!(other project)
  # can never swap the overlay out from under a mid-resolve reader.
  def test_load_blocks_while_another_thread_holds_the_lock
    with_tmp_dir do |project_root|
      write_project_workflow(project_root, "blocked-flow")
      holder_ready = Queue.new
      release = Queue.new
      loaded = false

      holder = Thread.new do
        Hive::Workflows::Project::LOCK.synchronize do
          holder_ready << true
          release.pop # hold the lock until the main thread signals
        end
      end

      holder_ready.pop # the helper thread now owns the lock
      loader = Thread.new do
        Hive::Workflows::Project.load!(project_root)
        loaded = true
      end

      # The loader cannot progress while the lock is held. Give it room to run;
      # if it ignored the lock it would set `loaded` here.
      assert_nil loader.join(0.2), "load! must block while another thread holds Project::LOCK"
      refute loaded, "load! must not mutate the registry while the lock is held"

      release << true # let the holder drop the lock
      holder.join
      loader.join(2)

      assert loaded, "load! must complete once the lock is released"
      assert_includes Hive::Workflows::Registry.ids, :"blocked-flow"
    end
  end

  def test_active_workflow_blocks_serialize_different_roots_for_the_full_reader_lifetime
    with_tmp_dir do |root_a|
      with_tmp_dir do |root_b|
        write_project_workflow(root_a, "flow-a", stage_name: "alpha")
        write_project_workflow(root_b, "flow-b", stage_name: "beta")
        entered_a = Queue.new
        attempted_b = Queue.new
        entered_b = Queue.new
        release_a = Queue.new

        reader_a = Thread.new do
          Hive::Workflows::Project.with_active_workflows(root_a) do |registry, stages|
            entered_a << true
            release_a.pop
            [ registry.ids, stages ]
          end
        end
        entered_a.pop
        reader_b = Thread.new do
          attempted_b << true
          Hive::Workflows::Project.with_active_workflows(root_b) do |registry, stages|
            entered_b << true
            [ registry.ids, stages ]
          end
        end
        attempted_b.pop

        assert_nil reader_b.join(0.1),
                   "root B must not enter while root A's reader block is active"
        assert entered_b.empty?
        release_a << true
        assert reader_a.join(2), "root A reader did not finish"
        assert reader_b.join(2), "root B reader did not finish"

        ids_a, stages_a = reader_a.value
        ids_b, stages_b = reader_b.value
        assert_includes ids_a, :"flow-a"
        refute_includes ids_a, :"flow-b"
        assert_includes stages_a, "alpha"
        refute_includes stages_a, "beta"
        assert_includes ids_b, :"flow-b"
        refute_includes ids_b, :"flow-a"
        assert_includes stages_b, "beta"
        refute_includes stages_b, "alpha"
      ensure
        release_a << true if release_a&.empty?
        reader_a&.kill if reader_a&.alive?
        reader_b&.kill if reader_b&.alive?
      end
    end
  end

  def test_consumer_exception_releases_the_operation_for_another_root
    with_tmp_dir do |root_a|
      with_tmp_dir do |root_b|
        write_project_workflow(root_a, "flow-a", stage_name: "alpha")
        write_project_workflow(root_b, "flow-b", stage_name: "beta")

        error = assert_raises(RuntimeError) do
          Hive::Workflows::Project.with_active_workflows(root_a) { raise "consumer failed" }
        end
        assert_equal "consumer failed", error.message

        reader_b = Thread.new do
          Hive::Workflows::Project.with_active_workflows(root_b) do |registry, stages|
            [ registry.ids, stages ]
          end
        end
        assert reader_b.join(2), "root B remained blocked after root A's consumer raised"
        ids, stages = reader_b.value
        assert_includes ids, :"flow-b"
        assert_includes stages, "beta"
      ensure
        reader_b&.kill if reader_b&.alive?
      end
    end
  end

  def test_outer_activation_reloads_descriptor_edits_deletions_and_empty_directory_switches
    with_tmp_dir do |project_root|
      descriptor_path = write_project_workflow(project_root, "mutable-flow", stage_name: "alpha")

      first_names = Hive::Workflows::Project.with_active_workflows(project_root) do |registry, stages|
        [ registry.ids, stages ]
      end
      assert_includes first_names.first, :"mutable-flow"
      assert_includes first_names.last, "alpha"

      write_project_workflow(project_root, "mutable-flow", stage_name: "bravo")
      edited_names = Hive::Workflows::Project.with_active_workflows(project_root) do |registry, stages|
        [ registry.ids, stages ]
      end
      assert_includes edited_names.first, :"mutable-flow"
      assert_includes edited_names.last, "bravo"
      refute_includes edited_names.last, "alpha"

      File.delete(descriptor_path)
      deleted_names = Hive::Workflows::Project.with_active_workflows(project_root) do |registry, stages|
        [ registry.ids, stages ]
      end
      refute_includes deleted_names.first, :"mutable-flow"
      refute_includes deleted_names.last, "bravo"

      state_a = File.join(project_root, ".empty-a")
      state_b = File.join(project_root, ".empty-b")
      FileUtils.mkdir_p(File.join(state_a, "workflows"))
      FileUtils.mkdir_p(File.join(state_b, "workflows"))
      config_path = File.join(project_root, ".hive-state", "config.yml")
      loaded_dirs = []
      original = Hive::Workflows::Loader.method(:load_dir)

      with_replaced_singleton_method(Hive::Workflows::Loader, :load_dir, lambda { |dir|
        loaded_dirs << dir
        original.call(dir)
      }) do
        File.write(config_path, { "hive_state_path" => ".empty-a" }.to_yaml)
        Hive::Workflows::Project.with_active_workflows(project_root) { nil }
        File.write(config_path, { "hive_state_path" => ".empty-b" }.to_yaml)
        Hive::Workflows::Project.with_active_workflows(project_root) { nil }
      end

      assert_equal [ File.join(state_a, "workflows"), File.join(state_b, "workflows") ],
                   loaded_dirs.last(2)
    end
  end

  def test_rejected_collision_keeps_siblings_and_becomes_accepted_after_repair
    with_tmp_dir do |project_root|
      rejected_path = write_project_workflow(project_root, "coding", stage_name: "collision-only")
      write_project_workflow(project_root, "sibling-flow", stage_name: "sibling")

      _out, warning = capture_io do
        Hive::Workflows::Project.with_active_workflows(project_root) do |registry, stages|
          assert_equal :coding, registry.fetch(:coding).id
          assert_includes registry.ids, :"sibling-flow"
          assert_includes stages, "sibling"
          refute_includes stages, "collision-only"
        end
      end
      assert_includes warning, "collides with registered workflow :coding"

      repaired_path = File.join(File.dirname(rejected_path), "repaired-flow.yml")
      repaired = File.read(rejected_path).sub("id: coding\n", "id: repaired-flow\n")
      File.write(rejected_path, repaired)
      File.rename(rejected_path, repaired_path)

      Hive::Workflows::Project.with_active_workflows(project_root) do |registry, stages|
        assert_includes registry.ids, :"sibling-flow"
        assert_includes registry.ids, :"repaired-flow"
        assert_includes stages, "sibling"
        assert_includes stages, "collision-only"
      end
    end
  end

  # The collision/parse skip warning is deduped per source_path: only the parse
  # result is cached, so register_descriptor re-runs on every load! that swaps
  # @active_root — without dedup a multi-project daemon alternating roots would
  # re-emit the breadcrumb every tick.
  def test_collision_skip_warn_is_emitted_once_per_source_path
    with_tmp_dir do |root_a|
      with_tmp_dir do |root_b|
        write_project_workflow(root_a, "coding")           # collides with built-in
        write_project_workflow(root_b, "flow-b", stage_name: "beta")

        _out, first = capture_io { Hive::Workflows::Project.load!(root_a) }
        assert_includes first, "collides with registered workflow :coding"

        capture_io { Hive::Workflows::Project.load!(root_b) } # swap overlay away

        _out, second = capture_io { Hive::Workflows::Project.load!(root_a) } # swap back → re-registers
        refute_includes second, "collides with registered workflow :coding",
                         "the skip breadcrumb must not re-emit on a later overlay swap"
      end
    end
  end

  # U9-3: an explicitly-named workflow whose descriptor collides with a built-in
  # must surface the real ConfigError at the resolution boundary, not silently
  # resolve to the built-in.
  def test_explicit_workflow_request_surfaces_builtin_collision_config_error
    with_tmp_dir do |project_root|
      path = write_project_workflow(project_root, "coding")

      error = assert_raises(Hive::ConfigError) do
        capture_io { Hive::WorkflowSelection.fetch!("coding", project_root: project_root) }
      end

      assert_includes error.message, path
      assert_includes error.message, "collides with registered workflow :coding"
    end
  end

  # U9-3: an explicitly-named workflow whose descriptor is malformed must
  # surface the real parse error, not a misleading "unknown workflow".
  def test_explicit_workflow_request_surfaces_malformed_descriptor_error
    with_tmp_dir do |project_root|
      workflows_dir = File.join(project_root, ".hive-state", "workflows")
      FileUtils.mkdir_p(workflows_dir)
      path = File.join(workflows_dir, "broken-flow.yml")
      File.write(path, "id: [\n")

      error = assert_raises(Hive::ConfigError) do
        capture_io { Hive::WorkflowSelection.fetch!("broken-flow", project_root: project_root) }
      end

      assert_includes error.message, path
      assert_includes error.message, "not valid YAML"
    end
  end

  # A clean, registered project descriptor resolves normally — the
  # resolution-boundary guard must not interfere with the happy path.
  def test_explicit_workflow_request_resolves_clean_descriptor
    with_tmp_dir do |project_root|
      write_project_workflow(project_root, "my-flow")

      assert_equal :"my-flow", Hive::WorkflowSelection.fetch!("my-flow", project_root: project_root).id
    end
  end

  def test_stages_for_project_reraises_ambiguous_short_name
    with_tmp_dir do |project_root|
      project = { "path" => project_root, "hive_state_path" => File.join(project_root, ".hive-state") }

      # `done` is the terminal short name of BOTH built-ins (coding 9-done,
      # content 6-done): ambiguous refs re-raise through stages_for_project —
      # classified by TYPE (AmbiguousStageRef), not by exception-message text.
      error = assert_raises(Hive::Workflows::AmbiguousStageRef) do
        Hive::Workflows.stages_for_project(project, stage_filter: "done")
      end

      assert_includes error.message, "ambiguous stage 'done'"
    end
  end

  def test_stages_for_project_tolerates_unknown_stage_filter
    with_tmp_dir do |project_root|
      project = { "path" => project_root, "hive_state_path" => File.join(project_root, ".hive-state") }

      assert_equal [], Hive::Workflows.stages_for_project(project, stage_filter: "nonexistent-stage"),
                   "a stage absent from this project must skip (return []), not abort the scan"
    end
  end

  def test_stages_for_project_returns_full_union_without_filter
    with_tmp_dir do |project_root|
      project = { "path" => project_root, "hive_state_path" => File.join(project_root, ".hive-state") }

      assert_equal Hive::Workflows.all_stage_dirs,
                   Hive::Workflows.stages_for_project(project, stage_filter: nil)
    end
  end

  def test_task_resolves_project_workflow_from_meta
    with_tmp_dir do |project_root|
      write_project_workflow(project_root, "my-flow")
      task_dir = File.join(project_root, ".hive-state", "stages", "2-work", "write-report-260621-abcd")
      FileUtils.mkdir_p(task_dir)
      Hive::TaskMeta.write(task_dir, id: 1, slug: File.basename(task_dir), display_name: nil, workflow: "my-flow")

      task = Hive::Task.new(task_dir)

      assert_equal :"my-flow", task.workflow.id
      assert_equal "work", task.stage_name
    end
  end

  def test_workflow_selection_loads_project_descriptors_and_reports_valid_names
    with_tmp_dir do |project_root|
      write_project_workflow(project_root, "my-flow")

      assert_equal :"my-flow", Hive::WorkflowSelection.fetch!("my-flow", project_root: project_root).id

      error = assert_raises(Hive::Workflows::UnknownWorkflow) do
        Hive::WorkflowSelection.fetch!("missing", project_root: project_root)
      end

      assert_includes error.valid, "my-flow"
      assert_includes error.message, "my-flow"
    end
  end

  def test_status_loads_project_descriptors_before_scanning_stage_union
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      write_project_workflow(project_root, "my-flow")
      task_dir = File.join(hive_state, "stages", "2-work", "status-task-260621-abcd")
      FileUtils.mkdir_p(task_dir)
      File.write(File.join(task_dir, "work.md"), "<!-- COMPLETE -->\n")
      Hive::TaskMeta.write(task_dir, id: 2, slug: File.basename(task_dir), display_name: nil, workflow: "my-flow")

      payload = Hive::Commands::Status.new.json_payload([
        { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      ])

      tasks = payload.fetch("projects").first.fetch("tasks")
      task = tasks.find { |candidate| candidate.fetch("slug") == "status-task-260621-abcd" }
      refute_nil task
      assert_equal "my-flow", task.fetch("workflow")
      assert_equal "2-work", task.fetch("stage")
    end
  end

  private

    def write_project_workflow(project_root, id, stage_name: "work")
      workflows_dir = File.join(project_root, ".hive-state", "workflows")
      instruction_dir = File.join(workflows_dir, id)
      FileUtils.mkdir_p(instruction_dir)
      File.write(File.join(instruction_dir, "#{stage_name}.md"), "Do #{stage_name}.\n")
      path = File.join(workflows_dir, "#{id}.yml")
      File.write(path, <<~YAML)
        id: #{id}
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
          - name: #{stage_name}
            kind: agent
            state_file: #{stage_name}.md
            instruction: ./#{id}/#{stage_name}.md
          - name: done
            kind: terminal
            state_file: done.md
      YAML
      path
    end

    def project_descriptor(id, stage_name: "work")
      Hive::Workflow.new(
        id: id.to_sym,
        stages: [
          Hive::Workflow::Stage.new(name: "inbox", index: 1, state_file: "idea.md", kind: :inert),
          Hive::Workflow::Stage.new(
            name: stage_name,
            index: 2,
            state_file: "#{stage_name}.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: stage_name),
            kind: :agent,
            instruction: "/tmp/#{stage_name}.md"
          )
        ]
      )
    end
end
