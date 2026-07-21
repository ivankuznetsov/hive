require "test_helper"
require "hive/workflow_package/authoring_lint"

class WorkflowPackageAuthoringLintTest < Minitest::Test
  include HiveTestHelper

  Lint = Hive::WorkflowPackage::AuthoringLint

  def test_benign_and_malicious_contract_fixtures_have_stable_redacted_findings
    with_lint_package(File.read(fixture("benign.md"))) do |root, manifest|
      result = Lint.verify(root, manifest: manifest)
      assert result.valid?, result.findings.map(&:to_h).inspect
      assert_equal "v1", result.contract.fetch("version")
    end

    secret = "sk-ant-#{'x' * 30}"
    with_lint_package(File.read(fixture("malicious.md")).sub("SECRET_VALUE", secret), permissions: unbounded) do |root, manifest|
      result = Lint.verify(root, manifest: manifest)
      rules = result.findings.map(&:rule_id)
      assert_includes rules, "secret.anthropic-key"
      assert_includes rules, "deny.pipe-to-shell"
      assert_includes rules, "deny.credential-read"
      assert_includes rules, "review.network"
      assert result.findings.any?(&:review_required)
      refute_includes result.findings.map(&:to_h).join, secret
      refute result.valid?
      expected = JSON.parse(File.read(fixture("expected.json"))).fetch("malicious_rules")
      assert_equal expected.sort, rules.uniq.sort
    end
  end

  def test_policy_integrity_and_input_limits_fail_closed
    policy = Hive::WorkflowPackage::LintPolicy.load
    assert_equal Hive::WorkflowPackage::LintPolicy::PINNED_COMMIT, policy.upstream_commit

    with_tmp_dir do |dir|
      File.write(File.join(dir, "policy.yml"), "schema: changed\n")
      assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::LintPolicy.load(path: File.join(dir, "policy.yml"))
      end
    end

    with_lint_package("x" * (1_048_576 + 1)) do |root, manifest|
      result = Lint.verify(root, manifest: manifest)
      refute result.valid?
      assert_includes result.findings.map(&:rule_id), "policy.file-limit"
    end
  end

  private

  def fixture(name) = File.expand_path("../../fixtures/honeycomb_security_lint/#{name}", __dir__)

  def unbounded
    {
      "risk" => "high", "capabilities" => %w[filesystem-read filesystem-write network shell],
      "network_hosts" => [ "*" ], "filesystem_read" => [ "*" ],
      "filesystem_write" => [ "*" ], "secrets" => [ "*" ]
    }
  end

  def with_lint_package(instruction, permissions: nil)
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, "instructions"))
      File.write(File.join(root, "README.md"), "# Demo\n")
      File.write(File.join(root, "workflow.yml"), "id: demo\nstages: []\n")
      File.binwrite(File.join(root, "instructions", "work.md"), instruction)
      data = {
        "permissions" => permissions || {
          "risk" => "low", "capabilities" => [ "filesystem-read" ], "network_hosts" => [],
          "filesystem_read" => %w[repository task], "filesystem_write" => [], "secrets" => []
        }
      }
      manifest = Struct.new(:data, :permissions).new(data, data.fetch("permissions"))
      yield root, manifest
    end
  end
end
