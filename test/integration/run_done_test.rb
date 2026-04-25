require "test_helper"
require "hive/commands/init"
require "hive/commands/run"

class RunDoneTest < Minitest::Test
  include HiveTestHelper

  def test_done_prints_cleanup_with_pointer
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "feat-x-260424-aaaa"
        done_dir = File.join(dir, ".hive-state", "stages", "7-done", slug)
        FileUtils.mkdir_p(done_dir)
        File.write(File.join(done_dir, "task.md"), "## work\n<!-- EXECUTE_COMPLETE -->\n")
        File.write(File.join(done_dir, "worktree.yml"),
                   { "path" => "/tmp/wt-feat-x", "branch" => slug }.to_yaml)
        out, _err = capture_io { Hive::Commands::Run.new(done_dir).call }
        assert_includes out, "git worktree remove /tmp/wt-feat-x"
        assert_includes out, "git branch -d #{slug}"
        assert_equal :complete, Hive::Markers.current(File.join(done_dir, "task.md")).name
      end
    end
  end

  def test_done_without_pointer_archives
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "feat-y-260424-aaaa"
        done_dir = File.join(dir, ".hive-state", "stages", "7-done", slug)
        FileUtils.mkdir_p(done_dir)
        out, _err = capture_io { Hive::Commands::Run.new(done_dir).call }
        assert_includes out, "archived"
      end
    end
  end
end
