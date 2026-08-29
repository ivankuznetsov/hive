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

  def test_detect_main_wiki_path_prefers_the_qmd_hive_wiki_collection
    with_tmp_dir do |root|
      project_root = File.join(root, "projects", "screenote")
      qmd_wiki = File.join(root, "projects", "hive", "wiki")
      legacy_wiki = File.join(root, "wikis", "master", "wiki")
      qmd_config = File.join(root, "config", "qmd", "index.yml")
      FileUtils.mkdir_p([ project_root, qmd_wiki, legacy_wiki, File.dirname(qmd_config) ])
      File.write(qmd_config, <<~YAML)
        collections:
          hive-wiki:
            path: #{qmd_wiki}
            pattern: "**/*.md"
      YAML

      detected = with_env("HOME" => root, "XDG_CONFIG_HOME" => File.dirname(File.dirname(qmd_config))) do
        Hive::LlmWikiBootstrap.detect_main_wiki_path(project_root)
      end

      assert_equal qmd_wiki, detected
    end
  end

  def test_ensure_config_replaces_a_stale_path_with_the_qmd_hive_wiki_collection
    with_tmp_dir do |root|
      project_root = File.join(root, "projects", "screenote")
      qmd_wiki = File.join(root, "projects", "hive", "wiki")
      llm_wiki_config = File.join(project_root, ".llm-wiki", "config.json")
      qmd_config = File.join(root, "config", "qmd", "index.yml")
      FileUtils.mkdir_p([ File.dirname(llm_wiki_config), qmd_wiki, File.dirname(qmd_config) ])
      File.write(
        llm_wiki_config,
        JSON.pretty_generate("main_wiki_path" => File.join(root, "deleted", "wiki"))
      )
      File.write(qmd_config, <<~YAML)
        collections:
          hive-wiki:
            path: #{qmd_wiki}
      YAML

      with_env("HOME" => root, "XDG_CONFIG_HOME" => File.dirname(File.dirname(qmd_config))) do
        Hive::LlmWikiBootstrap.ensure_config(project_root)
      end

      payload = JSON.parse(File.read(llm_wiki_config))
      assert_equal qmd_wiki, payload.fetch("main_wiki_path")
    end
  end

  def test_detect_main_wiki_path_treats_malformed_qmd_config_as_unavailable
    with_tmp_dir do |root|
      project_root = File.join(root, "projects", "screenote")
      legacy_wiki = File.join(root, "wikis", "master", "wiki")
      qmd_config = File.join(root, "config", "qmd", "index.yml")
      FileUtils.mkdir_p([ project_root, legacy_wiki, File.dirname(qmd_config) ])
      configs = [
        "collections: [\n",
        "collections: broken\n",
        "collections:\n  - hive-wiki\n",
        <<~YAML
          collections:
            hive-wiki:
              path: "~hive-user-that-does-not-exist/wiki"
        YAML
      ]

      with_env("HOME" => root, "XDG_CONFIG_HOME" => File.dirname(File.dirname(qmd_config))) do
        configs.each do |config|
          File.write(qmd_config, config)
          assert_equal legacy_wiki, Hive::LlmWikiBootstrap.detect_main_wiki_path(project_root)
        end
      end
    end
  end

  def test_detect_main_wiki_path_treats_unreadable_qmd_config_as_unavailable
    with_tmp_dir do |root|
      project_root = File.join(root, "projects", "screenote")
      legacy_wiki = File.join(root, "wikis", "master", "wiki")
      FileUtils.mkdir_p([ project_root, legacy_wiki ])

      detected = with_env("HOME" => root, "XDG_CONFIG_HOME" => File.join(root, "config")) do
        with_replaced_singleton_method(
          YAML, :safe_load_file, ->(*) { raise Errno::EACCES, "index.yml" }
        ) do
          Hive::LlmWikiBootstrap.detect_main_wiki_path(project_root)
        end
      end

      assert_equal legacy_wiki, detected
    end
  end

  def test_detect_main_wiki_path_falls_back_when_qmd_collection_is_missing
    with_tmp_dir do |root|
      project_root = File.join(root, "projects", "screenote")
      legacy_wiki = File.join(root, "wikis", "master", "wiki")
      qmd_config = File.join(root, "config", "qmd", "index.yml")
      FileUtils.mkdir_p([ project_root, legacy_wiki, File.dirname(qmd_config) ])
      File.write(qmd_config, <<~YAML)
        collections:
          hive-wiki:
            path: #{File.join(root, "deleted", "wiki")}
      YAML

      detected = with_env("HOME" => root, "XDG_CONFIG_HOME" => File.dirname(File.dirname(qmd_config))) do
        Hive::LlmWikiBootstrap.detect_main_wiki_path(project_root)
      end

      assert_equal legacy_wiki, detected
    end
  end

  def test_detect_main_wiki_path_resolves_relative_qmd_collection_paths
    with_tmp_dir do |root|
      project_root = File.join(root, "projects", "screenote")
      qmd_wiki = File.join(root, "projects", "hive", "wiki")
      qmd_config = File.join(root, "config", "qmd", "index.yml")
      FileUtils.mkdir_p([ project_root, qmd_wiki, File.dirname(qmd_config) ])
      File.write(qmd_config, <<~YAML)
        collections:
          hive-wiki:
            path: ../../projects/hive/wiki
      YAML

      detected = with_env("HOME" => root, "XDG_CONFIG_HOME" => File.dirname(File.dirname(qmd_config))) do
        Hive::LlmWikiBootstrap.detect_main_wiki_path(project_root)
      end

      assert_equal qmd_wiki, detected
    end
  end

  def test_ensure_config_preserves_a_valid_custom_main_wiki_path
    with_tmp_dir do |root|
      project_root = File.join(root, "projects", "screenote")
      custom_wiki = File.join(root, "custom", "wiki")
      qmd_wiki = File.join(root, "projects", "hive", "wiki")
      llm_wiki_config = File.join(project_root, ".llm-wiki", "config.json")
      qmd_config = File.join(root, "config", "qmd", "index.yml")
      FileUtils.mkdir_p([
        File.dirname(llm_wiki_config), custom_wiki, qmd_wiki, File.dirname(qmd_config)
      ])
      File.write(llm_wiki_config, JSON.generate("main_wiki_path" => custom_wiki))
      File.write(qmd_config, <<~YAML)
        collections:
          hive-wiki:
            path: #{qmd_wiki}
      YAML

      with_env("HOME" => root, "XDG_CONFIG_HOME" => File.dirname(File.dirname(qmd_config))) do
        Hive::LlmWikiBootstrap.ensure_config(project_root)
      end

      payload = JSON.parse(File.read(llm_wiki_config))
      assert_equal custom_wiki, payload.fetch("main_wiki_path")
    end
  end
end
