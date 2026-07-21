require "test_helper"
require "yaml"

class LaunchPathFixtureTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  FIXTURE_ROOT = File.join(ROOT, "docs", "fixtures", "launch-paths")
  PATH_IDS = %w[build content].freeze

  EXPECTED_LABELS = {
    "launch" => "Add idea",
    "queued" => "Queued for the daemon",
    "running" => "Agent running",
    "approval_waiting" => "Needs your input",
    "provider_limit" => "Waiting on provider / scheduler",
    "recoverable_failure" => "Needs recovery",
    "terminal_failure" => "Error",
    "success" => "Archived",
    "artifact_inspection" => "Artifacts",
    "retry_resume" => "Retry stage",
    "next_action" => "Next action"
  }.freeze

  def test_manifest_is_an_explicit_non_live_fixture
    manifest = load_manifest

    assert_equal "hive-launch-path-fixtures/v1", manifest.fetch("schema")
    assert_equal true, manifest.fetch("fixture")
    assert_equal false, manifest.fetch("provider_completed")
    assert_equal "not_completed", manifest.fetch("live_full_replay_status")
    assert_equal "2026-07-21T15:23:25Z", manifest.fetch("observed_at")
    assert_nil manifest.fetch("live_first_artifact_time")
    assert_nil manifest.fetch("measured_full_completion_time")
    assert_equal EXPECTED_LABELS, manifest.fetch("state_labels")
  end

  def test_both_paths_have_memorable_inputs_and_complete_artifact_sets
    manifest = load_manifest

    assert_equal PATH_IDS, manifest.fetch("paths").keys
    manifest.fetch("paths").each do |id, path|
      files = [ path.fetch("input"), *path.fetch("artifacts") ]
      files.each do |relative_path|
        body = File.read(File.join(FIXTURE_ROOT, relative_path))
        refute_empty body
        assert_includes body, "Deterministic replay fixture"
      end
      assert_operator files.length, :>=, 6, "#{id} should expose the idea and its inspectable stage outputs"
    end
  end

  def test_each_cross_surface_label_is_grounded_in_its_native_producer
    helper = File.read(File.join(ROOT, "web/app/helpers/application_helper.rb"))
    task_actions = File.read(File.join(ROOT, "web/app/views/tasks/_primary_actions.html.erb"))
    task_page = File.read(File.join(ROOT, "web/app/views/tasks/show.html.erb"))
    status_view = File.read(File.join(ROOT, "web/app/views/status/index.html.erb"))
    run_controller = File.read(File.join(ROOT, "web/app/controllers/tasks/runs_controller.rb"))
    task_action = File.read(File.join(ROOT, "lib/hive/task_action.rb"))
    status_command = File.read(File.join(ROOT, "lib/hive/commands/status.rb"))

    producer_by_key = {
      "launch" => status_view,
      "queued" => run_controller,
      "running" => task_action,
      "approval_waiting" => task_action,
      "provider_limit" => status_command,
      "recoverable_failure" => task_action,
      "terminal_failure" => task_action,
      "success" => task_action,
      "artifact_inspection" => task_page,
      "retry_resume" => task_actions,
      "next_action" => task_action
    }
    EXPECTED_LABELS.each do |key, label|
      normalized_source = producer_by_key.fetch(key).downcase.tr("_", " ")
      assert_includes normalized_source, label.downcase, "#{key} must match its native producer"
    end
    assert_includes helper, 'task["action_label"]'
  end

  def test_clean_startup_installs_the_web_service_and_build_claims_match_the_patch
    guide = File.read(File.join(ROOT, "docs", "launch-paths.md"))
    setup_source = File.read(File.join(ROOT, "lib", "hive", "commands", "setup.rb"))
    plan = File.read(File.join(FIXTURE_ROOT, "build", "plan.md"))
    patch = File.read(File.join(FIXTURE_ROOT, "build", "patch.diff"))
    outcome = File.read(File.join(FIXTURE_ROOT, "build", "artifact.md"))
    response = '{"status":"ok","version":"0.1.0","revision":"7c9e12a"}'

    assert_includes guide, "hive setup --service"
    assert_includes guide, "hive daemon status || hive daemon start --detach"
    assert_includes guide, "hive web start --detach"
    assert_match(/if @service.*?if web_bundle\["ok"\].*?install_web_service/m, setup_source)
    assert_includes plan, response
    assert_includes outcome, response
    assert_includes patch, 'VERSION = "0.1.0"'
  end

  def test_public_live_content_evidence_is_timestamped_and_redacted
    evidence = File.read(File.join(ROOT, "docs", "launch-paths.md"))

    assert_includes evidence, "2026-07-21T15:23:25Z"
    assert_includes evidence, "provider budget"
    assert_includes evidence, "single bounded retry"
    refute_match(/task \d+|[0-9a-f]{8}-[0-9a-f-]{27,}|\$\d|\d[\d,]+-byte/i, evidence)
    refute_match(/reviewed terminal article (?:was|is) available/i, evidence)
  end

  private

  def load_manifest
    YAML.safe_load_file(File.join(FIXTURE_ROOT, "manifest.yml"), aliases: false)
  end
end
