require "test_helper"
require "hive/config"

class ConfigTest < Minitest::Test
  include HiveTestHelper

  def test_load_returns_defaults_when_no_config_file
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)
      assert_equal 4, cfg["max_review_passes"]
      assert_equal 10, cfg["budget_usd"]["brainstorm"]
      assert_equal 100, cfg["budget_usd"]["execute_implementation"]
      assert_equal dir, cfg["project_root"]
    end
  end

  def test_load_merges_per_project_overrides
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        default_branch: main
        max_review_passes: 6
        budget_usd:
          brainstorm: 20
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal "main", cfg["default_branch"]
      assert_equal 6, cfg["max_review_passes"]
      assert_equal 20, cfg["budget_usd"]["brainstorm"]
      assert_equal 20, cfg["budget_usd"]["plan"], "plan budget should fall back to default"
    end
  end

  def test_register_and_lookup_project
    with_tmp_global_config do |home|
      Hive::Config.register_project(name: "foo", path: "/tmp/foo")
      Hive::Config.register_project(name: "bar", path: "/tmp/bar")
      projects = Hive::Config.registered_projects
      assert_equal 2, projects.size, "two projects should be registered"
      assert_equal "/tmp/foo", projects.first["path"]
      assert Hive::Config.find_project("bar"), "find_project should locate registered project by name"
      refute Hive::Config.find_project("missing"), "find_project should return nil for unknown project"
      assert File.exist?(File.join(home, "config.yml"))
    end
  end

  def test_register_project_replaces_existing_by_name
    with_tmp_global_config do
      Hive::Config.register_project(name: "foo", path: "/tmp/old")
      Hive::Config.register_project(name: "foo", path: "/tmp/new")
      projects = Hive::Config.registered_projects
      assert_equal 1, projects.size
      assert_equal "/tmp/new", projects.first["path"]
    end
  end

  def test_load_raises_on_non_hash_yaml
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), "- a\n- b\n")
      assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
    end
  end
end
