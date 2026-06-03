require "test_helper"
require "json"
require "hive/config"
require "hive/patrol/mapper"

class HivePatrolMapperTest < Minitest::Test
  include HiveTestHelper

  def cfg(overrides = {})
    Hive::Config.deep_merge(Hive::Config.deep_dup(Hive::Config::DEFAULTS), overrides)
  end

  def test_maps_routes_commands_packages_and_tests
    with_tmp_git_repo do |repo|
      FileUtils.mkdir_p(File.join(repo, "app/users"))
      FileUtils.mkdir_p(File.join(repo, "test"))
      FileUtils.mkdir_p(File.join(repo, "bin"))
      File.write(File.join(repo, "app/users/page.tsx"), "export default function Page() {}\n")
      File.write(File.join(repo, "test/users_test.rb"), "assert true\n")
      File.write(File.join(repo, "bin/tool"), "#!/usr/bin/env ruby\n")
      File.write(File.join(repo, "package.json"), JSON.generate(
        "bin" => { "tool" => "bin/tool" },
        "scripts" => { "test" => "node --test" }
      ))
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "fixture", "--quiet")

      features = Hive::Patrol::Mapper.new(repo, cfg: cfg).call
      ids = features.map(&:id)

      assert_includes ids, "route-app-users-page-tsx"
      assert_includes ids, "command-bin-tool"
      assert_includes ids, "command-npm-script-test"
      assert_includes ids, "package-package-json"
      assert_includes ids, "test-suite-test-users-test-rb"
      assert File.exist?(File.join(repo, ".hive-state", "patrol", "features", "route-app-users-page-tsx.json"))
    end
  end

  def test_ids_are_stable_across_runs
    with_tmp_git_repo do |repo|
      FileUtils.mkdir_p(File.join(repo, "pages"))
      File.write(File.join(repo, "pages/index.tsx"), "export default function Page() {}\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "route", "--quiet")

      first = Hive::Patrol::Mapper.new(repo, cfg: cfg).call.map(&:id)
      second = Hive::Patrol::Mapper.new(repo, cfg: cfg).call.map(&:id)

      assert_equal first, second
    end
  end

  def test_empty_repo_returns_empty_map
    with_tmp_git_repo do |repo|
      run!("git", "-C", repo, "rm", "README.md", "--quiet")
      run!("git", "-C", repo, "commit", "-m", "empty", "--quiet")

      assert_empty Hive::Patrol::Mapper.new(repo, cfg: cfg).call
    end
  end

  def test_maps_python_swift_rust_go_and_manifest_commands
    with_tmp_git_repo do |repo|
      FileUtils.mkdir_p(File.join(repo, "api"))
      FileUtils.mkdir_p(File.join(repo, "cmd/tool"))
      FileUtils.mkdir_p(File.join(repo, "src/bin"))
      File.write(File.join(repo, "api/app.py"), "@app.get('/x')\ndef x(): pass\n")
      File.write(File.join(repo, "pyproject.toml"), "[project.scripts]\nship = \"pkg:main\"\n[tool.other]\n")
      File.write(File.join(repo, "Package.swift"), ".executableTarget(name: \"swift-tool\")\n")
      File.write(File.join(repo, "cmd/tool/main.go"), "package main\n")
      File.write(File.join(repo, "src/main.rs"), "fn main() {}\n")
      File.write(File.join(repo, "src/bin/side.rs"), "fn main() {}\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "multi", "--quiet")

      ids = Hive::Patrol::Mapper.new(repo, cfg: cfg).call.map(&:id)

      assert_includes ids, "route-api-app-py"
      assert_includes ids, "command-python-script-ship"
      assert_includes ids, "command-swift-executable-swift-tool"
      assert_includes ids, "command-cmd-tool-main-go"
      assert_includes ids, "command-src-main-rs"
      assert_includes ids, "command-src-bin-side-rs"
    end
  end

  def test_untracked_fallback_and_missing_read
    with_tmp_dir do |repo|
      FileUtils.mkdir_p(File.join(repo, "pages"))
      File.write(File.join(repo, "pages/home.tsx"), "export default function Home() {}\n")
      mapper = Hive::Patrol::Mapper.new(repo, cfg: cfg)

      assert_includes mapper.call.map(&:id), "route-pages-home-tsx"
      assert_equal "", mapper.send(:read, "missing.rb")
    end
  end
end
