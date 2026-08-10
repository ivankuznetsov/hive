require "test_helper"
require "json"
require "timeout"
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
      assert_includes ids, "command-package-json-scripts"
      assert_includes ids, "package-package-json"
      assert_includes ids, "test-suite-test-users-test-rb"
      assert File.exist?(File.join(repo, ".hive-state", "patrol", "features", "route-app-users-page-tsx.json"))
    end
  end

  def test_babysitter_stub_features_include_their_behavioral_tests
    with_tmp_git_repo do |repo|
      %w[bin test/unit/babysitter test/babysitter/acceptance].each do |dir|
        FileUtils.mkdir_p(File.join(repo, dir))
      end
      File.write(File.join(repo, "bin", "hive-babysitter-skip-log.rb"), "# helper\n")
      File.write(File.join(repo, "test", "unit", "babysitter", "dry_run_env_test.rb"), "# unit\n")
      File.write(File.join(repo, "test", "babysitter", "acceptance", "dry_run_test.rb"), "# acceptance\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "babysitter fixture", "--quiet")

      feature = Hive::Patrol::Mapper.new(repo, cfg: cfg).call.find do |candidate|
        candidate.entrypoints.include?("bin/hive-babysitter-skip-log.rb")
      end

      assert_equal %w[
        test/unit/babysitter/dry_run_env_test.rb
        test/babysitter/acceptance/dry_run_test.rb
      ], feature.tests
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
      assert_includes ids, "command-pyproject-scripts"
      assert_includes ids, "command-package-swift-executables"
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

  def test_path_entry_probe_distinguishes_existing_and_missing_paths
    with_tmp_dir do |repo|
      File.write(File.join(repo, "present.md"), "present\n")
      mapper = Hive::Patrol::Mapper.new(repo, cfg: cfg, dry_run: true)

      assert mapper.send(:path_entry_exists?, "present.md")
      refute mapper.send(:path_entry_exists?, "missing.md")
    end
  end

  # git ls-files emits raw filename bytes; a Latin-1 name used to raise
  # ArgumentError from split/tr once the invalid byte hit UTF-8 string ops.
  def test_latin1_filename_bytes_from_git_are_tolerated_without_raising
    with_tmp_git_repo do |repo|
      FileUtils.mkdir_p(File.join(repo, "pages"))
      File.write(File.join(repo, "pages/index.tsx"), "export default function Page() {}\n")
      File.binwrite(File.join(repo.b, "caf\xE9.rb".b), "class Cafe\nend\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "latin1", "--quiet")

      features = Hive::Patrol::Mapper.new(repo, cfg: cfg).call

      assert_includes features.map(&:id), "route-pages-index-tsx"
      owned = features.flat_map(&:owned_files)
      refute owned.any? { |path| path.include?("�") },
             "a scrubbed non-UTF-8 name must be dropped, not claimed as owned"
    end
  end

  def test_mapping_confines_tracked_symlinks_and_bounds_every_content_read
    with_tmp_git_repo do |repo|
      Dir.mktmpdir("patrol-mapper-outside") do |outside|
        File.write(File.join(outside, "package.json"), JSON.generate("scripts" => { "leak" => "cat ~/.ssh/id_rsa" }))
        File.write(File.join(outside, "external.py"), "@app.get('/outside')\ndef outside(): pass\n")
        File.write(File.join(outside, "external.md"), "outside documentation\n")

        FileUtils.mkdir_p(File.join(repo, "api"))
        FileUtils.mkdir_p(File.join(repo, "docs"))
        FileUtils.mkdir_p(File.join(repo, "safe"))
        File.write(File.join(repo, "safe", "route.py"), "@app.get('/inside')\ndef inside(): pass\n")
        File.write(File.join(repo, "docs", "safe.md"), "safe documentation\n")
        File.symlink("../safe/route.py", File.join(repo, "api", "internal.py"))
        File.symlink("safe.md", File.join(repo, "docs", "internal.md"))
        File.symlink(File.join(outside, "package.json"), File.join(repo, "package.json"))
        File.symlink(File.join(outside, "external.py"), File.join(repo, "api", "external.py"))
        File.symlink(File.join(outside, "external.md"), File.join(repo, "docs", "external.md"))
        File.symlink("/dev/zero", File.join(repo, "api", "device.py")) if File.exist?("/dev/zero")

        cap = Hive::Patrol::SourceReader::MAX_SOURCE_BYTES
        File.write(File.join(repo, "bounded.flux"), ("a" * cap) + "TAIL")
        run!("git", "-C", repo, "add", ".")
        run!("git", "-C", repo, "commit", "-m", "symlink boundaries", "--quiet")

        mapper = Hive::Patrol::Mapper.new(
          repo,
          cfg: cfg,
          dry_run: true,
          capabilities: %i[architecture documentation],
          documentation_changes: [
            { "path" => "docs/internal.md", "status" => "added" },
            { "path" => "docs/external.md", "status" => "added" }
          ]
        )
        features = Timeout.timeout(2) { mapper.call }
        mapped = features.flat_map { |feature| feature.entrypoints + feature.owned_files + feature.context_files }

        assert_includes features.map(&:id), "architecture-api",
                        "tracked symlinks resolving within the checkout remain mappable"
        assert_includes mapped, "api/internal.py"
        assert_includes mapped, "docs/internal.md"
        %w[package.json api/external.py docs/external.md api/device.py].each do |path|
          refute_includes mapped, path, "unsafe tracked path must not reach a reviewer feature"
        end

        bounded = mapper.send(:read, "bounded.flux")
        assert_equal cap, bounded.bytesize
        refute_includes bounded, "TAIL"
      end
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

  def test_architecture_decision_directories_are_documentation_slices
    with_tmp_dir do |repo|
      mapper = Hive::Patrol::Mapper.new(repo, cfg: cfg, dry_run: true)

      assert mapper.send(:documentation_path?, "architecture/adrs/0001-boundaries.md")
      assert mapper.send(:documentation_path?, "ARCHITECTURE/decisions/0002-storage.md")
      refute mapper.send(:documentation_path?, "architecture/notes/draft.md")
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
      architecture_component = architecture.find { |feature| feature.id == "architecture-lib-acme" }
      assert_includes ordinary_one.owned_files, "bin/two", "ordinary patrol behavior remains compatible"
      assert_equal [ "bin/one" ], architecture_one.owned_files
      refute_includes architecture_component.entrypoints, "bin/one",
                      "a dedicated command must not be a second component evidence anchor"
    end
  end

  def test_architecture_component_keeps_its_dedicated_command_as_context_only
    with_tmp_git_repo do |repo|
      FileUtils.mkdir_p(File.join(repo, "cmd", "tool"))
      File.write(File.join(repo, "go.mod"), "module example.test/tool\n")
      File.write(File.join(repo, "cmd", "tool", "main.go"), "package main\nfunc main() {}\n")
      File.write(File.join(repo, "cmd", "tool", "worker.go"), "package main\nfunc work() {}\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "command component", "--quiet")

      features = Hive::Patrol::Mapper.new(
        repo, cfg: cfg, dry_run: true, capabilities: [ :architecture ]
      ).call
      component = features.find { |feature| feature.id == "architecture-cmd-tool" }

      assert_includes features.map(&:id), "command-cmd-tool-main-go"
      refute_includes component.entrypoints, "cmd/tool/main.go"
      assert_includes component.context_files, "cmd/tool/main.go"
    end
  end

  def test_architecture_capability_replaces_overlapping_route_manifest_and_test_suite_slices
    with_tmp_git_repo do |repo|
      FileUtils.mkdir_p(File.join(repo, "pages"))
      FileUtils.mkdir_p(File.join(repo, "test"))
      File.write(File.join(repo, "pages", "home.tsx"), "export default function Home() {}\n")
      File.write(File.join(repo, "test", "home.test.ts"), "import '../pages/home'\n")
      File.write(File.join(repo, "package.json"), JSON.generate("scripts" => { "test" => "node --test" }))
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "web component", "--quiet")

      features = Hive::Patrol::Mapper.new(
        repo, cfg: cfg, dry_run: true, capabilities: [ :architecture ]
      ).call
      ids = features.map(&:id)

      assert_includes ids, "architecture-pages"
      assert_includes ids, "command-package-json-scripts"
      refute_includes ids, "architecture-manifest-project",
                      "a grouped command-contract slice owns the manifest exactly once"
      refute ids.any? { |id| id.start_with?("route-", "package-", "test-suite-") },
             "component mapping must not review the same behavior again through legacy slices"
      assert_includes features.find { |feature| feature.id == "architecture-pages" }.tests,
                      "test/home.test.ts"
    end
  end

  def test_architecture_capability_groups_manifest_commands_into_one_review
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "package.json"), JSON.generate(
        "scripts" => { "test" => "node --test", "lint" => "eslint .", "build" => "vite build" }
      ))
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "scripts", "--quiet")

      features = Hive::Patrol::Mapper.new(
        repo, cfg: cfg, dry_run: true, capabilities: [ :architecture ]
      ).call

      manifest_owners = features.select { |feature| feature.owned_files.include?("package.json") }
      assert_equal [ "command-package-json-scripts" ], manifest_owners.map(&:id)
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
