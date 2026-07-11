require "test_helper"
require "hive/refactor_patrol/caps"
require "hive/refactor_patrol/thesis"

class RefactorPatrolCapsTest < Minitest::Test
  def test_exceeds_max_files_is_flagged_not_blocked
    thesis = sample_thesis(risk_hash: default_risk(est_files: 12))

    result = Hive::RefactorPatrol::Caps.new(cfg("max_files" => 8)).apply(thesis)

    refute result.blocked
    assert_includes thesis.risk.fetch("flags"), "exceeds_max_files"
  end

  def test_in_budget_diff_lines_are_not_flagged
    thesis = sample_thesis(risk_hash: default_risk(est_diff_lines: 300))

    Hive::RefactorPatrol::Caps.new(cfg("max_diff_lines" => 400)).apply(thesis)

    refute_includes thesis.risk.fetch("flags"), "exceeds_max_diff_lines"
  end

  def test_non_single_feature_is_flagged_when_cap_requires_single_feature
    thesis = sample_thesis(risk_hash: default_risk.merge("caps" => default_risk.fetch("caps").merge("single_feature" => false)))

    result = Hive::RefactorPatrol::Caps.new(cfg("single_feature_only" => true)).apply(thesis)

    refute result.blocked
    assert_includes thesis.risk.fetch("flags"), "not_single_feature"
  end

  # A thesis is behavior-preserving by contract: working inside files that
  # host public surface is an advisory, not an API change, so it must not
  # disqualify the thesis (no flag, public_api_impact stays false).
  def test_public_surface_paths_are_advisory_not_flagged
    cli = sample_thesis(boundary_files: [ "packages/tool/src/cli.ts" ])
    schema = sample_thesis(boundary_files: [ "schemas/foo.v1.json" ])

    Hive::RefactorPatrol::Caps.new(cfg).apply(cli)
    Hive::RefactorPatrol::Caps.new(cfg).apply(schema)

    [ cli, schema ].each do |thesis|
      assert_equal false, thesis.risk.fetch("public_api_impact")
      refute_includes thesis.risk.fetch("flags"), "public_api_impact"
      assert_includes thesis.risk.fetch("advisories"), "touches_public_api_surface"
    end
    assert_includes cli.risk.fetch("public_api_details"), "packages/tool/src/cli.ts"
    assert_includes schema.risk.fetch("public_api_details"), "schemas/foo.v1.json"
  end

  def test_agent_declared_public_api_impact_is_flagged
    thesis = sample_thesis(risk_hash: default_risk.merge("public_api_impact" => true))

    Hive::RefactorPatrol::Caps.new(cfg).apply(thesis)

    assert_includes thesis.risk.fetch("flags"), "public_api_impact"
    assert_empty thesis.risk.fetch("advisories")
  end

  def test_allowed_public_api_changes_produce_no_flag_or_advisory
    thesis = sample_thesis(boundary_files: [ "cmd/tool/main.go" ])

    Hive::RefactorPatrol::Caps.new(cfg("allow_public_api_changes" => true)).apply(thesis)

    assert_empty thesis.risk.fetch("flags")
    assert_empty thesis.risk.fetch("advisories")
  end

  def test_language_neutral_public_contract_paths_are_recognized
    paths = [
      "src/index.ts",
      "services/browser/src/index.mjs",
      "packages/browser/index.js",
      "packages/browser/package.json",
      "src/acme/__init__.py",
      "src/acme/contracts.pyi",
      "crates/engine/src/lib.rs",
      "modules/payments/src/main/java/module-info.java",
      "src/Payments/PublicAPI.Shipped.txt",
      "src/Payments/Properties/AssemblyInfo.cs",
      "types/browser.d.ts",
      "include/acme/client.h"
    ]

    paths.each do |path|
      assert Hive::RefactorPatrol::Caps.public_api_path?(path), "expected #{path} to be a public contract surface"
    end
  end

  def test_internal_index_and_ordinary_source_files_are_not_assumed_public
    paths = [
      "src/components/card/index.ts",
      "src/acme/service.py",
      "crates/engine/src/parser.rs",
      "src/main/java/com/acme/InternalClient.java",
      "src/Payments/InternalClient.cs",
      "pkg/client/client.go"
    ]

    paths.each do |path|
      refute Hive::RefactorPatrol::Caps.public_api_path?(path), "did not expect #{path} to be public from its path alone"
    end
  end

  def test_explicit_public_declarations_are_detected_from_evidence
    go = sample_thesis(
      boundary_files: [ "pkg/client/client.go" ],
      evidence: [ code_evidence("pkg/client/client.go", "func NewClient(endpoint string) *Client") ]
    )
    java = sample_thesis(
      boundary_files: [ "src/main/java/com/acme/Client.java" ],
      evidence: [ code_evidence("src/main/java/com/acme/Client.java", "public sealed interface Client") ]
    )
    dotnet = sample_thesis(
      boundary_files: [ "src/Acme/Client.cs" ],
      evidence: [ code_evidence("src/Acme/Client.cs", "public Client Create(string endpoint)") ]
    )
    python = sample_thesis(
      boundary_files: [ "src/acme/contracts.py" ],
      evidence: [ code_evidence("src/acme/contracts.py", "__all__ = [\"Client\"]") ]
    )
    typescript = sample_thesis(
      boundary_files: [ "src/client.ts" ],
      evidence: [ code_evidence("src/client.ts", "export function createClient() {}") ]
    )
    rust = sample_thesis(
      boundary_files: [ "src/client.rs" ],
      evidence: [ code_evidence("src/client.rs", "pub fn create_client() -> Client") ]
    )
    ruby = sample_thesis(
      boundary_files: [ "lib/client.rb" ],
      evidence: [ code_evidence("lib/client.rb", "def create_client") ]
    )
    php = sample_thesis(
      boundary_files: [ "src/Client.php" ],
      evidence: [ code_evidence("src/Client.php", "public function createClient(): Client") ]
    )
    elixir = sample_thesis(
      boundary_files: [ "lib/client.ex" ],
      evidence: [ code_evidence("lib/client.ex", "def create_client(opts) do") ]
    )

    declarations = [ go, java, dotnet, python, typescript, rust, ruby, php, elixir ]
    declarations.each { |thesis| Hive::RefactorPatrol::Caps.new(cfg).apply(thesis) }

    declarations.each do |thesis|
      assert_includes thesis.risk.fetch("advisories"), "touches_public_api_surface"
      assert_equal thesis.feature_boundary.fetch("owned_files"), thesis.risk.fetch("public_api_details")
    end

    assert Hive::RefactorPatrol::Caps.public_api_declaration?(
      "src/main/java/com/acme/Client.java", "public Client create(String endpoint)"
    )

    assert Hive::RefactorPatrol::Caps.public_api_declaration?(
      "pkg/client/client.go", "func (client *Client) Send(request Request) error"
    )
  end

  def test_ambiguous_or_non_exported_declarations_are_not_assumed_public
    cases = {
      "internal/client/client.go" => "func NewClient() *Client",
      "pkg/client/client.go" => "func newClient() *Client",
      "src/main/java/com/acme/Client.java" => "final class Client",
      "src/Acme/Client.cs" => "internal class Client",
      "src/acme/contracts.py" => "class _Client:",
      "src/client.ts" => "function createClient() {}",
      "src/client.rs" => "pub(crate) fn create_client()",
      "lib/client.ex" => "defp create_client(opts) do"
    }

    cases.each do |path, snippet|
      thesis = sample_thesis(boundary_files: [ path ], evidence: [ code_evidence(path, snippet) ])

      Hive::RefactorPatrol::Caps.new(cfg).apply(thesis)

      assert_empty thesis.risk.fetch("advisories"), "did not expect #{snippet.inspect} in #{path} to imply a public contract"
      assert_empty thesis.risk.fetch("public_api_details")
    end
  end

  def test_public_declaration_signatures_ignore_bodies_but_retain_contract_shape
    before = "module Checkout\n  def self.call(request) = old(request)\nend\n"
    body_only = "module Checkout\n  def self.call(request) = new_path(request)\nend\n"
    changed_contract = "module Checkout\n  def self.call(request, options) = new_path(request)\nend\n"

    signatures = Hive::RefactorPatrol::Caps.public_declaration_signatures("lib/checkout.rb", before)

    assert_equal signatures,
                 Hive::RefactorPatrol::Caps.public_declaration_signatures("lib/checkout.rb", body_only)
    refute_equal signatures,
                 Hive::RefactorPatrol::Caps.public_declaration_signatures("lib/checkout.rb", changed_contract)
  end

  def test_out_of_boundary_evidence_marks_cross_feature_impact
    thesis = sample_thesis(evidence: [ { "file" => "lib/other.rb", "signal" => "fan_in", "value" => 2 } ])

    Hive::RefactorPatrol::Caps.new(cfg).apply(thesis)

    assert_equal true, thesis.risk.fetch("cross_feature_impact")
    assert_includes thesis.risk.fetch("cross_feature_details"), "lib/other.rb"
    assert_includes thesis.risk.fetch("flags"), "cross_feature_impact"
  end

  def test_dependency_manifest_is_flagged
    thesis = sample_thesis(boundary_files: [ "pom.xml" ])

    Hive::RefactorPatrol::Caps.new(cfg).apply(thesis)

    assert_includes thesis.risk.fetch("flags"), "dependency_bump"
    assert_equal true, thesis.risk.fetch("cross_feature_impact")
    assert_includes thesis.risk.fetch("cross_feature_details"), "pom.xml"
  end

  def test_dependency_manifests_cover_common_ecosystems
    paths = [
      "package.json",
      "requirements-dev.txt",
      "Cargo.toml",
      "go.mod",
      "pom.xml",
      "settings.gradle.kts",
      "gradle/libs.versions.toml",
      "src/Payments/Payments.csproj",
      "src/Payments/packages.lock.json",
      "Directory.Build.props",
      "nuget.config",
      "vcpkg.json",
      "acme.gemspec",
      "CMakeLists.txt",
      "BUILD.bazel",
      "rules/dependencies.bzl",
      "flake.lock",
      "build.zig.zon",
      "acme.cabal",
      "stack.yaml",
      "cpanfile"
    ]

    paths.each do |path|
      assert Hive::RefactorPatrol::Caps.dependency_manifest?(path), "expected #{path} to be a dependency manifest"
    end
  end

  def test_dependency_manifest_mentioned_in_proposal_is_flagged
    thesis = sample_thesis
    thesis.proposed_refactor = "Update Payments.csproj. while extracting the adapter"

    Hive::RefactorPatrol::Caps.new(cfg).apply(thesis)

    assert_includes thesis.risk.fetch("flags"), "dependency_bump"
    assert_includes thesis.risk.fetch("cross_feature_details"), "Payments.csproj"
  end

  def test_similarly_named_source_files_are_not_dependency_manifests
    paths = [ "src/package.rb", "src/requirements_parser.py", "src/project.cs", "src/pom.xml.rb" ]

    paths.each do |path|
      refute Hive::RefactorPatrol::Caps.dependency_manifest?(path), "did not expect #{path} to be a dependency manifest"
    end
  end

  def test_in_bounds_thesis_has_no_flags
    thesis = sample_thesis

    Hive::RefactorPatrol::Caps.new(cfg).apply(thesis)

    assert_empty thesis.risk.fetch("flags")
    assert_empty thesis.risk.fetch("advisories")
    assert_equal false, thesis.risk.fetch("public_api_impact")
    assert_equal false, thesis.risk.fetch("cross_feature_impact")
  end

  private

  def cfg(overrides = {})
    {
      "refactor_patrol" => {
        "caps" => {
          "single_feature_only" => true,
          "allow_dependency_bumps" => false,
          "allow_public_api_changes" => false,
          "max_files" => 8,
          "max_diff_lines" => 400,
          "allow_cross_feature" => false
        }.merge(overrides)
      }
    }
  end

  def sample_thesis(boundary_files: [ "lib/checkout.rb" ], evidence: nil, risk_hash: nil)
    Hive::RefactorPatrol::Thesis.new(
      id: "t1",
      feature_id: "checkout",
      feature: "Checkout",
      problem: "Checkout mixes concerns",
      cost: "Churn is high",
      evidence: evidence || [ { "file" => boundary_files.first, "signal" => "churn", "value" => 7 } ],
      proposed_refactor: "Extract service",
      feature_boundary: { "owned_files" => boundary_files, "entrypoints" => boundary_files },
      expected_leverage: { "score" => 0.5, "breakdown" => { "churn" => 0.5 } },
      confidence: "medium",
      risk: risk_hash || default_risk,
      required_validation: { "commands" => [ "test" ], "characterization_first" => false, "notes" => "" },
      admissible: true,
      admissibility_reason: "ok",
      follow_up_approval_state: "pending",
      fingerprint: "fp"
    )
  end

  def default_risk(est_files: 2, est_diff_lines: 80)
    {
      "caps" => { "est_files" => est_files, "est_diff_lines" => est_diff_lines, "single_feature" => true },
      "public_api_impact" => false,
      "public_api_details" => [],
      "cross_feature_impact" => false,
      "cross_feature_details" => [],
      "flags" => []
    }
  end

  def code_evidence(file, snippet)
    { "file" => file, "snippet" => snippet, "claim" => "the declaration is part of the package contract" }
  end
end
