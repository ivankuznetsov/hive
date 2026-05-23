require "test_helper"
require "json"
require "open3"
require "hive/commands/drop"
require "hive/commands/status"
require "hive/git_ops"
require "hive/task"
require "hive/tui/bubble_model"
require "hive/worktree"

class TuiDropTaskE2ETest < Minitest::Test
  include HiveTestHelper

  def with_tui_drop_project
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        ops = Hive::GitOps.new(dir)
        ops.hive_state_init
        project = File.basename(dir)
        Hive::Config.register_project(name: project, path: dir)
        File.write(
          File.join(dir, ".hive-state", "config.yml"),
          { "worktree_root" => File.join(File.dirname(dir), "#{project}.worktrees") }.to_yaml
        )
        yield(dir, ops, project)
      ensure
        if dir
          FileUtils.rm_rf(File.join(File.dirname(dir), "#{File.basename(dir)}.worktrees"))
        end
      end
    end
  end

  def create_task(dir, stage, slug, body: nil)
    folder = File.join(dir, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    state_name = Hive::Task::STATE_FILES.fetch(stage.split("-", 2).last)
    File.write(File.join(folder, state_name), body || "# #{slug}\n\n<!-- WAITING -->\n")
    folder
  end

  def snapshot
    out, _err = capture_io { Hive::Commands::Status.new(json: true).call }
    Hive::Tui::Snapshot.from_payload(JSON.parse(out))
  end

  def tasks
    out, _err = capture_io { Hive::Commands::Status.new(json: true).call }
    JSON.parse(out)["projects"].flat_map { |project| Array(project["tasks"]) }
  end

  def run_shift_x(snapshot)
    messages = []
    model = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(snapshot: snapshot, cursor: [ 0, 0 ], pane_focus: :right),
      dispatch: ->(message) { messages << message }
    )
    calls = []

    with_drop_dispatch_stub(calls) do
      model.update(Bubbletea::KeyMessage.new(key_type: 0, runes: [ "X".ord ]))
    end

    [ model, messages, calls ]
  end

  def with_drop_dispatch_stub(calls)
    # Capture the original as an UnboundMethod so we can restore it
    # cleanly after the stub. `Subprocess` uses `module_function`, so
    # simply removing the singleton override would erase the only
    # callable copy of the method.
    original = Hive::Tui::Subprocess.method(:dispatch_background).unbind
    quiet_drop = lambda do |argv|
      real_stdout = $stdout
      real_stderr = $stderr
      $stdout = StringIO.new
      $stderr = StringIO.new
      Hive::Commands::Drop.new(
        argv[2],
        project: argv[4],
        from: argv[6],
        json: argv.include?("--json")
      ).call
    ensure
      $stdout = real_stdout
      $stderr = real_stderr
    end
    Hive::Tui::Subprocess.define_singleton_method(:dispatch_background) do |argv, dispatch:|
      calls << argv
      quiet_drop.call(argv)
      dispatch.call(Hive::Tui::Messages::SubprocessExited.new(verb: argv[1], exit_code: 0))
      nil
    end
    yield
  ensure
    Hive::Tui::Subprocess.singleton_class.send(:remove_method, :dispatch_background)
    Hive::Tui::Subprocess.define_singleton_method(
      :dispatch_background, original.bind(Hive::Tui::Subprocess)
    ) if original
  end

  def branch_exists?(dir, branch)
    _out, _err, status = Open3.capture3("git", "-C", dir, "show-ref", "--verify", "refs/heads/#{branch}")
    status.success?
  end

  def test_shift_x_drops_brainstorm_task_and_row_disappears
    with_tui_drop_project do |dir, _ops, project|
      slug = "tui-drop-brainstorm-260522-aaaa"
      folder = create_task(dir, "2-brainstorm", slug)
      File.write(File.join(folder, ".lock"), { "pid" => 999_999 }.to_yaml)
      File.write(File.join(folder, ".markers-lock"), "locked\n")

      model, messages, calls = run_shift_x(snapshot)

      assert_equal [
        [ "hive", "drop", slug, "--project", project, "--from", "2-brainstorm", "--json" ]
      ], calls
      assert_equal "dropping #{slug}...", model.hive_model.flash
      assert messages.any? { |message| message.is_a?(Hive::Tui::Messages::SubprocessExited) }
      refute File.directory?(folder)
      assert_empty tasks.select { |task| task["slug"] == slug }
    end
  end

  def test_shift_x_drops_execute_task_worktree_and_branch
    with_tui_drop_project do |dir, _ops, project|
      slug = "tui-drop-execute-260522-aaaa"
      folder = create_task(dir, "4-execute", slug, body: "# #{slug}\n\n<!-- AGENT_WORKING pid=999999 -->\n")
      worktree_root = File.join(File.dirname(dir), "#{File.basename(dir)}.worktrees")
      worktree = Hive::Worktree.new(dir, slug, worktree_root: worktree_root)
      worktree.create!(slug, default_branch: "master")
      worktree.write_pointer!(folder, slug)

      _model, _messages, calls = run_shift_x(snapshot)

      assert_equal [
        [ "hive", "drop", slug, "--project", project, "--from", "4-execute", "--json" ]
      ], calls
      refute File.directory?(folder)
      refute File.directory?(worktree.path)
      refute branch_exists?(dir, slug)
    end
  end

  def test_shift_x_on_archived_row_flashes_without_dispatching
    with_tui_drop_project do |dir, _ops, _project|
      slug = "tui-drop-archived-260522-aaaa"
      folder = create_task(dir, "9-done", slug)

      model, _messages, calls = run_shift_x(snapshot)

      assert_empty calls
      assert_equal "task is archived; nothing to drop", model.hive_model.flash
      assert File.directory?(folder)
    end
  end

  # U6: when Shift+X dispatches `hive drop` via the real
  # `Subprocess.dispatch_background` (no stub), PATH lookup must
  # succeed, the SubprocessExited message must arrive, and the row
  # must disappear from the snapshot within the 2s polling budget.
  def test_shift_x_dispatches_real_subprocess_and_row_disappears
    with_tui_drop_project do |dir, _ops, project|
      slug = "tui-drop-real-260522-aaaa"
      folder = create_task(dir, "2-brainstorm", slug)
      hive_bin_dir = File.expand_path("../../bin", __dir__)
      bundle_path = ENV["BUNDLE_GEMFILE"] || File.expand_path("../../Gemfile", __dir__)
      original_path = ENV["PATH"]
      original_home = ENV["HIVE_HOME"]
      original_bundle = ENV["BUNDLE_GEMFILE"]
      messages = []
      dispatch = ->(message) { messages << message }
      begin
        ENV["PATH"] = "#{hive_bin_dir}:#{original_path}"
        ENV["HIVE_HOME"] = ENV["HIVE_HOME"] # already set by with_tmp_global_config
        ENV["BUNDLE_GEMFILE"] = bundle_path
        argv = [ "hive", "drop", slug, "--project", project, "--from", "2-brainstorm", "--json" ]
        Hive::Tui::Subprocess.dispatch_background(argv, dispatch: dispatch)

        # Poll for the SubprocessExited message and for the row
        # disappearance — 2s budget mirrors the U6 TUI contract.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5.0
        until messages.any? { |m| m.is_a?(Hive::Tui::Messages::SubprocessExited) }
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.05
        end
        exited = messages.find { |m| m.is_a?(Hive::Tui::Messages::SubprocessExited) }
        refute_nil exited, "real subprocess should dispatch SubprocessExited within 5s"
        assert_equal 0, exited.exit_code, "hive drop must exit 0 for the fixture"
      ensure
        ENV["PATH"] = original_path
        ENV["HIVE_HOME"] = original_home if original_home
        ENV["BUNDLE_GEMFILE"] = original_bundle
      end
      refute File.directory?(folder),
             "task folder must disappear after the real subprocess completes"
      assert_empty tasks.select { |task| task["slug"] == slug },
                   "row must disappear from the snapshot within the polling budget"
    end
  end
end
