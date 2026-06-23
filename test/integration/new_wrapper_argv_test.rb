require "test_helper"
require "open3"
require "rbconfig"
require "hive/commands/init"
require "hive/task"
require "hive/task_meta"
require "hive/workflows/project"

class NewWrapperArgvTest < Minitest::Test
  include HiveTestHelper

  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)
  WORKFLOW_ID = "my-flow"

  def setup
    super
    Hive::Workflows::Project.reset!
  end

  def teardown
    Hive::Workflows::Project.reset!
    super
  end

  def test_canonical_workflow_hint_command_pins_task_to_project_workflow
    with_workflow_project do |home, project_root, project|
      out, err, status = run_hive(home, "new", project, "--workflow", WORKFLOW_ID, "custom workflow task",
                                  chdir: project_root)

      assert status.success?, "canonical hive new command should succeed, stderr was: #{err}"
      assert_includes out, "hive: captured"
      folder = only_task_folder(project_root)
      assert_pinned_to_my_flow(folder)
      refute_includes File.read(File.join(folder, "idea.md")), "--workflow",
                      "lifted --workflow must not be swallowed into idea.md"
    end
  end

  def test_workflow_option_before_project_still_pins_task
    with_workflow_project do |home, project_root, project|
      _out, err, status = run_hive(home, "new", "--workflow", WORKFLOW_ID, project, "before project task",
                                   chdir: project_root)

      assert status.success?, "before-project --workflow should still succeed, stderr was: #{err}"
      assert_pinned_to_my_flow(only_task_folder(project_root))
    end
  end

  def test_workflow_equals_form_after_project_pins_task
    with_workflow_project do |home, project_root, project|
      _out, err, status = run_hive(home, "new", project, "--workflow=#{WORKFLOW_ID}", "equals workflow task",
                                   chdir: project_root)

      assert status.success?, "--workflow=ID should be lifted after project, stderr was: #{err}"
      assert_pinned_to_my_flow(only_task_folder(project_root))
    end
  end

  def test_depends_on_and_workflow_after_project_are_both_lifted
    with_workflow_project do |home, project_root, project|
      _out, err, status = run_hive(home, "new", project, "--depends-on", "42", "--workflow", WORKFLOW_ID,
                                   "dependent workflow task", chdir: project_root)

      assert status.success?, "--depends-on and --workflow should both lift, stderr was: #{err}"
      folder = only_task_folder(project_root)
      assert_pinned_to_my_flow(folder)
      assert_equal "42", Hive::TaskMeta.read(folder)[:depends_on]
    end
  end

  def test_trailing_workflow_option_after_text_is_lifted
    with_workflow_project do |home, project_root, project|
      _out, err, status = run_hive(home, "new", project, "trailing option task", "--workflow", WORKFLOW_ID,
                                   chdir: project_root)

      assert status.success?, "trailing --workflow should lift out of text, stderr was: #{err}"
      folder = only_task_folder(project_root)
      assert_pinned_to_my_flow(folder)
      refute_includes File.read(File.join(folder, "idea.md")), "--workflow"
    end
  end

  def test_trailing_valueless_value_option_stays_literal_text
    with_cli_project do |home, project_root, project|
      _out, err, status = run_hive(home, "new", project, "idea1 idea2", "--depends-on", chdir: project_root)

      assert status.success?, "trailing value-less --depends-on must not eat PROJECT, stderr was: #{err}"
      folder = only_task_folder(project_root)
      assert_nil Hive::TaskMeta.read(folder)[:depends_on], "value-less --depends-on must not bind a dependency"
      assert_includes File.read(File.join(folder, "idea.md")), "idea1 idea2 --depends-on"
    end
  end

  def test_depends_on_equals_form_after_project_is_lifted
    with_cli_project do |home, project_root, project|
      _out, err, status = run_hive(home, "new", project, "--depends-on=42", "depends equals task", chdir: project_root)

      assert status.success?, "--depends-on=42 should be lifted after project, stderr was: #{err}"
      folder = only_task_folder(project_root)
      assert_equal "42", Hive::TaskMeta.read(folder)[:depends_on]
      refute_includes File.read(File.join(folder, "idea.md")), "--depends-on"
    end
  end

  def test_literal_double_dash_keeps_following_options_as_text
    with_cli_project do |home, project_root, project|
      _out, err, status = run_hive(home, "new", project, "--", "--workflow", "id", "text", chdir: project_root)

      assert status.success?, "literal -- should keep following tokens as task text, stderr was: #{err}"
      folder = only_task_folder(project_root)
      assert_nil Hive::TaskMeta.read(folder)[:workflow], "options after -- must not pin a workflow"
      assert_includes File.read(File.join(folder, "idea.md")), "--workflow id text"
    end
  end

  def test_workflow_looking_substring_inside_one_text_argument_stays_literal
    with_cli_project do |home, project_root, project|
      _out, err, status = run_hive(home, "new", project, "fix the --workflow parsing bug", chdir: project_root)

      assert status.success?, "quoted text containing --workflow should remain literal, stderr was: #{err}"
      folder = only_task_folder(project_root)
      assert_nil Hive::TaskMeta.read(folder)[:workflow], "literal --workflow substring must not pin a workflow"
      assert_includes File.read(File.join(folder, "idea.md")), "fix the --workflow parsing bug"
    end
  end

  def test_json_boolean_after_project_is_lifted_but_new_stays_plain_text
    with_cli_project do |home, project_root, project|
      out, err, status = run_hive(home, "new", project, "--json", "json flag task", chdir: project_root)

      assert status.success?, "--json after project should not be swallowed into text, stderr was: #{err}"
      assert_includes out, "hive: captured"
      refute_match(/\A\s*\{/, out, "hive new still emits plain text even when --json is lifted")
      folder = only_task_folder(project_root)
      assert_nil Hive::TaskMeta.read(folder)[:workflow]
      refute_includes File.read(File.join(folder, "idea.md")), "--json"
      assert_includes File.read(File.join(folder, "idea.md")), "json flag task"
    end
  end

  def test_missing_text_after_lifted_workflow_fails_without_creating_task
    with_workflow_project do |home, project_root, project|
      _out, err, status = run_hive(home, "new", project, "--workflow", WORKFLOW_ID, chdir: project_root)

      refute status.success?, "hive new without text should fail"
      assert_includes err, "missing task text"
      assert_empty task_folders(project_root), "missing text must not create an empty-slug task folder"
    end
  end

  def test_unrecognized_option_after_project_stays_literal_text
    with_cli_project do |home, project_root, project|
      _out, err, status = run_hive(home, "new", project, "--foo", "idea", chdir: project_root)

      assert status.success?, "unrecognized --foo after project should remain task text, stderr was: #{err}"
      folder = only_task_folder(project_root)
      assert_nil Hive::TaskMeta.read(folder)[:workflow]
      assert_includes File.read(File.join(folder, "idea.md")), "--foo idea"
    end
  end

  private

  def with_workflow_project
    with_cli_project do |home, project_root, project|
      out, err, status = run_hive(home, "workflow", "new", WORKFLOW_ID, chdir: project_root)
      assert status.success?, "workflow scaffold should succeed, stdout: #{out}, stderr: #{err}"
      assert_includes out, %(hive new #{project} --workflow #{WORKFLOW_ID} "<your idea>")

      yield home, project_root, project
    end
  end

  def with_cli_project
    with_tmp_global_config do |home|
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        yield home, project_root, File.basename(project_root)
      end
    end
  end

  def run_hive(home, *args, chdir: Dir.pwd)
    Open3.capture3(
      {
        "HIVE_HOME" => home,
        "HOME" => home,
        "HIVE_BIN" => fake_name_generator_bin(home),
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => "1",
        "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "1"
      },
      RbConfig.ruby, "-Ilib", HIVE_BIN, *args,
      chdir: chdir
    )
  end

  def fake_name_generator_bin(home)
    path = File.join(home, "fake-hive-name-generator")
    return path if File.executable?(path)

    File.write(path, "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, path)
    path
  end

  def only_task_folder(project_root)
    folders = task_folders(project_root)
    assert_equal 1, folders.size, "expected one task folder, got #{folders.inspect}"
    folders.first
  end

  def task_folders(project_root)
    Dir[File.join(project_root, ".hive-state", "stages", "*", "*")].select { |path| File.directory?(path) }
  end

  def assert_pinned_to_my_flow(folder)
    meta = Hive::TaskMeta.read(folder)
    assert_equal WORKFLOW_ID, meta[:workflow], "meta.yml should pin the selected workflow"

    Hive::Workflows::Project.reset!
    workflow = Hive::Task.new(folder).workflow
    assert_equal WORKFLOW_ID.to_sym, workflow.id
    assert_equal "2-work", workflow.stages.fetch(1).dir
    refute_equal "2-brainstorm", workflow.stages.fetch(1).dir
  end
end
