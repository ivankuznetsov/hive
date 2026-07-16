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
        architecture-lib-acme
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
      assert Hive::Patrol::ArchitectureMapper.source_candidate_path?("src/firmware/control.zig")
    end
  end

  def test_dependency_context_and_tests_follow_components_instead_of_directory_siblings
    with_tmp_git_repo do |repo|
      write_mixed_repository(repo)
      commit_all(repo)

      features = mapper(repo).call(tracked_files(repo))
      daemon = features.find { |feature| feature.id == "architecture-lib-acme-daemon" }
      ruby_core = features.find { |feature| feature.id == "architecture-lib-acme" }
      web = features.find { |feature| feature.id == "architecture-packages-web" }
      reports = features.find { |feature| feature.id == "architecture-services-reports" }
      gateway = features.find { |feature| feature.id == "architecture-services-gateway" }
      rust_cli = features.find { |feature| feature.id == "architecture-crates-cli" }
      native = features.find { |feature| feature.id == "architecture-src-native" }
      swift_app = features.find { |feature| feature.id == "architecture-sources-app" }
      swift_core = features.find { |feature| feature.id == "architecture-sources-core" }

      assert_includes daemon.context_files, "lib/acme/config.rb"
      assert_includes daemon.tests, "test/acme/daemon/dispatcher_test.rb"
      assert_includes ruby_core.owned_files, "lib/acme/config.rb"
      assert_includes ruby_core.owned_files, "lib/acme/client.rb"
      refute_includes ruby_core.owned_files, "lib/acme/daemon/dispatcher.rb"
      refute_includes ruby_core.tests, "test/acme/daemon/dispatcher_test.rb"
      assert_includes web.context_files, "packages/core/src/api.ts"
      assert_includes web.tests, "packages/web/test/checkout.test.ts"
      assert_includes reports.context_files, "services/billing/billing/service.py"
      assert_includes gateway.context_files, "services/search/search/index.go"
      assert_includes rust_cli.context_files, "crates/engine/src/model.rs"
      assert_includes native.context_files, "src/include/common.h"
      assert_includes swift_app.context_files, "Sources/Core/API.swift"
      assert_includes swift_core.tests, "Tests/CoreTests/APITests.swift"
      refute_includes features.flat_map(&:owned_files), "Tests/CoreTests/APITests.swift"

      assert_includes web.context_files, "packages/web/package.json"
      assert_includes reports.context_files, "services/reports/pyproject.toml"
      assert_includes gateway.context_files, "services/gateway/go.mod"
      assert_includes rust_cli.context_files, "crates/cli/Cargo.toml"
      assert_includes swift_app.context_files, "Package.swift"
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
      write(repo, "domain/workflow/engine.flux", "import core.runtime\nrule Engine {}\n")
      write(repo, "scripts/release", "#!/usr/bin/env custom-runtime\nrelease --safe\n")
      File.binwrite(
        File.join(repo, "assets", "opaque.flux").tap { |path| FileUtils.mkdir_p(File.dirname(path)) },
        "\x00\xFFbinary".b
      )
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
          domain/workflow/engine.flux package.json scripts/release tools/cli.js
          tools/helper.js
        ].sort,
        (features.flat_map(&:owned_files) + architecture_mapper.reserved_command_files).sort
      )
      assert_includes command_component.entrypoints, "cmd/tool/main.go"
      refute_includes command_component.owned_files, "cmd/tool/main.go"
      assert_includes package_command_component.entrypoints, "tools/cli.js"
      refute_includes package_command_component.owned_files, "tools/cli.js"
      refute_includes features.flat_map(&:owned_files), "docs/demo.mp4"
      refute_includes features.flat_map(&:owned_files), "config/brakeman.ignore"
      refute_includes features.flat_map(&:owned_files), "assets/opaque.flux"
      assert Hive::Patrol::ArchitectureMapper.source_candidate_path?("main.cob")
      assert Hive::Patrol::ArchitectureMapper.source_candidate_path?("src/firmware/control.cob")
      assert Hive::Patrol::ArchitectureMapper.source_candidate_path?("domain/workflow/engine.flux")
      refute Hive::Patrol::ArchitectureMapper.source_candidate_path?("docs/architecture.md")
    end
  end

  def test_tracked_source_symlinks_cannot_escape_the_project_or_read_devices
    with_tmp_git_repo do |repo|
      Dir.mktmpdir("architecture-mapper-outside") do |outside|
        outside_source = File.join(outside, "outside.rb")
        File.write(outside_source, "class Outside; end\n")
        FileUtils.mkdir_p(File.join(repo, "lib"))
        File.symlink(outside_source, File.join(repo, "lib", "external.rb"))
        File.symlink("/dev/zero", File.join(repo, "lib", "device.rb")) if File.exist?("/dev/zero")
        write(repo, "lib/local.rb", "class Local; end\n")
        commit_all(repo)

        owned = Timeout.timeout(1) { mapper(repo).call(tracked_files(repo)).flat_map(&:owned_files) }

        assert_includes owned, "lib/local.rb"
        refute_includes owned, "lib/external.rb"
        refute_includes owned, "lib/device.rb" if File.exist?("/dev/zero")
      end
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

  # ArchitectureMapper#call receives raw git-output filename bytes; a Latin-1
  # name used to raise ArgumentError from tr/downcase/split inside normalize
  # and the classifiers instead of simply not being mapped.
  def test_latin1_filename_bytes_are_scrubbed_at_the_boundary_without_raising
    with_tmp_git_repo do |repo|
      write(repo, "services/billing/invoice.rb", "module Billing\nend\n")
      write(repo, "services/billing/ledger.rb", "module Ledger\nend\n")
      File.binwrite(File.join(repo.b, "services/billing/caf\xE9.rb".b), "class Cafe\nend\n")
      commit_all(repo)
      files = run!("git", "-C", repo, "ls-files", "-z").b.split("\0").reject(&:empty?)

      features = mapper(repo).call(files)

      owned = features.flat_map(&:owned_files)
      assert_includes owned, "services/billing/invoice.rb"
      refute owned.any? { |path| path.include?("\uFFFD") },
             "a scrubbed non-UTF-8 name must be dropped, not claimed as owned"
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
      assert_equal [ 7, 63 ], first.map { |feature| feature.owned_files.size }.sort
      assert first.all? { |feature| feature.context_files.size <= 63 }
      assert_equal 70, first.sum { |feature| feature.owned_files.size }
      assert_equal 70, first.flat_map(&:owned_files).uniq.size
    end
  end

  def test_maps_common_data_science_infrastructure_schema_database_and_static_projects
    with_tmp_git_repo do |repo|
      write(repo, "R/model.R", "fit <- function(data) data\n")
      write(repo, "modules/vpc/main.tf", "module \"subnet\" { source = \"../subnet\" }\n")
      write(repo, "modules/subnet/main.tf", "resource \"example_subnet\" \"main\" {}\n")
      write(repo, "db/migrations/001_create_orders.sql", "create table orders(id bigint);\n")
      write(repo, "api/orders.proto", "syntax = \"proto3\"; message Order {}\n")
      write(repo, "deploy/app.yaml", "apiVersion: apps/v1\nkind: Deployment\n")
      write(repo, "styles/app.css", ".app { display: grid; }\n")
      commit_all(repo)

      features = mapper(repo).call(tracked_files(repo))
      owned = features.flat_map(&:owned_files)

      %w[
        R/model.R modules/vpc/main.tf modules/subnet/main.tf
        db/migrations/001_create_orders.sql api/orders.proto deploy/app.yaml
        styles/app.css
      ].each { |path| assert_includes owned, path }
      vpc = features.find { |feature| feature.owned_files.include?("modules/vpc/main.tf") }
      assert_includes vpc.context_files, "modules/subnet/main.tf"
    end
  end

  def test_root_manifest_has_one_owned_slice_and_does_not_trigger_every_source_component
    with_tmp_git_repo do |repo|
      write(repo, "Gemfile", "source \"https://rubygems.org\"\n")
      write(repo, "lib/acme/client.rb", "module Acme::Client; end\n")
      write(repo, "lib/acme/server.rb", "module Acme::Server; end\n")
      write(repo, "lib/acme/admin/audit.rb", "module Acme::Admin::Audit; end\n")
      commit_all(repo)

      features = mapper(repo).call(tracked_files(repo))
      manifest_owners = features.select { |feature| feature.owned_files.include?("Gemfile") }

      assert_equal 1, manifest_owners.size
      assert_equal "architecture-manifest-project", manifest_owners.first.id
      assert_empty features.reject { |feature| feature == manifest_owners.first }
                           .flat_map(&:entrypoints).grep("Gemfile")
      assert features.select { |feature| feature.context_files.include?("Gemfile") }.any?
    end
  end

  def test_test_and_fixture_manifests_never_become_architecture_slices
    with_tmp_git_repo do |repo|
      write(repo, "package.json", '{"name":"production"}')
      write(repo, "test/fixtures/package.json", '{"name":"test-fixture"}')
      write(repo, "spec/fixtures/Gemfile", "source 'https://example.invalid'\n")
      write(repo, "fixtures/Cargo.toml", "[package]\nname='fixture'\n")
      write(repo, "src/app.ts", "export const app = true\n")
      commit_all(repo)

      features = mapper(repo).call(tracked_files(repo))
      owned = features.flat_map(&:owned_files)

      assert_includes owned, "package.json"
      refute_includes owned, "test/fixtures/package.json"
      refute_includes owned, "spec/fixtures/Gemfile"
      refute_includes owned, "fixtures/Cargo.toml"
      assert_equal [ "architecture-manifest-project" ],
                   features.select { |feature| feature.id.start_with?("architecture-manifest-") }.map(&:id)
    end
  end

  def test_generic_module_and_quoted_imports_build_cross_ecosystem_dependency_edges
    with_tmp_git_repo do |repo|
      write(repo, "services/catalog/catalog/Catalog.java", "package catalog; public class Catalog {}\n")
      write(repo, "services/web/web/Web.java", "import catalog.Catalog; public class Web {}\n")
      write(repo, "services/billing/Billing/Contracts/Invoice.cs", "namespace Billing.Contracts; public class Invoice {}\n")
      write(repo, "services/api/Api/Handler.cs", "using Billing.Contracts.Invoice; public class Handler {}\n")
      write(repo, "services/orders/lib/orders/policy.ex", "defmodule Orders.Policy do\nend\n")
      write(repo, "services/checkout/lib/checkout.ex", "alias Orders.Policy\ndefmodule Checkout do\nend\n")
      write(repo, "services/core/Core/Policy.hs", "module Core.Policy where\n")
      write(repo, "services/worker/Worker/Job.hs", "import Core.Policy\n")
      write(repo, "services/php/App/Domain/Policy.php", "<?php namespace App\\Domain; class Policy {}\n")
      write(repo, "services/site/App/Controller.php", "<?php\nuse App\\Domain\\Policy;\n")
      write(repo, "services/common/money.proto", "syntax = \"proto3\"; message Money {}\n")
      write(repo, "services/consumer/order.proto", "import \"common/money.proto\"; message Order {}\n")
      commit_all(repo)

      architecture_mapper = mapper(repo)
      features = architecture_mapper.call(tracked_files(repo))
      expectations = {
        "services/web/web/Web.java" => "services/catalog/catalog/Catalog.java",
        "services/api/Api/Handler.cs" => "services/billing/Billing/Contracts/Invoice.cs",
        "services/checkout/lib/checkout.ex" => "services/orders/lib/orders/policy.ex",
        "services/worker/Worker/Job.hs" => "services/core/Core/Policy.hs",
        "services/site/App/Controller.php" => "services/php/App/Domain/Policy.php",
        "services/consumer/order.proto" => "services/common/money.proto"
      }

      expectations.each do |source, dependency|
        assert_includes architecture_mapper.dependency_edges.fetch(source), dependency, source
        feature = features.find { |candidate| candidate.owned_files.include?(source) }
        assert_includes feature.context_files, dependency, source
      end
      assert_equal expectations.keys.sort & architecture_mapper.source_files,
                   expectations.keys.sort
    end
  end

  def test_polyglot_import_forms_resolve_package_indexes_and_language_relative_paths
    with_tmp_git_repo do |repo|
      write(repo, "packages/ui/package.json", '{"name":"@acme/ui","types":"src/public.ts"}')
      write(repo, "packages/ui/src/public.ts", "export interface Public {}\n")
      write(repo, "packages/app/package.json", '{"name":"@acme/app"}')
      write(repo, "packages/app/src/main.ts", "import type { Public } from '@acme/ui'\n")
      write(repo, "services/python/pyproject.toml", "[project]\nname='python-service'\n")
      write(repo, "services/python/src/acme/one.py", "ONE = 1\n")
      write(repo, "services/python/src/acme/two.py", "TWO = 2\n")
      write(repo, "services/python/src/acme/main.py", "import acme.one, acme.two as second\n")
      write(repo, "services/search/go.mod", "module example.com/search\n")
      write(repo, "services/search/index.go", "package search\n")
      write(repo, "services/gateway/go.mod", "module example.com/gateway\n")
      write(repo, "services/gateway/main.go", <<~GO)
        package gateway
        import (
          "example.com/search"
        )
      GO
      write(repo, "include/acme/client.h", "int client(void);\n")
      write(repo, "src/native/main.c", "#include <acme/client.h>\n")
      write(repo, "crates/model/Cargo.toml", "[package]\nname='model'\n")
      write(repo, "crates/model/src/lib.rs", "pub struct Model;\n")
      write(repo, "crates/model/src/model.rs", "pub struct Model;\n")
      write(repo, "crates/engine/Cargo.toml", "[package]\nname='engine'\n")
      write(repo, "crates/engine/src/lib.rs", "mod local;\nmod nested;\nuse crate::local::Local;\n")
      write(repo, "crates/engine/src/local.rs", "pub struct Local;\n")
      write(repo, "crates/engine/src/nested/mod.rs", "use self::child::Child;\n")
      write(repo, "crates/engine/src/nested/child.rs", "pub struct Child;\n")
      write(repo, "crates/engine/src/child.rs", "pub struct Child;\n")
      write(repo, "crates/engine/src/nested/deep.rs", "use super::child::Child;\nuse model::model::Model;\n")
      commit_all(repo)

      architecture_mapper = mapper(repo)
      architecture_mapper.call(tracked_files(repo))
      edges = architecture_mapper.dependency_edges

      assert_includes edges.fetch("packages/app/src/main.ts"), "packages/ui/src/public.ts"
      assert_includes edges.fetch("services/python/src/acme/main.py"), "services/python/src/acme/one.py"
      assert_includes edges.fetch("services/python/src/acme/main.py"), "services/python/src/acme/two.py"
      assert_includes edges.fetch("services/gateway/main.go"), "services/search/index.go"
      assert_includes edges.fetch("src/native/main.c"), "include/acme/client.h"
      assert_includes edges.fetch("crates/engine/src/lib.rs"), "crates/engine/src/local.rs"
      assert_includes edges.fetch("crates/engine/src/nested/mod.rs"), "crates/engine/src/nested/child.rs"
      assert_includes edges.fetch("crates/engine/src/nested/deep.rs"), "crates/engine/src/child.rs"
      assert_includes edges.fetch("crates/engine/src/nested/deep.rs"), "crates/model/src/model.rs"
    end
  end

  def test_manifest_and_language_registries_cover_supported_ecosystems
    architecture_mapper = mapper(Dir.pwd)
    manifests = {
      "acme.gemspec" => :ruby,
      "composer.json" => :php,
      "mix.exs" => :elixir,
      "pom.xml" => :jvm,
      "DESCRIPTION" => :r,
      "Project.toml" => :julia,
      "stack.yaml" => :haskell,
      "pubspec.yaml" => :dart,
      "build.zig" => :zig,
      "CMakeLists.txt" => :native,
      "rebar.config" => :erlang,
      "project.clj" => :clojure,
      "build.sbt" => :scala,
      "flake.nix" => :nix,
      "acme.cabal" => :haskell,
      "Acme.csproj" => :dotnet
    }
    languages = {
      "main.jl" => :julia,
      "main.hs" => :haskell,
      "main.dart" => :dart,
      "main.zig" => :zig,
      "main.erl" => :erlang,
      "main.clj" => :clojure,
      "main.scala" => :scala,
      "main.cs" => :dotnet,
      "main.c" => :native,
      "main.nix" => :nix
    }

    manifests.each do |path, kind|
      assert_equal kind, architecture_mapper.send(:manifest_kind, path), path
    end
    languages.each do |path, kind|
      assert_equal kind, architecture_mapper.send(:language_kind, path), path
    end
    assert_nil architecture_mapper.send(
      :toml_section_value, "[dependencies]\njson = '1.0'\n", "package", "name"
    )
  end

  def test_unreadable_inputs_and_unknown_import_kinds_fail_closed
    with_tmp_dir do |repo|
      write(repo, "package.json", "{")
      architecture_mapper = mapper(repo)
      architecture_mapper.call([ "package.json" ])

      refute architecture_mapper.send(:shebang_script?, "missing-script")
      refute architecture_mapper.send(:text_file?, "missing.flux")
      assert_equal "", architecture_mapper.send(:read, "missing.flux")
      assert_empty architecture_mapper.send(:resolve_import, "missing.flux", :unknown, "elsewhere")
      assert_empty architecture_mapper.send(:resolve_progressively, "src", %w[missing path])
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
