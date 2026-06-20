require "test_helper"
require "hive/config"
require "hive/task"

class TaskTest < Minitest::Test
  include HiveTestHelper

  def test_parses_valid_path
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", "add-foo")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)
      assert_equal "add-foo", task.slug
      assert_equal "brainstorm", task.stage_name
      assert_equal 2, task.stage_index
      assert_equal File.join(folder, "brainstorm.md"), task.state_file
      assert_equal dir, task.project_root
    end
  end

  def test_path_helpers_use_task_and_state_directories
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "4-execute", "add-foo")
      FileUtils.mkdir_p(folder)

      task = Hive::Task.new(folder)

      assert_equal File.join(folder, ".lock"), task.lock_file
      assert_equal File.join(dir, ".hive-state", ".commit-lock"), task.commit_lock_file
    end
  end

  def test_state_file_per_stage
    with_tmp_dir do |dir|
      mappings = {
        "1-inbox" => "idea.md",
        "2-brainstorm" => "brainstorm.md",
        "3-plan" => "plan.md",
        "4-execute" => "task.md",
        "5-open-pr" => "pr.md",
        "6-review" => "task.md",
        "7-artifacts" => "artifact.md",
        "8-finalize" => "pr.md",
        "9-done" => "task.md"
      }
      mappings.each do |stage_dir, state_file|
        folder = File.join(dir, ".hive-state", "stages", stage_dir, "x-260424-7a3b")
        FileUtils.mkdir_p(folder)
        task = Hive::Task.new(folder)
        stage_name = stage_dir.split("-", 2).last

        assert_equal :coding, task.workflow.id
        assert_equal Hive::Task::STAGE_NAMES, task.stage_names
        assert_equal File.join(folder, Hive::Task::STATE_FILES.fetch(stage_name)), task.state_file
        assert_equal state_file, File.basename(task.state_file)
      end
    end
  end

  def test_rejects_stage_index_mismatch
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "3-brainstorm", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)

      error = assert_raises(Hive::InvalidTaskPath) { Hive::Task.new(folder) }

      assert_equal Hive::ExitCodes::USAGE, error.exit_code
      assert_match(/stage directory 3-brainstorm/, error.message)
      assert_match(/expected 2-brainstorm/, error.message)
    end
  end

  def test_invalid_path_without_hive_state_segment
    assert_raises(Hive::InvalidTaskPath) { Hive::Task.new("/tmp/random/path") }
  end

  def test_invalid_path_without_slug
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "2-brainstorm")
      FileUtils.mkdir_p(folder)
      assert_raises(Hive::InvalidTaskPath) { Hive::Task.new(folder) }
    end
  end

  def test_invalid_stage_format
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "brainstorm", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)
      assert_raises(Hive::InvalidTaskPath) { Hive::Task.new(folder) }
    end
  end

  def test_invalid_stage_name
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "4-nonsense", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)
      error = assert_raises(Hive::InvalidTaskPath) { Hive::Task.new(folder) }

      assert_match(/unknown stage name: 4-nonsense/, error.message)
      assert_match(/workflow :coding/, error.message)
    end
  end

  def test_meta_workflow_selector_resolves_task_workflow
    with_tmp_dir do |dir|
      with_registered_workflow(research_workflow) do
        folder = File.join(dir, ".hive-state", "stages", "2-gather", "x-260424-7a3b")
        FileUtils.mkdir_p(folder)
        File.write(File.join(folder, "meta.yml"), "workflow: research\n")

        task = Hive::Task.new(folder)

        assert_equal :research, task.workflow.id
        assert_equal %w[intake gather report], task.stage_names
        assert_equal File.join(folder, "notes.md"), task.state_file
      end
    end
  end

  def test_project_default_workflow_resolves_fieldless_task
    with_tmp_dir do |dir|
      with_registered_workflow(research_workflow) do
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), "default_workflow: research\n")
        folder = File.join(dir, ".hive-state", "stages", "2-gather", "x-260424-7a3b")
        FileUtils.mkdir_p(folder)

        task = Hive::Task.new(folder)

        assert_equal :research, task.workflow.id
        assert_equal %w[intake gather report], task.stage_names
        assert_equal File.join(folder, "notes.md"), task.state_file
      end
    end
  end

  def test_blank_task_workflow_selector_falls_back_to_project_default
    with_tmp_dir do |dir|
      with_registered_workflow(research_workflow) do
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), "default_workflow: research\n")
        folder = File.join(dir, ".hive-state", "stages", "2-gather", "x-260424-7a3b")
        FileUtils.mkdir_p(folder)
        File.write(File.join(folder, "meta.yml"), "workflow: \"  \"\n")

        task = Hive::Task.new(folder)

        assert_equal :research, task.workflow.id
      end
    end
  end

  def test_blank_project_default_workflow_resolves_to_coding
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), "default_workflow: \"  \"\n")
      folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)

      task = Hive::Task.new(folder)

      assert_equal :coding, task.workflow.id
    end
  end

  def test_unknown_workflow_selector_raises_invalid_task_path
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"), "workflow: nope\n")

      error = assert_raises(Hive::InvalidTaskPath) { Hive::Task.new(folder) }

      assert_equal Hive::ExitCodes::USAGE, error.exit_code
      assert_match(/unknown workflow :nope/, error.message)
    end
  end

  def test_unknown_project_default_workflow_raises_invalid_task_path
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), "default_workflow: nope\n")
      folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)

      error = assert_raises(Hive::InvalidTaskPath) { Hive::Task.new(folder) }

      assert_equal Hive::ExitCodes::USAGE, error.exit_code
      assert_match(/unknown workflow :nope/, error.message)
    end
  end

  def test_malformed_meta_yaml_falls_back_to_coding
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"), "workflow: [unterminated\n")

      task = nil
      _out, err = capture_io { task = Hive::Task.new(folder) }

      assert_equal :coding, task.workflow.id
      assert_match(/task_meta: failed to read/, err)
    end
  end

  def test_broken_project_config_default_workflow_falls_back_to_coding
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), "dependency_gate_stage: 7-artifacts\n")
      folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)

      task = nil
      _out, err = capture_io { task = Hive::Task.new(folder) }

      assert_equal :coding, task.workflow.id
      assert_match(/failed to read default_workflow/, err)
      assert_match(/falling back to coding/, err)
    end
  end

  def test_worktree_path_uses_yml_when_present
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "4-execute", "add-foo")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "worktree.yml"),
                 { "path" => "/some/where/add-foo", "branch" => "add-foo" }.to_yaml)
      task = Hive::Task.new(folder)
      assert_equal "/some/where/add-foo", task.worktree_path
    end
  end

  def test_meta_readers_use_sidecar_when_present
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "1-inbox", "add-foo")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"),
                 { "id" => 42, "slug" => "add-foo", "display_name" => "Add Foo" }.to_yaml)

      task = Hive::Task.new(folder)

      assert_equal File.join(folder, "meta.yml"), task.meta_yml_path
      assert_equal 42, task.id
      assert_equal "Add Foo", task.display_name
      assert_nil task.depends_on
      assert_equal "Add Foo", task.display_label
    end
  end

  def test_depends_on_reader_uses_sidecar
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "1-inbox", "add-foo")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"),
                 { "id" => 42, "slug" => "add-foo", "depends_on" => "base-task" }.to_yaml)

      task = Hive::Task.new(folder)

      assert_equal "base-task", task.depends_on
    end
  end

  def test_meta_readers_fall_back_when_sidecar_absent_or_malformed
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "1-inbox", "add-foo")
      FileUtils.mkdir_p(folder)

      task = Hive::Task.new(folder)
      assert_nil task.id
      assert_nil task.display_name
      assert_nil task.depends_on
      assert_equal "add-foo", task.display_label

      File.write(File.join(folder, "meta.yml"), ":\n:not yaml")
      task = Hive::Task.new(folder)
      assert_nil task.id
      assert_nil task.display_name
      assert_nil task.depends_on
      assert_equal "add-foo", task.display_label
    end
  end

  def test_worktree_path_returns_nil_for_low_stages
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "1-inbox", "add-foo")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)
      assert_nil task.worktree_path
    end
  end

  def test_worktree_path_derives_from_template_when_yml_absent
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"),
                 { "worktree_root" => "/work/%{slug}" }.to_yaml)
      folder = File.join(dir, ".hive-state", "stages", "4-execute", "add-foo")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)
      derived = task.worktree_path
      assert_includes derived, "add-foo"
    end
  end
end
