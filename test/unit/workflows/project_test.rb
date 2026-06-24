require "test_helper"
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

  def test_project_load_is_memoized_per_root
    with_tmp_dir do |project_root|
      workflows_dir = File.join(project_root, ".hive-state", "workflows")
      calls = 0
      descriptor = project_descriptor("memo-flow")

      with_replaced_singleton_method(Hive::Workflows::Loader, :workflow_dir, ->(_root) { workflows_dir }) do
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

  def test_load_tolerates_broken_project_config_for_task_fallback_paths
    with_tmp_dir do |project_root|
      FileUtils.mkdir_p(File.join(project_root, ".hive-state"))
      File.write(File.join(project_root, ".hive-state", "config.yml"), "default_workflow: [\n")
      # A descriptor sitting in the DEFAULT workflows dir must still load via the
      # fallback even though config.yml is unreadable (the fallback resolves to
      # `<root>/.hive-state/workflows`).
      write_project_workflow(project_root, "fallback-flow", stage_name: "build")

      _out, err = capture_io { Hive::Workflows::Project.load!(project_root) }

      assert_equal [ :coding, :content, :"fallback-flow" ], Hive::Workflows::Registry.ids,
                   "descriptors must load from the fallback dir when hive_state_path is unreadable"
      assert_match(/could not read hive_state_path/, err,
                   "the fallback must leave a stderr breadcrumb")
      assert_match(/falling back to/, err)
    end
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

      with_replaced_singleton_method(Hive::Workflows::Loader, :workflow_dir, ->(_root) { workflows_dir }) do
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
      # content 6-done): ambiguous refs re-raise through stages_for_project.
      error = assert_raises(Hive::InvalidTaskPath) do
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

    def project_descriptor(id)
      Hive::Workflow.new(
        id: id.to_sym,
        stages: [
          Hive::Workflow::Stage.new(name: "inbox", index: 1, state_file: "idea.md", kind: :inert),
          Hive::Workflow::Stage.new(
            name: "work",
            index: 2,
            state_file: "work.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "work"),
            kind: :agent,
            instruction: "/tmp/work.md"
          )
        ]
      )
    end
end
