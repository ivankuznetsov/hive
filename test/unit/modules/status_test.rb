require "test_helper"
require_relative "../../support/module_helpers"
require "hive/attempts/store"
require "hive/module_package/managed_store"
require "hive/module_package/preview"
require "hive/modules/inspector"
require "json_schemer"

class ModulesStatusTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

  NOW = Time.utc(2026, 7, 22, 12, 15, 0)

  class FakeAttempt
    attr_reader :attempt_id, :subject, :state, :outcome

    def initialize(state:, outcome:, final:, retry_charge: 1, outputs: [],
                   project_id: "project-1", attempt_id: "attempt-1", created_at: NOW)
      @attempt_id = attempt_id
      @subject = {
        "kind" => "module_hook", "project_id" => project_id,
        "module" => "demo", "hook" => "schedule", "event_id" => "event-1"
      }
      @state = state
      @outcome = outcome
      @final = final
      @data = {
        "retry_charge" => retry_charge, "created_at" => created_at.iso8601(6),
        "started_at" => NOW.iso8601(6), "ended_at" => final ? NOW.iso8601(6) : nil,
        "current_outputs" => outputs
      }
    end

    def [](key) = @data[key]
    def final? = @final
    def module_hook? = true
  end

  FakeScan = Data.define(:records)
  FakeAttemptStore = Data.define(:records) do
    def scan = FakeScan.new(records: records)
  end

  def test_projects_one_redacted_status_with_next_trigger
    with_installed_module do |root, store|
      inspector = inspector(store, root, available: { "MODULE_TOKEN" => true })
      status = inspector.inspect("demo")

      assert_equal "active", status["lifecycle_state"]
      assert_equal "a" * 40, status.dig("active", "source_commit")
      assert status.dig("integrity", "configuration_valid")
      token = status.fetch("settings").find { |row| row.fetch("name") == "api_token" }
      assert_nil token.fetch("value")
      assert_equal "MODULE_TOKEN", token.fetch("binding")
      assert_equal true, token.fetch("available")
      assert_equal "2026-07-22T13:00:00.000000Z", status.fetch("hooks").first.fetch("next_trigger_at")
      refute_includes JSON.generate(status.to_h), "raw-secret-value"
      payload = {
        "schema" => "hive-module-status", "schema_version" => 1, "ok" => true,
        "modules" => [ status.to_h ]
      }
      schema = JSONSchemer.schema(Pathname(Hive::Schemas.schema_path("hive-module-status")))
      assert schema.valid?(payload), schema.validate(payload).to_a.inspect
    end
  end

  def test_interrupted_activation_is_reported_without_reconciliation
    with_installed_module do |root, store|
      barrier = File.join(store.runtime_path("demo"), "activation-barrier.json")
      File.write(barrier, "{}")
      before = tree_digest(root)

      status = inspector(store, root).inspect("demo")

      assert_equal "activating", status["lifecycle_state"]
      assert_equal true, status.dig("integrity", "activation_fenced")
      assert_equal before, tree_digest(root)
      assert File.exist?(barrier)
    end
  end

  def test_malformed_selection_returns_bounded_corrupt_projection
    with_installed_module do |root, store|
      File.write(File.join(store.modules_dir, "demo", "selection.json"), "secret stderr\n")
      status = inspector(store, root).inspect("demo")

      assert_equal "corrupt", status["lifecycle_state"]
      assert_equal "state_corrupt", status["failure_reason"]
      refute_includes JSON.generate(status.to_h), "secret stderr"
    end
  end

  def test_status_projection_rejects_incomplete_shapes
    assert_raises(Hive::ConfigError) { Hive::Modules::Status.new("name" => "demo") }
  end

  def test_status_projection_rejects_each_nested_malformed_shape
    base = Hive::Modules::Status.corrupt(
      name: "demo", generated_at: NOW.iso8601(6)
    ).to_h
    complete_grants = Hive::ModulePackage::Manifest::PERMISSION_KEYS.to_h do |key|
      [ key, key == "repository_write" ? false : [] ]
    end
    valid_hook = {
      "id" => "schedule", "enabled" => true, "cursor" => nil,
      "binding_digest" => "a" * 64, "target" => {
        "kind" => "entrypoint", "id" => "demo.run"
      },
      "concurrency" => "drop", "schedules" => [ "0 * * * *" ],
      "event_bindings" => [], "next_trigger_at" => NOW.iso8601(6)
    }
    invalid = [
      ->(data) { data["installed"] = "yes" },
      ->(data) { data["integrity"]["journal_present"] = nil },
      ->(data) { data["settings"] = [ { "name" => "missing fields" } ] },
      ->(data) { data["grants"] = complete_grants.except("secrets") },
      ->(data) {
        data["grants"] = complete_grants.merge("secrets" => "not-an-array")
      },
      ->(data) { data["hooks"] = [ valid_hook.except("target") ] },
      ->(data) {
        data["retry"] = {
          "status" => "pending", "charge" => -1, "max" => nil,
          "reason" => nil
        }
      },
      ->(data) {
        data["artifacts"] = [
          { "path" => "result.json", "size" => -1, "sha256" => "a" * 64 }
        ]
      }
    ]
    invalid.each do |mutation|
      data = Marshal.load(Marshal.dump(base))
      mutation.call(data)
      assert_raises(Hive::ConfigError) { Hive::Modules::Status.new(data) }
    end

    with_artifact = Marshal.load(Marshal.dump(base))
    with_artifact["artifacts"] = [
      { "path" => "result.json", "size" => 1, "sha256" => "a" * 64 }
    ]
    assert_equal(
      "result.json",
      Hive::Modules::Status.new(with_artifact).fetch("artifacts").first.fetch("path")
    )

    malformed = Hive::Modules::Status.allocate
    malformed.instance_variable_set(:@data, base)
    malformed.define_singleton_method(:validate_scalar_fields!) { raise TypeError }
    assert_raises(Hive::ConfigError) { malformed.send(:validate!) }
    assert_raises(Hive::ConfigError) { malformed.send(:string!, "value", "") }
    assert_raises(Hive::ConfigError) { malformed.send(:malformed!) }
  end

  def test_inspector_summarizes_decisions_attempts_retries_artifacts_and_failures
    with_installed_module do |_root, store|
      inspector = Hive::Modules::Inspector.new(store: store, project_id: "project-1")
      decision = {
        "decision_id" => "decision-1", "hook" => "schedule", "event_id" => "event-1",
        "event_name" => "schedule", "evaluated_at" => NOW.iso8601(6),
        "outcome" => "launch", "reason" => "admitted", "binding_digest" => "a" * 64,
        "cursor_before" => nil, "cursor_after" => "event-1", "attempt_id" => "attempt-1",
        "secret" => "not-projected"
      }
      summary = inspector.send(:decision_summary, decision)
      refute summary.key?("secret")
      assert_equal "schedule", summary.fetch("hook")

      outputs = [
        {
          "path" => "artifacts/result.json", "sha256" => "b" * 64,
          "size" => 10, "raw" => "hidden"
        }
      ]
      pending = FakeAttempt.new(state: "running", outcome: nil, final: false, outputs: outputs)
      finished = FakeAttempt.new(state: "terminal", outcome: "failed", final: true, outputs: outputs)
      assert_equal "attempt-1", inspector.send(:attempt_summary, pending).fetch("attempt_id")
      assert_equal %w[path sha256 size],
                   inspector.send(:bounded_artifacts, pending).first.keys.sort
      assert_equal "pending", inspector.send(:retry_summary, nil, pending).fetch("status")
      assert_equal "finished", inspector.send(:retry_summary, nil, finished).fetch("status")
      retry_state = inspector.send(
        :retry_summary,
        { "retry" => { "status" => "secret stderr", "reason" => "token=hidden" } },
        pending
      )
      assert_equal(
        { "status" => "unknown", "charge" => nil, "max" => nil, "reason" => nil },
        retry_state
      )
      capacity_retry = inspector.send(
        :retry_summary,
        {
          "retry" => {
            "status" => "pending", "charge" => 1,
            "max" => nil, "reason" => "capacity_blocked"
          }
        },
        pending
      )
      assert_equal(
        {
          "status" => "pending", "charge" => 1,
          "max" => nil, "reason" => "capacity_blocked"
        },
        capacity_retry
      )
      assert_equal "attempt_lost",
                   inspector.send(:failure_reason, { "failure" => nil }, FakeAttempt.new(state: "lost", outcome: nil, final: true))
      assert_equal "hook_failed", inspector.send(:failure_reason, { "failure" => nil }, finished)
      assert_nil inspector.send(
        :failure_reason, { "failure" => nil }, FakeAttempt.new(state: "terminal", outcome: "succeeded", final: true)
      )

      diagnostic = {
        "schema_version" => 1, "failed_at" => NOW.iso8601(6),
        "reason" => "activation_failed", "error_class" => "Hive::ConfigError"
      }
      path = store.failed_activation_path("demo")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, Hive::WorkflowPackage::CanonicalJSON.generate(diagnostic))
      assert_equal "Hive::ConfigError", inspector.send(:safe_failed_activation, "demo").fetch("error_class")
      File.write(path, "{bad")
      assert_equal({ "reason" => "activation_failed" }, inspector.send(:safe_failed_activation, "demo"))
    end
  end

  def test_default_read_dependencies_power_installed_list_and_attempt_filtering
    with_installed_module do |_root, store|
      attempt = FakeAttempt.new(state: "running", outcome: nil, final: false)
      attempt_store = FakeAttemptStore.new(records: [ attempt ])
      with_env("MODULE_TOKEN" => "present") do
        inspector = Hive::Modules::Inspector.new(
          store: store, project_id: "project-1", attempt_store: attempt_store
        )
        statuses = inspector.all

        assert_equal [ "demo" ], statuses.map { |status| status.fetch("name") }
        token = statuses.first.fetch("settings").find do |setting|
          setting.fetch("name") == "api_token"
        end
        assert_equal true, token.fetch("available")
        assert_equal [ attempt ], inspector.send(:module_attempts, "demo")
        assert_empty inspector.send(:module_attempts, "another")
      end
    end
  end

  def test_attempt_projection_is_isolated_by_project_identity
    with_installed_module do |_root, store|
      local = FakeAttempt.new(
        state: "running", outcome: nil, final: false,
        project_id: "project-1", attempt_id: "local-attempt"
      )
      foreign = FakeAttempt.new(
        state: "terminal", outcome: "failed", final: true,
        project_id: "project-2", attempt_id: "foreign-attempt",
        created_at: NOW + 60,
        outputs: [ { "kind" => "artifact", "path" => "foreign/secret.txt" } ]
      )
      inspector = Hive::Modules::Inspector.new(
        store: store, project_id: "project-1",
        attempt_store: FakeAttemptStore.new(records: [ local, foreign ])
      )

      status = inspector.inspect("demo")

      assert_equal [ local ], inspector.send(:module_attempts, "demo")
      assert_equal "local-attempt", status.dig("latest_attempt", "attempt_id")
      refute_includes JSON.generate(status.to_h), "foreign"
    end
  end

  def test_disabled_module_does_not_advertise_a_next_trigger
    with_installed_module do |root, store|
      store.disable("demo", now: NOW)

      status = inspector(store, root).inspect("demo")

      assert_equal "disabled", status["lifecycle_state"]
      assert_nil status.fetch("hooks").first.fetch("next_trigger_at")
    end
  end

  def test_inspector_projects_conflicts_decisions_migration_and_legacy_history
    with_installed_module do |root, store|
      legacy = Object.new
      legacy.define_singleton_method(:inspect_selected) do |_name, cfg:|
        { "name" => "demo" }
      end
      conflict = Hive::Modules::Inspector.new(
        store: store, workflow_store: legacy, project_config: {},
        project_id: "project-1", clock: -> { NOW }
      ).inspect("demo")
      assert_equal "corrupt", conflict.fetch("lifecycle_state")
      assert_equal "ownership_conflict", conflict.fetch("failure_reason")

      journal = Object.new
      journal.define_singleton_method(:all) do
        [
          {
            "project_id" => "foreign", "module" => "demo",
            "evaluated_at" => (NOW + 1).iso8601(6)
          },
          {
            "project_id" => "project-1", "module" => "demo",
            "decision_id" => "local", "hook" => "schedule",
            "event_id" => "event-1", "event_name" => "schedule",
            "evaluated_at" => NOW.iso8601(6), "outcome" => "launch",
            "reason" => "admitted", "binding_digest" => "a" * 64,
            "cursor_before" => nil, "cursor_after" => "event-1",
            "attempt_id" => nil
          }
        ]
      end
      projected = Hive::Modules::Inspector.new(
        store: store, project_id: "project-1", decision_journal: journal,
        clock: -> { NOW }
      ).inspect("demo")
      assert_equal "local", projected.dig("latest_decision", "decision_id")

      inspector = Hive::Modules::Inspector.new(
        store: store, project_id: "project-1", clock: -> { NOW }
      )
      tombstone = {
        "name" => "demo", "installed" => false, "enabled" => false,
        "epoch" => 2, "high_water_at" => NOW.iso8601(6),
        "active" => nil, "previous" => nil
      }
      assert_empty inspector.send(:build_status, tombstone, NOW).fetch("hooks")

      original_diagnostic = Hive::Modules::Migration::Patrols.method(:diagnostic)
      begin
        Hive::Modules::Migration::Patrols.define_singleton_method(:diagnostic) do |*|
          { "status" => "corrupt", "admission" => false }
        end
        assert_equal(
          "migration_state_corrupt",
          inspector.send(:migration_failure, "patrol")
        )
        Hive::Modules::Migration::Patrols.define_singleton_method(:diagnostic) do |*|
          { "status" => "module", "admission" => false }
        end
        assert_equal "migration_fenced", inspector.send(:migration_failure, "patrol")
        Hive::Modules::Migration::Patrols.define_singleton_method(:diagnostic) do |*|
          { "status" => "module", "admission" => true }
        end
        assert_nil inspector.send(:migration_failure, "patrol")
      ensure
        Hive::Modules::Migration::Patrols.define_singleton_method(
          :diagnostic, original_diagnostic
        )
      end

      generation = File.join(root, "legacy-generation")
      configuration = File.join(root, "legacy-configuration.json")
      FileUtils.mkdir_p(generation)
      File.write(configuration, "{}")
      workflow = Object.new
      workflow.define_singleton_method(:inspect_selections) do |cfg:|
        [ { "name" => "selected" } ]
      end
      workflow.define_singleton_method(:inspect_task_references) do |name = nil|
        rows = [
          {
            name: "historical", commit: "a" * 40, digest: "b" * 64,
            configuration_digest: "c" * 64
          }
        ]
        name ? rows.select { |row| row.fetch(:name) == name } : rows
      end
      workflow.define_singleton_method(:generation_path) { |*| generation }
      workflow.define_singleton_method(:configuration_path) { |*| configuration }
      history_inspector = Hive::Modules::Inspector.new(
        store: store, workflow_store: workflow, project_config: {},
        project_id: "project-1", clock: -> { NOW }
      )
      assert_equal(
        %w[selected historical],
        history_inspector.send(
          :legacy_workflow_names, include_tombstones: true
        )
      )
      history = history_inspector.send(:build_legacy_history, "historical", NOW)
      assert_equal "uninstalled_history", history.fetch("lifecycle_state")
      assert history.dig("integrity", "generation_present")
      assert_nil history.fetch("failure_reason")

      FileUtils.rm_rf(generation)
      missing = history_inspector.send(:build_legacy_history, "historical", NOW)
      assert_equal "state_corrupt", missing.fetch("failure_reason")

      workflow.define_singleton_method(:inspect_task_references) do |*|
        raise Hive::ConfigError, "bad history"
      end
      corrupt = history_inspector.send(:build_legacy_history, "historical", NOW)
      assert_equal "corrupt", corrupt.fetch("lifecycle_state")
      assert_equal "state_corrupt", corrupt.fetch("failure_reason")
    end
  end

  private

  def with_installed_module
    with_tmp_dir do |root|
      package = File.join(root, "package")
      resolution, descriptor = write_module_package(package)
      store = Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state"))
      preview = Hive::ModulePackage::Preview.build(
        operation: "install", descriptor: descriptor, generation: resolution,
        current: nil, current_configuration: nil,
        settings: { "mode" => "safe", "api_token" => "MODULE_TOKEN" },
        hooks: { "schedule" => true }, grants: exact_grants(descriptor), now: NOW - 60
      )
      store.apply(preview, package_root: package, resolution: resolution, now: NOW - 60)
      yield root, store
    end
  end

  def inspector(store, root, available: {})
    Hive::Modules::Inspector.new(
      store: store, project_id: "project-1",
      attempt_store: Hive::Attempts::Store.new(root: File.join(root, "attempts"), create_directories: false),
      secret_availability: ->(name) { available.fetch(name, false) }, clock: -> { NOW }
    )
  end

  def tree_digest(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
      next unless File.file?(path)
      [ path.delete_prefix("#{root}/"), Digest::SHA256.file(path).hexdigest ]
    end
  end
end
