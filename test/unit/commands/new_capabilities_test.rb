require "test_helper"
require "json_schemer"
require "hive/commands/init"
require "hive/commands/new"
require "hive/cli"

class NewCapabilitiesTest < Minitest::Test
  include HiveTestHelper

  def with_project(enabled: true)
    with_tmp_global_config do
      with_tmp_git_repo do |root|
        capture_io { Hive::Commands::Init.new(root, agent_skill_preflight: false).call }
        configure(root, enabled: enabled)
        yield root, File.basename(root)
      end
    end
  end

  def configure(root, enabled:, command: nil)
    path = File.join(root, ".hive-state/config.yml")
    cfg = YAML.safe_load_file(path)
    cfg["task_capabilities"] = { "enabled" => enabled }
    cfg["review"] ||= {}
    cfg["review"]["ci"] = { "command" => command }
    File.write(path, cfg.to_yaml)
  end

  def command(project, **options)
    Hive::Commands::New.new(project, "some behavior", slug_override: "capability-task", **options)
  end

  def test_production_default_adopts_new_coding_tasks_without_a_standing_exception
    assert_equal true, Hive::Config::DEFAULTS.dig("task_capabilities", "enabled")
    with_tmp_global_config(task_capabilities: nil) do
      with_tmp_git_repo do |root|
        capture_io { Hive::Commands::Init.new(root, agent_skill_preflight: false).call }
        project = File.basename(root)
        payload = nil
        capture_io { payload = command(project).call! }
        assert_equal "on", payload.dig("capabilities", "choices", "qa", "effective")
        assert payload.fetch("capability_recovery").any? { |item| item["reason"] == "task_capability_verification_unavailable" }
        assert_includes payload.fetch("capability_adoption_notice"), "separate human QA waiver"
        second = nil
        capture_io { second = Hive::Commands::New.new(project, "Another task", slug_override: "another-task").call! }
        refute second.key?("capability_adoption_notice")
        assert_equal "on", second.dig("capabilities", "choices", "qa", "effective")
        assert_equal 1, second.fetch("execution_plan_version")
      end
    end
  end

  def test_unkeyed_creation_uses_atomic_resolved_capture_and_displays_notice
    with_project do |root, project|
      output, = capture_io { command(project).call! }
      folder = File.join(root, ".hive-state/stages/1-inbox/capability-task")
      plan = Hive::TaskCapabilities::Store.new(folder).current
      assert_equal "on", plan.data.dig("choices", "qa", "effective")
      assert_includes output, "QA defaults On"
      assert_includes output, "blocked:"
      error = assert_raises(Hive::TaskCapabilities::Admission::Error) { Hive::TaskCapabilities::Admission.enforce!(Hive::Task.new(folder)) }
      assert_equal "task_capability_verification_unavailable", error.reason
      notice = File.join(root, ".hive-state/task-capabilities-adoption.json")
      assert File.file?(notice)
      assert_equal "task-capabilities-adoption.json", Hive::GitOps.new(root).run_git!("-C", File.join(root, ".hive-state"), "ls-files", "task-capabilities-adoption.json").strip
    end
  end

  def test_preview_is_json_without_a_key_and_does_not_write_or_spawn
    with_project do |root, project|
      before = Dir.glob(File.join(root, ".hive-state/**/*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.to_h { |path| [ path, File.binread(path) ] }
      output, = capture_io { command(project, preview: true, json: true).call! }
      payload = JSON.parse(output)
      assert_equal true, payload.fetch("preview")
      assert_equal true, payload.fetch("capabilities_enabled")
      assert_equal "on", payload.dig("capabilities", "choices", "qa", "effective")
      assert JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-new")))).valid?(payload)
      after = Dir.glob(File.join(root, ".hive-state/**/*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.to_h { |path| [ path, File.binread(path) ] }
      assert_equal before, after
      silent = nil
      quiet_output, = capture_io { silent = command(project).preview! }
      assert_empty quiet_output
      assert_equal payload, silent
    end
  end

  def test_replay_returns_pinned_plan_before_changed_policy_or_stale_preview
    with_project do |root, project|
      first = nil
      capture_io { first = command(project, idempotency_key: "replay").call! }
      digest = first.fetch("execution_plan_digest")
      configure(root, enabled: false)
      replay = nil
      capture_io { replay = command(project, idempotency_key: "replay", capability_preview: "stale").call! }
      assert_equal false, replay.fetch("created")
      assert_equal digest, replay.fetch("execution_plan_digest")
      assert_raises(Hive::TaskCapture::IdempotencyConflict) do
        capture_io { Hive::Commands::New.new(project, "different", idempotency_key: "replay").call! }
      end
    end
  end

  def test_qa_waiver_is_per_task_and_cannot_be_authorized_by_attempt_context
    with_project do |root, project|
      options = { capabilities: [ "qa=off" ], qa_waiver_reason: "operator docs exception", qa_waiver_checks: [ "all" ] }
      with_attempt_context(attempt_id: "active", task_generation: 0) do
        error = assert_raises(Hive::TaskCapabilities::Admission::Error) { capture_io { command(project, **options).call! } }
        assert_equal "task_capability_operator_required", error.reason
      end
      refute File.exist?(File.join(root, ".hive-state/stages/1-inbox/capability-task"))
      payload = nil
      capture_io { payload = command(project, **options).call! }
      assert_equal "waived", payload.dig("capabilities", "choices", "qa", "state")
      other = nil
      capture_io { other = Hive::Commands::New.new(project, "next behavior", slug_override: "next-capability-task").call! }
      assert_equal "on", other.dig("capabilities", "choices", "qa", "effective")
      refute other.key?("capability_adoption_notice")
    end
  end

  def test_stale_preview_fails_without_capture_and_disabled_switch_remains_legacy
    with_project do |root, project|
      preview = nil
      capture_io { preview = command(project, preview: true).call! }
      configure(root, enabled: true, command: "ruby check.rb")
      error = assert_raises(Hive::TaskCapabilities::Admission::Error) do
        capture_io { command(project, capability_preview: preview.dig("capabilities", "preview_digest")).call! }
      end
      assert_equal "task_capability_stale_preview", error.reason
      refute File.exist?(File.join(root, ".hive-state/stages/1-inbox/capability-task"))
      refute File.exist?(File.join(root, ".hive-state/task-capabilities-adoption.json"))
      configure(root, enabled: false)
      capture_io { command(project).call! }
      assert_nil Hive::TaskCapabilities::Store.new(File.join(root, ".hive-state/stages/1-inbox/capability-task")).current
      refute File.exist?(File.join(root, ".hive-state/task-capabilities-adoption.json"))
    end
  end

  def test_cli_flags_are_repeatable_and_preserve_named_choices
    captured = nil
    constructor = lambda do |*args, **options|
      captured = [ args, options ]
      Object.new.tap { |object| object.define_singleton_method(:call) { true } }
    end
    with_replaced_singleton_method(Hive::Commands::New, :new, constructor) do
      Hive::CLI.start(%w[new demo text --capability ui=on --capability qa=off --qa-waiver-reason reason --qa-waiver-check all --capability-approval security=local --preview --json])
    end
    assert_equal %w[ui=on qa=off], captured.last.fetch(:capabilities)
    assert_equal [ "all" ], captured.last.fetch(:qa_waiver_checks)
    assert_equal [ "security=local" ], captured.last.fetch(:capability_approvals)
    assert_equal true, captured.last.fetch(:preview)
  end
end

class NewCapabilitiesTest
  def test_disabled_noncoding_and_invalid_input_preview_use_typed_errors_without_adoption
    with_project(enabled: false) do |root, project|
      preview = nil
      capture_io { preview = command(project, preview: true).call! }
      assert_equal false, preview.fetch("capabilities_enabled")
      assert_empty preview.dig("capabilities", "choices")
      assert_raises(Hive::TaskCapabilities::Admission::Error) { command(project, capabilities: [ "ui=on" ]).call! }
      assert_empty Dir.glob(File.join(root, ".hive-state/stages/*/*/execution-plan-current.json"))
    end
  end

  def test_command_receipt_identity_contains_only_digest_of_waiver_free_text
    command = command("project", idempotency_key: "key", capabilities: [ "qa=off" ], qa_waiver_reason: "operator sensitive reason", qa_waiver_checks: [ "all" ])
    captured = nil
    with_replaced_singleton_method(Hive::CommandOperation, :new, ->(**options) { captured = options; Object.new }) do
      command.command_operation
    end
    refute_includes captured.fetch(:request).to_s, "operator sensitive reason"
    assert_match(/\A[0-9a-f]{64}\z/, captured.dig(:request, "capability_inputs_sha256"))
  end
end

class NewCapabilitiesTest
  def test_legacy_keyed_request_identity_does_not_gain_an_optional_capability_field
    captured = nil
    with_replaced_singleton_method(Hive::CommandOperation, :new, ->(**options) { captured = options; Object.new }) do
      command("project", idempotency_key: "old-key").command_operation
    end
    refute captured.fetch(:request).key?("capability_inputs_sha256")
  end
end

class NewCapabilitiesTest
  def test_blocked_capture_does_not_schedule_name_generator
    with_project do |_root, project|
      previous = Hive::Commands::New.instance_variable_get(:@name_generator_spawn)
      launches = []
      Hive::Commands::New.name_generator_spawn = ->(*args, **) { launches << args; raise "must not schedule" }
      capture_io { command(project).call! }
      assert_empty launches
    ensure
      Hive::Commands::New.name_generator_spawn = previous
    end
  end
end

class NewCapabilitiesTest
  def test_public_preview_call_works_without_receipts_or_writes
    with_project do |root, project|
      output, = capture_io { command(project, preview: true, json: true).call }
      assert JSON.parse(output).fetch("preview")
      refute File.exist?(File.join(root, ".hive-state/stages/1-inbox/capability-task"))
    end
  end

  def test_capture_rechecks_live_configuration_under_its_commit_lock
    with_project do |root, project|
      factory = lambda do |**options|
        Hive::TaskCapture.new(**options, before_candidate: ->(_folder) { configure(root, enabled: true, command: "ruby changed.rb") })
      end
      error = assert_raises(Hive::TaskCapabilities::Admission::Error) do
        capture_io { command(project, task_capture_factory: factory).call! }
      end
      assert_equal "task_capability_stale_preview", error.reason
      refute File.exist?(File.join(root, ".hive-state/stages/1-inbox/capability-task"))
    end
  end

  def test_corrupt_or_duplicate_adopted_replay_metadata_is_never_ignored
    with_project do |root, project|
      first = nil
      capture_io { first = command(project, idempotency_key: "replay").call! }
      duplicate = File.join(root, ".hive-state/stages/1-inbox/duplicate-task")
      FileUtils.cp_r(first.fetch("task_folder"), duplicate)
      assert_raises(Hive::TaskCapture::IdempotencyConflict) { capture_io { command(project, idempotency_key: "replay").call! } }
      File.write(File.join(duplicate, "meta.yml"), "broken: [\n")
      assert_raises(Hive::TaskCapture::IdempotencyConflict) { capture_io { command(project, idempotency_key: "replay").call! } }
    end
  end

  def test_installing_receipts_after_an_adopted_capture_requires_its_original_response
    require "hive/runtime_control_plane/command_schema_installation"
    with_project do |root, project|
      capture_io { command(project, idempotency_key: "replay").call! }
      Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(
        database: Hive::RuntimeControlPlane.database.open!,
        package_coordinates: { version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "9" * 64 })
      path = File.join(root, ".hive-state/config.yml")
      cfg = YAML.safe_load_file(path)
      cfg["command_receipts"] = { "keyed_intake_enabled" => true }
      File.write(path, cfg.to_yaml)
      assert_raises(Hive::CommandUnresolved) { capture_io { command(project, idempotency_key: "replay").call! } }
    end
  end
end
