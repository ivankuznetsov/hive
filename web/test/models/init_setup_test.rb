require "test_helper"

class InitSetupTest < ActiveSupport::TestCase
  test "workflow_options without a project lists only the built-in workflows" do
    options = InitSetup.workflow_options

    assert_equal InitSetup.workflows, options
    assert_equal "coding", options.first
  end

  test "workflow_options preserves a persisted default that is no longer registry-valid" do
    # The policy that keeps a bare Apply from silently rebinding the project to
    # coding lives HERE, in the class that owns workflow enumeration — not in
    # the /repos/new view, which must render the list it is given verbatim.
    name = create_hive_project!("initsetup-orphan-app")
    dir = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos", name)
    capture_io { Hive::Commands::Init.new(dir, new_workflow: "writing", force: true).call }
    FileUtils.rm_rf(File.join(dir, ".hive-state", "workflows", "writing.yml"))
    FileUtils.rm_rf(File.join(dir, ".hive-state", "workflows", "writing"))
    # The per-root workflow overlay is process-memoized; force a fresh disk read.
    Hive::Workflows::Project.reset!

    assert_not_includes InitSetup.workflows(dir), "writing",
                        "the plain enumeration must reflect registry validity"
    options = InitSetup.workflow_options(project_root: dir, persisted: "writing")

    assert_includes options, "writing",
                    "the form enumeration must preserve an unloadable persisted default"
    assert_includes options, "coding"
  ensure
    Hive::Workflows::Project.reset!
  end

  test "workflow_options with no persisted value adds nothing beyond valid names" do
    name = create_hive_project!("initsetup-clean-app")
    dir = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos", name)
    Hive::Workflows::Project.reset!

    assert_equal InitSetup.workflows(dir), InitSetup.workflow_options(project_root: dir)
    assert_equal InitSetup.workflows(dir), InitSetup.workflow_options(project_root: dir, persisted: "")
  ensure
    Hive::Workflows::Project.reset!
  end
end
