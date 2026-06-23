require "application_system_test_case"

class RepoSetupFlowTest < ApplicationSystemTestCase
  test "fresh setup writes the selected built-in workflow" do
    root = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos-system-workflow-fresh")
    name = "workflow-web-fresh"
    dir = create_git_repo!(root, name)

    sign_in!
    with_repos_root(root) do
      visit "/repos/new?url=ivankuznetsov/#{name}&name=#{name}"

      assert_selector "label", text: "Workflow", wait: 5
      assert_equal %w[coding content], workflow_option_values,
                   "fresh setup should list only built-in workflows with coding first"
      assert_equal "coding", workflow_select.value,
                   "fresh setup should preselect coding"
      assert_no_selector "select[name='settings[workflow]'] option[value='writing']",
                         wait: 0

      select "content", from: "Workflow"
      click_button "Clone and init"

      assert_current_path "/repos", wait: 10
      assert_text "#{name} is registered", wait: 5
    end

    config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
    assert_equal "content", config.fetch("default_workflow"),
                 "the browser-selected workflow should be written by the real Init path"
  end

  test "rerun setup lists project workflows and preselects current default" do
    root = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos-system-workflow-rerun")
    name = "workflow-web-rerun"
    dir = create_git_repo!(root, name)
    capture_io { Hive::Commands::Init.new(dir, new_workflow: "writing", force: true).call }

    sign_in!
    visit "/repos/new?project=#{name}"

    assert_selector "label", text: "Workflow", wait: 5
    values = workflow_option_values
    assert_equal "coding", values.first,
                 "rerun setup should keep built-in coding first"
    assert_includes values, "content",
                    "rerun setup should keep built-in content available"
    assert_includes values, "writing",
                    "rerun setup should include project-authored workflows"
    assert_equal "writing", workflow_select.value,
                 "rerun setup should preselect the project's current default workflow"
  end

  private

  def workflow_select
    find("select[name='settings[workflow]']")
  end

  def workflow_option_values
    all("select[name='settings[workflow]'] option", wait: 5).map(&:value)
  end

  def create_git_repo!(root, name)
    dir = File.join(root, name)
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    system("git", "init", "-q", dir, exception: true)
    system("git", "-C", dir, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", dir, "config", "user.name", "Hive Test", exception: true)
    File.write(File.join(dir, "README.md"), "# #{name}\n")
    system("git", "-C", dir, "add", ".", exception: true)
    system("git", "-C", dir, "-c", "user.email=test@example.com", "-c", "user.name=Test",
           "commit", "-qm", "init", exception: true)
    dir
  end

  def with_repos_root(root)
    old = ENV["HIVEBOX_REPOS_DIR"]
    ENV["HIVEBOX_REPOS_DIR"] = root
    yield
  ensure
    old.nil? ? ENV.delete("HIVEBOX_REPOS_DIR") : ENV["HIVEBOX_REPOS_DIR"] = old
  end
end
