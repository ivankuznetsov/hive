require "test_helper"
require "hive/stages/execute"
require "hive/markers"

class HiveStagesExecuteTest < Minitest::Test
  include HiveTestHelper

  TaskStub = Struct.new(:folder, :state_file, :worktree_yml_path, :project_root, :slug, :reviews_dir, keyword_init: true)

  FakeGit = Struct.new(:head, :branch, :dirty, :ancestor_result, :raise_head, :raise_ancestor, keyword_init: true) do
    def head_sha
      raise Hive::GitError, "head failed" if raise_head

      head
    end

    def current_branch
      branch
    end

    def status_short
      dirty ? " M file.txt\n" : ""
    end

    def ancestor?(_base, _head)
      raise Hive::GitError, "ancestor failed" if raise_ancestor

      ancestor_result
    end
  end

  def test_run_exits_when_worktree_pointer_path_is_missing
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(task, "path" => File.join(dir, "missing-worktree"), "branch" => task.slug)

      _out, err, status = with_captured_exit { Hive::Stages::Execute.run!(task, {}) }

      assert_equal 1, status
      assert_includes err, "worktree pointer present but worktree missing"
    end
  end

  def test_run_pass_waits_when_new_head_is_not_descendant
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(task, "path" => File.join(dir, "worktree"), "branch" => task.slug, "execute_base_head" => "base")
      git = FakeGit.new(head: "new-head", branch: task.slug, dirty: false, ancestor_result: false)

      result = with_fake_git_and_spawn(git, status: :ok) do
        Hive::Stages::Execute.run_pass(task, {}, File.join(dir, "worktree"))
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "execute_waiting_head_not_descendant", status: :execute_waiting }, result)
      assert_equal :execute_waiting, marker.name
      assert_equal "head_not_descendant", marker.attrs["reason"]
    end
  end

  def test_run_pass_marks_error_when_ancestor_check_raises
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(task, "path" => File.join(dir, "worktree"), "branch" => task.slug, "execute_base_head" => "base")
      git = FakeGit.new(head: "new-head", branch: task.slug, dirty: false, ancestor_result: true, raise_ancestor: true)

      result = with_fake_git_and_spawn(git, status: :ok) do
        Hive::Stages::Execute.run_pass(task, {}, File.join(dir, "worktree"))
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "execute_worktree_git_failed", status: :error }, result)
      assert_equal :error, marker.name
      assert_equal "worktree_git_failed", marker.attrs["reason"]
    end
  end

  def test_execute_baseline_head_returns_nil_when_git_head_fails
    with_tmp_dir do |dir|
      task = build_task(dir)
      git = FakeGit.new(raise_head: true)

      assert_nil Hive::Stages::Execute.execute_baseline_head(task, git)
    end
  end

  def test_inspect_worktree_state_returns_nil_when_git_status_fails
    with_tmp_dir do |dir|
      task = build_task(dir)
      git = FakeGit.new(raise_head: true)

      assert_nil Hive::Stages::Execute.inspect_worktree_state(task, git)
    end
  end

  def test_append_implementation_output_inserts_before_terminal_marker
    with_tmp_dir do |dir|
      task = build_task(dir)
      File.write(task.state_file, "# Task\n\n<!-- AGENT_WORKING -->\n")

      Hive::Stages::Execute.append_implementation_output(task, final_message: "implementation summary")

      content = File.read(task.state_file)
      assert_match(/## Execute Output\n\nimplementation summary\n\n<!-- AGENT_WORKING -->\n\z/, content)
    end
  end

  def test_research_execution_returns_false_for_malformed_frontmatter
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task, "---\n:\n---\nbody\n")

      assert_equal false, Hive::Stages::Execute.research_execution?(task)
    end
  end

  def build_task(project_root)
    folder = File.join(project_root, ".hive-state", "stages", "4-execute", "demo-260522-aaaa")
    FileUtils.mkdir_p(folder)
    TaskStub.new(
      folder: folder,
      state_file: File.join(folder, "task.md"),
      worktree_yml_path: File.join(folder, "worktree.yml"),
      project_root: project_root,
      slug: "demo-260522-aaaa",
      reviews_dir: File.join(folder, "reviews")
    )
  end

  def write_plan(task, content = "# plan\n")
    File.write(File.join(task.folder, "plan.md"), content)
  end

  def write_pointer(task, attrs)
    File.write(task.worktree_yml_path, attrs.to_yaml)
  end

  def with_fake_git_and_spawn(git, status:)
    with_replaced_singleton_method(Hive::GitOps, :new, ->(_path) { git }) do
      with_replaced_singleton_method(Hive::Stages::Execute, :spawn_implementation, lambda { |_task, _cfg, _path|
        { status: status }
      }) do
        yield
      end
    end
  end
end
