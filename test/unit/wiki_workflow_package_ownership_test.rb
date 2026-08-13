require "test_helper"

class WikiWorkflowPackageOwnershipTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  PACKAGE_PAGE = "wiki/modules/workflow_package.md"
  WORKFLOW_PAGE = "wiki/modules/workflows.md"
  COMMAND_PAGE = "wiki/commands/workflow.md"
  PERMISSIONS_PAGE = "docs/permissions.md"
  GUIDE_PAGE = "docs/workflows.md"
  RELEASE_PROOF = "wiki/log.d/20260719T235900Z-flagship-honeycomb-release-proof.md"
  OWNERSHIP_MARKER = "<!-- documentation-owner: managed-honeycomb-policy -->"

  def test_workflow_package_page_owns_the_package_source_and_policy
    package = read(PACKAGE_PAGE)
    workflows = read(WORKFLOW_PAGE)
    task_action = read("wiki/modules/task_action.md")

    assert_match(/^source: .*lib\/hive\/workflow_package\//, package)
    refute_match(/^source: .*lib\/hive\/workflow_package\//, workflows)
    assert_includes package, OWNERSHIP_MARKER
    assert_includes package, "## Managed Honeycomb boundary"
    assert_includes package, "## Publishing and recovery internals"
    refute_includes package, "TaskAction::READY_COMMANDS"
    assert_includes task_action, "TaskAction::READY_COMMANDS"
    refute_includes workflows, OWNERSHIP_MARKER
  end

  def test_consumers_link_to_the_policy_owner_without_repeating_it
    [ WORKFLOW_PAGE, COMMAND_PAGE, PERMISSIONS_PAGE, GUIDE_PAGE ].each do |path|
      document = read(path)
      assert_includes document, "workflow_package", "#{path} must link to the package-policy owner"
      refute_includes document, OWNERSHIP_MARKER, "#{path} must not claim package-policy ownership"
      refute_includes document, "## Publishing and recovery internals",
                      "#{path} must not own package publication internals"
    end
  end

  def test_shell_examples_do_not_use_doubled_continuation_characters
    [ COMMAND_PAGE, GUIDE_PAGE ].each do |path|
      refute_match(/\\\\[ \t]*\n/, read(path),
                   "#{path} contains a doubled Bash continuation")
    end
  end

  def test_index_registers_the_package_page
    assert_includes read("wiki/index.md"),
                    "[[modules/workflow_package]] — `wiki/modules/workflow_package.md`"
  end

  def test_release_proof_is_historical_not_evergreen_command_reference
    command = read(COMMAND_PAGE)
    proof = read(RELEASE_PROOF)

    refute_includes command, "## Flagship release proof"
    refute_includes command, "454fbd018dd62d2880747e74020edd429d994ba902f323d77ed4fba053821234"
    assert_includes proof, "454fbd018dd62d2880747e74020edd429d994ba902f323d77ed4fba053821234"
    assert_includes proof, "29686390960"
  end

  private

  def read(path)
    File.read(File.join(ROOT, path))
  end
end
