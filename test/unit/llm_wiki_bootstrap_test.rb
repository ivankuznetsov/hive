require "test_helper"
require "hive/llm_wiki_bootstrap"

class LlmWikiBootstrapTest < Minitest::Test
  include HiveTestHelper

  def test_git_common_dir_reports_git_resolution_failure
    status = Object.new
    status.define_singleton_method(:success?) { false }

    error = with_replaced_singleton_method(
      Open3, :capture3, ->(*_argv) { [ "", "not a Git repository", status ] }
    ) do
      assert_raises(ArgumentError) do
        Hive::LlmWikiBootstrap.git_common_dir("/tmp/not-a-repository")
      end
    end

    assert_match(/cannot resolve Git common directory/, error.message)
    assert_match(/not a Git repository/, error.message)
  end

  def test_primary_worktree_root_reports_git_resolution_failure
    status = Object.new
    status.define_singleton_method(:success?) { false }

    error = with_replaced_singleton_method(
      Open3, :capture3, ->(*_argv) { [ "", "not a Git repository", status ] }
    ) do
      assert_raises(ArgumentError) do
        Hive::LlmWikiBootstrap.primary_worktree_root("/tmp/not-a-repository")
      end
    end

    assert_match(/cannot resolve primary Git worktree/, error.message)
    assert_match(/not a Git repository/, error.message)
  end

  def test_managed_path_validation_rejects_a_regular_file_parent
    with_tmp_dir do |root|
      parent = File.join(root, ".llm-wiki")
      File.write(parent, "not a directory\n")

      error = assert_raises(Hive::ConfigError) do
        Hive::LlmWikiBootstrap.validate_project_managed_paths!(root)
      end

      assert_includes error.message, "managed parent"
      assert_includes error.message, "must be a directory"
      assert_equal "not a directory\n", File.read(parent)
    end
  end

  def test_managed_file_write_translates_nofollow_errors
    with_tmp_dir do |root|
      path = File.join(root, ".llm-wiki", "config.json")

      with_replaced_singleton_method(
        File, :open, ->(*_args) { raise Errno::ELOOP, path }
      ) do
        error = assert_raises(Hive::ConfigError) do
          Hive::LlmWikiBootstrap.write_file(path, "{}\n")
        end
        assert_includes error.message, "managed file"
        assert_includes error.message, "must not be a symlink"
      end
    end
  end
end
