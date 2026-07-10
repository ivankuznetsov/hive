require "test_helper"
require "hive/config"
require "hive/patrol/architecture_mapper"

class HivePatrolArchitectureMapperTest < Minitest::Test
  include HiveTestHelper

  def test_maps_mixed_language_components_with_non_overlapping_ownership
    with_tmp_git_repo do |repo|
      write_mixed_repository(repo)
      commit_all(repo)

      features = mapper(repo).call(tracked_files(repo))
      ids = features.map(&:id)

      %w[
        architecture-lib-acme-config-rb
        architecture-lib-acme-daemon
        architecture-packages-web
        architecture-services-billing
        architecture-services-search
        architecture-crates-engine
        architecture-sources-app
        architecture-sources-core
        architecture-src-firmware
        architecture-main-cob
      ].each { |id| assert_includes ids, id }

      source_paths = features.flat_map(&:owned_files)
      duplicates = source_paths.tally.select { |_path, count| count > 1 }
      assert_empty duplicates, "architecture components must have one authoritative owner"
      assert_includes source_paths, "src/firmware/control.zig",
                      "unsupported languages under source roots use the deterministic fallback"
    end
  end

  def test_dependency_context_and_tests_follow_components_instead_of_directory_siblings
    with_tmp_git_repo do |repo|
      write_mixed_repository(repo)
      commit_all(repo)

      features = mapper(repo).call(tracked_files(repo))
      daemon = features.find { |feature| feature.id == "architecture-lib-acme-daemon" }
      config = features.find { |feature| feature.id == "architecture-lib-acme-config-rb" }
      ruby_client = features.find { |feature| feature.id == "architecture-lib-acme-client-rb" }
      web = features.find { |feature| feature.id == "architecture-packages-web" }
      reports = features.find { |feature| feature.id == "architecture-services-reports" }
      gateway = features.find { |feature| feature.id == "architecture-services-gateway" }
      rust_cli = features.find { |feature| feature.id == "architecture-crates-cli" }
      native = features.find { |feature| feature.id == "architecture-src-native" }
      swift_app = features.find { |feature| feature.id == "architecture-sources-app" }
      swift_core = features.find { |feature| feature.id == "architecture-sources-core" }

      assert_includes daemon.context_files, "lib/acme/config.rb"
      assert_includes ruby_client.context_files, "lib/acme/config.rb"
      assert_includes daemon.tests, "test/acme/daemon/dispatcher_test.rb"
      refute_includes config.owned_files, "lib/acme/daemon/dispatcher.rb"
      refute_includes config.tests, "test/acme/daemon/dispatcher_test.rb"
      assert_includes web.context_files, "packages/core/src/api.ts"
      assert_includes web.tests, "packages/web/test/checkout.test.ts"
      assert_includes reports.context_files, "services/billing/billing/service.py"
      assert_includes gateway.context_files, "services/search/search/index.go"
      assert_includes rust_cli.context_files, "crates/engine/src/model.rs"
      assert_includes native.context_files, "src/include/common.h"
      assert_includes swift_app.context_files, "Sources/Core/API.swift"
      assert_includes swift_core.tests, "Tests/CoreTests/APITests.swift"
      refute_includes features.flat_map(&:owned_files), "Tests/CoreTests/APITests.swift"

      assert_includes web.entrypoints, "packages/web/package.json"
      assert_includes reports.entrypoints, "services/reports/pyproject.toml"
      assert_includes gateway.entrypoints, "services/gateway/go.mod"
      assert_includes rust_cli.entrypoints, "crates/cli/Cargo.toml"
      assert_includes swift_app.entrypoints, "Package.swift"
    end
  end

  def test_unknown_language_fallback_excludes_artifacts_and_reserves_command_entrypoints
    with_tmp_git_repo do |repo|
      write(repo, "src/firmware/control.cob", "IDENTIFICATION DIVISION.\nPROGRAM-ID. CONTROL.\n")
      write(repo, "main.cob", "IDENTIFICATION DIVISION.\nPROGRAM-ID. MAIN.\n")
      write(repo, "cmd/tool/main.go", "package main\n")
      write(repo, "cmd/tool/helper.go", "package main\n")
      write(repo, "package.json", '{"bin":{"extra":"tools/cli.js"}}')
      write(repo, "tools/cli.js", "export const cli = true\n")
      write(repo, "tools/helper.js", "export const helper = true\n")
      write(repo, "docs/demo.mp4", "not source\n")
      write(repo, "config/brakeman.ignore", "not source\n")
      commit_all(repo)

      architecture_mapper = mapper(repo)
      features = architecture_mapper.call(tracked_files(repo))
      command_component = features.find { |feature| feature.id == "architecture-cmd-tool" }
      package_command_component = features.find { |feature| feature.id == "architecture-tools" }

      assert_equal(
        %w[
          cmd/tool/helper.go cmd/tool/main.go main.cob src/firmware/control.cob
          tools/cli.js tools/helper.js
        ].sort,
        (features.flat_map(&:owned_files) + architecture_mapper.reserved_command_files).sort
      )
      assert_includes command_component.entrypoints, "cmd/tool/main.go"
      refute_includes command_component.owned_files, "cmd/tool/main.go"
      assert_includes package_command_component.entrypoints, "tools/cli.js"
      refute_includes package_command_component.owned_files, "tools/cli.js"
      refute_includes features.flat_map(&:owned_files), "docs/demo.mp4"
      refute_includes features.flat_map(&:owned_files), "config/brakeman.ignore"
    end
  end

  def test_python_relative_import_resolves_across_source_components
    with_tmp_git_repo do |repo|
      write(repo, "src/client/main.py", "from ..common.helpers import value\n")
      write(repo, "src/common/helpers.py", "value = 1\n")
      commit_all(repo)

      client = mapper(repo).call(tracked_files(repo)).find { |feature| feature.id == "architecture-src-client" }

      assert_includes client.context_files, "src/common/helpers.py"
    end
  end

  def test_collision_safe_ids_are_stable_for_distinct_case_sensitive_roots
    with_tmp_git_repo do |repo|
      write(repo, "src/foo-bar/one.zig", "pub const one = 1;\n")
      write(repo, "src/foo_bar/two.zig", "pub const two = 2;\n")
      commit_all(repo)
      files = tracked_files(repo)

      first = mapper(repo).call(files).map(&:id)
      second = mapper(repo).call(files.reverse).map(&:id)

      assert_equal 2, first.size
      assert_equal first.uniq, first
      assert_equal first, second
    end
  end

  def test_large_components_are_deterministically_partitioned_without_losing_files
    with_tmp_git_repo do |repo|
      70.times { |index| write(repo, format("services/large/src/unit_%02d.py", index), "VALUE = #{index}\n") }
      write(repo, "services/large/pyproject.toml", "[project]\nname='large'\n")
      commit_all(repo)

      overrides = {
        "patrol" => { "review" => { "max_owned_files" => 7, "max_context_files" => 9 } },
        "refactor_patrol" => { "review" => { "max_owned_files" => 63, "max_context_files" => 63 } }
      }
      first = mapper(repo, overrides).call(tracked_files(repo)).select { |feature| feature.id.start_with?("architecture-services-large") }
      second = mapper(repo, overrides).call(tracked_files(repo)).select { |feature| feature.id.start_with?("architecture-services-large") }

      assert_equal first.map(&:id), second.map(&:id)
      assert first.all? { |feature| feature.owned_files.size <= 7 }
      assert first.all? { |feature| feature.context_files.size <= 9 }
      assert_equal 70, first.sum { |feature| feature.owned_files.size }
      assert_equal 70, first.flat_map(&:owned_files).uniq.size
    end
  end

  private

  def mapper(repo, overrides = {})
    Hive::Patrol::ArchitectureMapper.new(
      repo,
      cfg: Hive::Config.deep_merge(Hive::Config.deep_dup(Hive::Config::DEFAULTS), overrides)
    )
  end

  def tracked_files(repo)
    run!("git", "-C", repo, "ls-files", "-z").split("\0").reject(&:empty?).sort
  end

  def write_mixed_repository(repo)
    write(repo, "lib/acme/config.rb", "module Acme::Config\nend\n")
    write(repo, "lib/acme/client.rb", "require_relative 'config'\nmodule Acme::Client\nend\n")
    write(repo, "lib/acme/daemon/dispatcher.rb", "require_relative '../config'\nmodule Acme::Daemon::Dispatcher\nend\n")
    write(repo, "lib/acme/daemon/logger.rb", "module Acme::Daemon::Logger\nend\n")
    write(repo, "test/acme/daemon/dispatcher_test.rb", "require 'acme/daemon/dispatcher'\n")

    write(repo, "packages/core/package.json", '{"name":"@acme/core"}')
    write(repo, "packages/core/src/api.ts", "export const api = 1\n")
    write(repo, "packages/web/package.json", '{"name":"@acme/web"}')
    write(repo, "packages/web/src/index.ts", "import { api } from '@acme/core/src/api'\nexport { api }\n")
    write(repo, "packages/web/src/checkout.ts", "export const checkout = true\n")
    write(repo, "packages/web/test/checkout.test.ts", "import '../src/checkout'\n")

    write(repo, "services/billing/pyproject.toml", "[project]\nname='billing'\n")
    write(repo, "services/billing/billing/__init__.py", "from .service import charge\n")
    write(repo, "services/billing/billing/service.py", "def charge(): return True\n")
    write(repo, "services/reports/pyproject.toml", "[project]\nname='reports'\n")
    write(repo, "services/reports/reports/job.py", "from billing.service import charge\n")
    write(repo, "services/search/go.mod", "module example.com/search\n")
    write(repo, "services/search/search/index.go", "package search\n")
    write(repo, "services/gateway/go.mod", "module example.com/gateway\n")
    write(repo, "services/gateway/main/server.go", "package main\nimport \"example.com/search/search\"\n")

    write(repo, "crates/engine/Cargo.toml", "[package]\nname='engine'\nversion='0.1.0'\n")
    write(repo, "crates/engine/src/lib.rs", "pub mod model;\n")
    write(repo, "crates/engine/src/model.rs", "pub struct Model;\n")
    write(repo, "crates/cli/Cargo.toml", "[package]\nname='cli'\nversion='0.1.0'\n")
    write(repo, "crates/cli/src/lib.rs", "use engine::model::Model;\n")

    write(repo, "Package.swift", "// swift-tools-version: 6.0\n")
    write(repo, "Sources/App/main.swift", "import Core\n")
    write(repo, "Sources/Core/API.swift", "public struct API {}\n")
    write(repo, "Tests/CoreTests/APITests.swift", "import Core\n")
    write(repo, "src/native/main.c", "#include \"../include/common.h\"\n")
    write(repo, "src/include/common.h", "int common(void);\n")
    write(repo, "src/firmware/control.zig", "pub fn control() void {}\n")
    write(repo, "main.cob", "IDENTIFICATION DIVISION.\nPROGRAM-ID. MAIN.\n")
  end

  def write(repo, path, content)
    full = File.join(repo, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def commit_all(repo)
    run!("git", "-C", repo, "add", ".")
    run!("git", "-C", repo, "commit", "-m", "mixed architecture", "--quiet")
  end
end
