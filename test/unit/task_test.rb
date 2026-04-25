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

  def test_state_file_per_stage
    with_tmp_dir do |dir|
      mappings = {
        "1-inbox" => "idea.md",
        "2-brainstorm" => "brainstorm.md",
        "3-plan" => "plan.md",
        "4-execute" => "task.md",
        "6-pr" => "pr.md",
        "7-done" => "task.md"
      }
      mappings.each do |stage_dir, state_file|
        folder = File.join(dir, ".hive-state", "stages", stage_dir, "x-260424-7a3b")
        FileUtils.mkdir_p(folder)
        task = Hive::Task.new(folder)
        assert_equal state_file, File.basename(task.state_file)
      end
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
      folder = File.join(dir, ".hive-state", "stages", "9-elsewhere", "x-260424-7a3b")
      FileUtils.mkdir_p(folder)
      assert_raises(Hive::InvalidTaskPath) { Hive::Task.new(folder) }
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
