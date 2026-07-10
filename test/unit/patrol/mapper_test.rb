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

  def test_documentation_capability_maps_stable_bounded_slices_without_churn_artifacts
    with_tmp_git_repo do |repo|
      write_docs_fixture(repo)
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "docs", "--quiet")

      ordinary = Hive::Patrol::Mapper.new(repo, cfg: cfg, dry_run: true).call
      first = Hive::Patrol::Mapper.new(
        repo, cfg: cfg, dry_run: true, capabilities: [ :documentation ]
      ).call
      second = Hive::Patrol::Mapper.new(
        repo, cfg: cfg, dry_run: true, capabilities: [ :documentation ]
      ).call

      assert_empty ordinary, "ordinary patrol must not map documentation features"
      assert_equal first.map(&:id), second.map(&:id)
      assert_includes first.map(&:id), "documentation-root"
      assert_includes first.map(&:id), "documentation-docs-guides"
      assert_includes first.map(&:id), "documentation-docs-adr"
      assert_includes first.map(&:id), "documentation-wiki-root"
      assert_includes first.map(&:id), "documentation-wiki-decisions"
      mapped = first.flat_map { |feature| feature.owned_files + feature.context_files }
      refute_includes mapped, "wiki/log.md"
      refute_includes mapped, "wiki/log.d/20260710.md"
      refute_includes mapped, "raw/notes/scratch.md"
      refute_includes mapped, ".cache/generated.md"
      assert first.all? { |feature| feature.owned_files.size <= 12 && feature.context_files.size <= 24 }
    end
  end

  def test_documentation_changes_keep_removed_and_renamed_paths_in_their_stable_slice
    with_tmp_git_repo do |repo|
      FileUtils.mkdir_p(File.join(repo, "docs", "guides"))
      File.write(File.join(repo, "docs", "old.md"), "old\n")
      File.write(File.join(repo, "docs", "reference.md"), "reference\n")
      File.write(File.join(repo, "docs", "guides", "before.md"), "before\n")
      File.write(File.join(repo, "package.json"), JSON.generate("scripts" => { "test" => "node --test" }))
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "docs", "--quiet")
      FileUtils.rm_f(File.join(repo, "docs", "old.md"))
      FileUtils.mv(File.join(repo, "docs", "guides", "before.md"), File.join(repo, "docs", "guides", "after.md"))
      run!("git", "-C", repo, "add", "-A")

      features = Hive::Patrol::Mapper.new(
        repo,
        cfg: cfg,
        dry_run: true,
        capabilities: [ :documentation ],
        documentation_changes: [
          { "path" => "docs/old.md", "status" => "removed" },
          { "path" => "docs/guides/after.md", "previous_path" => "docs/guides/before.md", "status" => "renamed" }
        ]
      ).call

      root = features.find { |feature| feature.id == "documentation-docs-root" }
      guides = features.find { |feature| feature.id == "documentation-docs-guides" }
      assert_equal [ "docs/old.md" ], root.owned_files
      assert_includes root.context_files, "docs/reference.md"
      assert_equal [ "docs/guides/after.md", "docs/guides/before.md" ], guides.owned_files
      assert_includes features.map(&:id), "package-package-json", "manifest docs must map alongside repository code features"
    end
  end

  def test_architecture_capability_adds_components_and_stops_command_sibling_ownership
    with_tmp_git_repo do |repo|
      FileUtils.mkdir_p(File.join(repo, "bin"))
      FileUtils.mkdir_p(File.join(repo, "lib", "acme"))
      File.write(File.join(repo, "bin", "one"), "#!/usr/bin/env ruby\n")
      File.write(File.join(repo, "bin", "two"), "#!/usr/bin/env ruby\n")
      File.write(File.join(repo, "package.json"), JSON.generate("bin" => { "one" => "bin/one" }))
      File.write(File.join(repo, "lib", "acme", "service.rb"), "module Acme::Service\nend\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "architecture", "--quiet")

      ordinary = Hive::Patrol::Mapper.new(repo, cfg: cfg, dry_run: true).call
      architecture = Hive::Patrol::Mapper.new(
        repo, cfg: cfg, dry_run: true, capabilities: [ :architecture ]
      ).call

      ordinary_one = ordinary.find { |feature| feature.id == "command-bin-one" }
      architecture_one = architecture.find { |feature| feature.id == "command-bin-one" }
      assert_includes ordinary_one.owned_files, "bin/two", "ordinary patrol behavior remains compatible"
      assert_equal [ "bin/one" ], architecture_one.owned_files
      assert_includes architecture.map(&:id), "architecture-lib-acme-service-rb"
    end
  end

  private

  def write_docs_fixture(repo)
    %w[docs/guides docs/adr wiki/decisions wiki/log.d raw/notes .cache].each do |dir|
      FileUtils.mkdir_p(File.join(repo, dir))
    end
    {
      "docs/guides/start.md" => "start\n",
      "docs/adr/0001.md" => "decision\n",
      "wiki/index.md" => "index\n",
      "wiki/decisions/one.md" => "decision\n",
      "wiki/log.md" => "compiled\n",
      "wiki/log.d/20260710.md" => "fragment\n",
      "raw/notes/scratch.md" => "raw\n",
      ".cache/generated.md" => "cache\n"
    }.each { |path, body| File.write(File.join(repo, path), body) }
  end
end
