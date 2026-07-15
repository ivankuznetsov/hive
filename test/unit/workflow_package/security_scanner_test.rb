require "test_helper"
require "hive/workflow_package/security_scanner"

class WorkflowPackageSecurityScannerTest < Minitest::Test
  def test_undeclared_network_is_an_error_and_declared_network_is_a_warning
    text = "Fetch https://api.example.com/report with curl.\n"

    rejected = Hive::WorkflowPackage::SecurityScanner.scan_text(
      text, path: "instructions/work.md", permissions: { "domains" => [] }
    )
    assert_equal "security.undeclared_network", rejected.first.rule_id
    assert_equal :error, rejected.first.severity

    warning = Hive::WorkflowPackage::SecurityScanner.scan_text(
      text,
      path: "instructions/work.md",
      permissions: { "domains" => [ "api.example.com" ], "network_justification" => "download the report" }
    )
    assert_equal "security.declared_network", warning.first.rule_id
    assert_equal :warning, warning.first.severity
  end

  def test_secret_diagnostic_has_location_but_no_snippet
    secret = "sk-ant-#{'x' * 30}"
    diagnostic = Hive::WorkflowPackage::SecurityScanner.scan_text(
      "prefix\n#{secret}\n", path: "instructions/work.md", permissions: {}
    ).first

    assert_equal "security.anthropic_api_key", diagnostic.rule_id
    assert_equal 2, diagnostic.line
    refute_includes diagnostic.to_s, secret
    refute_includes diagnostic.to_h.values.compact.join, secret
  end

  def test_manifest_policy_tool_names_are_not_mistaken_for_shell_instructions
    findings = Hive::WorkflowPackage::SecurityScanner.scan_text(
      "permissions:\n  deny:\n    - Bash\n",
      path: "honeycomb.yml",
      permissions: { "commands" => [] }
    )

    refute findings.any? { |finding| finding.rule_id == "security.undeclared_shell" }
  end
end
