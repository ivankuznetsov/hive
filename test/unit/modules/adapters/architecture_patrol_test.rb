require "test_helper"
require "hive/modules/adapters/architecture_patrol"
require "hive/module_package/validator"

class ModulesAdaptersArchitecturePatrolTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 22, 17, 0, 0)
  DIGEST = "a" * 64
  Configuration = Data.define(:settings, :grants, :digest, :generation)

  class FakeCommand
    def initialize(result = { "ok" => true }) = @result = result
    def call = @result
  end

  class RaisingCommand
    def call = raise("engine failed")
  end

  class FakeStateStore
    attr_reader :ensured

    def ensure! = @ensured = true
  end

  class FakeScheduler
    attr_reader :reserved, :completed, :cancelled

    def initialize(candidates, complete_status: :classified)
      @candidates = candidates
      @complete_status = complete_status
    end

    def candidates(now:) = @candidates.map { |candidate| candidate.merge(now: now) }

    def reserve(candidate, now:)
      @reserved = [ candidate, now ]
      candidate.merge(
        manifest_path: candidate.fetch(:manifest_path, "/project/manifest.json"),
        dispatch_token: {
          kind: :architecture_patrol, phase: candidate.fetch(:action_phase, :discovery),
          job_id: candidate.fetch(:job_id), registration: "demo"
        }
      )
    end

    def complete(**options)
      @completed = options
      { status: @complete_status }
    end

    def cancel(*args, **options) = @cancelled = [ args, options ]
  end

  def test_first_party_package_is_strictly_validated
    result = Hive::ModulePackage::Validator.validate!(
      File.expand_path("../../../../modules/architecture-patrol", __dir__),
      catalog_commit: "f" * 40
    )

    assert_equal "architecture-patrol", result.descriptor.name
    assert_equal "architecture-patrol", result.descriptor.type
    assert_equal(
      %w[setup scheduled-discovery merged-pr-discovery actions],
      result.descriptor.hooks.map { |hook| hook.fetch("id") }
    )
    assert_equal [ "pull_request.merged" ], result.descriptor.hooks.fetch(2).fetch("events")
    assert_equal %w[issues pull_requests], result.descriptor.permissions.fetch("github_mutations")
  end

  def test_shadow_merged_event_uses_exact_reconciler_job_without_claiming
    with_project do |project|
      scheduler = FakeScheduler.new([ candidate ])
      commands = []
      shadow = []
      adapter = adapter_for(
        scheduler, commands: commands, shadow: shadow
      )

      assert_equal 0, adapter.call(
        project: project, hook_id: "merged-pr-discovery",
        event: merged_event, configuration: configuration(shadow: true)
      )
      assert_nil scheduler.reserved
      assert_empty commands
      assert_equal "due", shadow.fetch(0).fetch("rationale")
      assert_equal "job-7", shadow.fetch(0).fetch("job_id")
      refute File.exist?(File.join(project.fetch("path"), ".hive-state", "refactor_patrol"))
    end
  end

  def test_scheduled_action_reserves_existing_lifecycle_and_invokes_internal_mode
    with_project(owner: "module") do |project|
      scheduler = FakeScheduler.new([ candidate.merge(action_phase: :action) ])
      commands = []
      adapter = adapter_for(scheduler, commands: commands)

      assert_equal 0, adapter.call(
        project: project, hook_id: "actions", event: schedule_event,
        configuration: configuration(shadow: false)
      )

      name, options = commands.fetch(0)
      assert_equal "demo", name
      assert options.fetch(:actions)
      assert_equal "/project/manifest.json", options.fetch(:job_manifest)
      assert_equal project, options.fetch(:project_entry)
      assert_instance_of Hive::Modules::CapabilityContext, options.fetch(:capability_context)
      assert_equal true, options.fetch(:config_loader).call(project.fetch("path")).dig("refactor_patrol", "enabled")
      assert_equal "job-7", scheduler.completed.fetch(:dispatch_token).fetch(:job_id)
    end
  end

  def test_permission_denial_precedes_claim_and_engine
    with_project(owner: "module") do |project|
      scheduler = FakeScheduler.new([ candidate ])
      commands = []
      denied = configuration(shadow: false)
      denied.grants["github_mutations"] = [ "pull_requests" ]
      adapter = adapter_for(scheduler, commands: commands)

      assert_raises(Hive::Modules::CapabilityDenied) do
        adapter.call(
          project: project, hook_id: "scheduled-discovery", event: schedule_event,
          configuration: denied
        )
      end
      assert_nil scheduler.reserved
      assert_empty commands
    end
  end

  def test_merged_event_rejects_manifest_identity_drift
    with_project do |project|
      scheduler = FakeScheduler.new([ candidate ])
      adapter = adapter_for(scheduler)
      event = merged_event
      event["payload"]["manifest_digest"] = "b" * 64

      error = assert_raises(Hive::ConfigError) do
        adapter.call(
          project: project, hook_id: "merged-pr-discovery", event: event,
          configuration: configuration(shadow: true)
        )
      end
      assert_match(/manifest identity/, error.message)
      assert_nil scheduler.reserved
    end
  end

  def test_setup_uses_authoritative_state_store_and_default_factories_are_constructible
    with_project(owner: "module") do |project|
      state_store = FakeStateStore.new
      adapter = Hive::Modules::Adapters::ArchitecturePatrol.new(
        state_store_factory: ->(_root) { state_store }
      )

      assert_equal 0, adapter.call(
        project: project, hook_id: "setup", event: event("project.registered"),
        configuration: configuration(shadow: false)
      )
      assert state_store.ensured
      refute_nil Hive::Modules::Adapters::ArchitecturePatrol.new

      write_migration_state(project, "legacy")
      shadow = []
      shadow_adapter = Hive::Modules::Adapters::ArchitecturePatrol.new(
        state_store_factory: ->(_root) { state_store }, shadow_sink: ->(row) { shadow << row }
      )
      assert_equal 0, shadow_adapter.call(
        project: project, hook_id: "setup", event: event("project.registered"),
        configuration: configuration(shadow: true)
      )
      assert_equal "setup", shadow.fetch(0).fetch("rationale")
    end
  end

  def test_retry_result_and_engine_exception_preserve_scheduler_lifecycle
    with_project(owner: "module") do |project|
      retrying = FakeScheduler.new([ candidate ], complete_status: :retry)
      adapter = adapter_for(retrying)
      assert_equal 1, adapter.call(
        project: project, hook_id: "scheduled-discovery", event: schedule_event,
        configuration: configuration(shadow: false)
      )

      failing = FakeScheduler.new([ candidate ])
      adapter = Hive::Modules::Adapters::ArchitecturePatrol.new(
        command_factory: ->(*) { RaisingCommand.new },
        scheduler_factory: ->(**) { failing }, shadow_sink: ->(_record) { }
      )
      error = assert_raises(RuntimeError) do
        adapter.call(
          project: project, hook_id: "scheduled-discovery", event: schedule_event,
          configuration: configuration(shadow: false)
        )
      end
      assert_equal "engine failed", error.message
      assert_equal "module_hook_error", failing.cancelled.fetch(1).fetch(:reason)
    end
  end

  def test_no_candidate_dry_run_shadow_and_hook_validation_are_side_effect_free
    with_project do |project|
      shadow = []
      scheduler = FakeScheduler.new([])
      adapter = adapter_for(scheduler, shadow: shadow)
      assert_equal 0, adapter.call(
        project: project, hook_id: "scheduled-discovery", event: schedule_event,
        configuration: configuration(shadow: true)
      )
      assert_equal "not_due", shadow.fetch(0).fetch("rationale")
      assert_nil scheduler.reserved

      assert_raises(Hive::ConfigError) do
        adapter.call(
          project: project, hook_id: "unknown", event: schedule_event,
          configuration: configuration(shadow: true)
        )
      end
      assert_raises(Hive::ConfigError) do
        adapter.call(
          project: project, hook_id: "setup", event: schedule_event,
          configuration: configuration(shadow: true)
        )
      end
    end
  end

  def test_default_shadow_comparator_keeps_missing_legacy_capture_noncomparable
    with_project do |project|
      scheduler = FakeScheduler.new([ candidate.merge(job_id: "other") ])
      commands = []
      adapter = Hive::Modules::Adapters::ArchitecturePatrol.new(
        command_factory: lambda do |name, options|
          commands << [ name, options ]
          FakeCommand.new
        end,
        scheduler_factory: ->(**) { scheduler }
      )
      assert_equal 0, adapter.call(
        project: project, hook_id: "merged-pr-discovery", event: merged_event,
        configuration: configuration(shadow: true)
      )
      assert_empty commands
      files = Dir.glob(File.join(
        project.fetch("hive_state_path"), "module-runtime", "migration", "shadow", "**", "*.json"
      ))
      refute_empty files
      record = JSON.parse(File.binread(files.fetch(0)))
      refute record.fetch("comparable")
      assert_nil record.fetch("evidence_source")
      assert_nil record.fetch("legacy_capture")
      assert_empty record.fetch("legacy_effects")
    end
  end

  def test_default_shadow_projects_a_candidate_without_legacy_capture
    with_project do |project|
      scheduler = FakeScheduler.new([ candidate ])
      adapter = Hive::Modules::Adapters::ArchitecturePatrol.new(
        command_factory: ->(*) { flunk("shadow discovery must not invoke the engine") },
        scheduler_factory: ->(**) { scheduler }
      )

      assert_equal 0, adapter.call(
        project: project, hook_id: "scheduled-discovery", event: schedule_event,
        configuration: configuration(shadow: true)
      )

      file = Dir.glob(File.join(
        project.fetch("hive_state_path"), "module-runtime", "migration", "shadow", "**", "*.json"
      )).fetch(0)
      record = JSON.parse(File.binread(file))
      assert_equal "job-7", record.dig("module_decision", "job_id")
      assert_equal "discovery", record.dig("module_decision", "phase")
      assert_equal "due", record.dig("module_decision", "rationale")
      refute record.fetch("comparable")
    end
  end

  def test_default_shadow_comparator_accepts_finalized_scheduler_capture
    with_project do |project|
      scheduler = FakeScheduler.new([ candidate ])
      adapter = Hive::Modules::Adapters::ArchitecturePatrol.new(
        scheduler_factory: ->(**) { scheduler }
      )
      capture = finalized_capture
      event = schedule_event
      event["payload"]["legacy_mutator_capture"] = capture.to_h

      assert_equal 0, adapter.call(
        project: project, hook_id: "scheduled-discovery", event: event,
        configuration: configuration(shadow: true)
      )
      file = Dir.glob(File.join(
        project.fetch("hive_state_path"), "module-runtime", "migration", "shadow", "**", "*.json"
      )).fetch(0)
      record = JSON.parse(File.binread(file))
      assert record.fetch("comparable")
      assert_equal "legacy_mutator_capture", record.fetch("evidence_source")
      assert_equal "job-7",
                   record.dig("legacy_capture", "selection", "job_id")
    end
  end

  def test_default_shadow_comparator_detects_independent_decision_divergence
    with_project do |project|
      scheduler = FakeScheduler.new([ candidate ])
      adapter = Hive::Modules::Adapters::ArchitecturePatrol.new(
        scheduler_factory: ->(**) { scheduler }
      )
      capture = finalized_capture(
        selection:
          Hive::Modules::Migration::PatrolDecisionProjection.build(
            module_name: "architecture-patrol",
            rationale: "not_due"
          )
      )
      event = schedule_event
      event["payload"]["legacy_mutator_capture"] = capture.to_h

      assert_equal 0, adapter.call(
        project: project, hook_id: "scheduled-discovery", event: event,
        configuration: configuration(shadow: true)
      )
      file = Dir.glob(File.join(
        project.fetch("hive_state_path"), "module-runtime", "migration", "shadow", "**", "*.json"
      )).fetch(0)
      record = JSON.parse(File.binread(file))

      assert record.fetch("comparable")
      assert_equal(
        %w[$.job_id $.phase $.rationale],
        record.fetch("unexplained_differences").map { |row| row.fetch("path") }
      )
    end
  end

  def test_default_command_and_scheduler_factories_forward_to_legacy_components
    with_project(owner: "module") do |project|
      scheduler = FakeScheduler.new([ candidate ])
      calls = []
      test_case = self
      original_command = Hive::Commands::RefactorPatrol.method(:new)
      original_scheduler = Hive::Daemon::RefactorPatrolScheduler.method(:new)
      Hive::Commands::RefactorPatrol.define_singleton_method(:new) do |name, **options|
        calls << [ name, options ]
        FakeCommand.new
      end
      Hive::Daemon::RefactorPatrolScheduler.define_singleton_method(:new) do |**options|
        test_case.assert_equal [ project ], options.fetch(:registry).call
        scheduler
      end
      begin
        adapter = Hive::Modules::Adapters::ArchitecturePatrol.new
        assert_equal 0, adapter.call(
          project: project, hook_id: "scheduled-discovery", event: schedule_event,
          configuration: configuration(shadow: false)
        )
      ensure
        Hive::Commands::RefactorPatrol.define_singleton_method(:new, original_command)
        Hive::Daemon::RefactorPatrolScheduler.define_singleton_method(:new, original_scheduler)
      end
      assert_equal "demo", calls.fetch(0).fetch(0)
    end
  end

  def test_malformed_legacy_shadow_capture_is_rejected
    adapter = Hive::Modules::Adapters::ArchitecturePatrol.new
    malformed = event(
      "schedule",
      "payload" => {
        "legacy_mutator_capture" => {
          "decision" => {}, "effects" => {}
        }
      }
    )

    error = assert_raises(Hive::ConfigError) do
      adapter.send(:legacy_capture, malformed)
    end
    assert_match(/legacy shadow capture is malformed/, error.message)

    with_project do |project|
      commands = []
      malformed_event = merged_event
      malformed_event["payload"]["legacy_mutator_capture"] = {
        "decision" => {}, "effects" => {}
      }
      scheduler = FakeScheduler.new([ candidate ])
      adapter = Hive::Modules::Adapters::ArchitecturePatrol.new(
        command_factory: lambda do |name, options|
          commands << [ name, options ]
          FakeCommand.new
        end,
        scheduler_factory: ->(**) { scheduler }
      )

      assert_raises(Hive::ConfigError) do
        adapter.call(
          project: project, hook_id: "merged-pr-discovery", event: malformed_event,
          configuration: configuration(shadow: true)
        )
      end
      assert_nil scheduler.reserved
      assert_empty commands
      assert_empty Dir.glob(File.join(
        project.fetch("hive_state_path"), "module-runtime", "migration", "shadow", "**", "*.json"
      ))
    end
  end

  def test_shadow_partitions_receipts_and_rejects_cross_project_capture
    adapter = Hive::Modules::Adapters::ArchitecturePatrol.new
    wrong_project = schedule_event
    wrong_project["project"] = "other"
    wrong_project["payload"]["legacy_mutator_capture"] =
      finalized_capture.to_h
    assert_raises(Hive::ConfigError) do
      adapter.send(:legacy_capture, wrong_project)
    end

    receipt_type = Data.define(:intent)
    intent_type = Data.define(:module_name, :authority)
    legacy = receipt_type.new(
      intent: intent_type.new(
        module_name: "architecture-patrol",
        authority: "legacy"
      )
    )
    shadow = receipt_type.new(
      intent: intent_type.new(
        module_name: "architecture-patrol",
        authority: "shadow"
      )
    )
    recorded = []
    comparator = Object.new
    comparator.define_singleton_method(:record!) do |**attributes|
      recorded << attributes
    end
    adapter.define_singleton_method(:occurrence_receipts) do |*, **|
      [ legacy, shadow ]
    end
    adapter.define_singleton_method(:shadow_comparator) do |_project|
      comparator
    end
    shadow_event = schedule_event
    shadow_event["payload"]["legacy_mutator_capture"] =
      finalized_capture.to_h
    assert_equal 0, adapter.send(
      :shadow,
      { "path" => "/tmp/project" },
      configuration(shadow: true),
      shadow_event,
      "due",
      candidate
    )
    assert_equal [ legacy ], recorded.fetch(0).fetch(:legacy_effects)
    assert_equal [ shadow ], recorded.fetch(0).fetch(:module_effects)
  end

  def test_occurrence_receipt_index_is_bounded_and_module_filtered
    adapter = Hive::Modules::Adapters::ArchitecturePatrol.new
    page_type = Data.define(:records, :next_cursor)
    receipt_type = Data.define(:intent)
    intent_type = Data.define(:module_name)
    architecture_receipt = receipt_type.new(
      intent: intent_type.new(module_name: "architecture-patrol")
    )
    foreign_receipt = receipt_type.new(
      intent: intent_type.new(module_name: "patrol")
    )
    store = Object.new
    store.define_singleton_method(:receipts_for_occurrence) do |*, **|
      page_type.new(
        records: [ architecture_receipt, foreign_receipt ],
        next_cursor: nil
      )
    end
    adapter.define_singleton_method(:evidence_store) { |_project| store }
    assert_equal(
      [ architecture_receipt ],
      adapter.send(
        :occurrence_receipts,
        { "path" => "/tmp/project" },
        finalized_capture
      )
    )

    store.define_singleton_method(:receipts_for_occurrence) do |*, **|
      page_type.new(records: [], next_cursor: "receipt-next")
    end
    assert_raises(Hive::ConfigError) do
      adapter.send(
        :occurrence_receipts,
        { "path" => "/tmp/project" },
        finalized_capture
      )
    end
  end

  private

  def adapter_for(scheduler, commands: [], shadow: [])
    Hive::Modules::Adapters::ArchitecturePatrol.new(
      command_factory: lambda do |name, options|
        commands << [ name, options ]
        FakeCommand.new
      end,
      scheduler_factory: lambda do |**options|
        options.fetch(:registry).call
        scheduler
      end,
      shadow_sink: ->(record) { shadow << record }
    )
  end

  def with_project(owner: "legacy")
    with_tmp_dir do |root|
      state = File.join(root, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(
        File.join(state, "config.yml"),
        {
          "hive_state_path" => ".hive-state",
          "patrol" => { "enabled" => true },
          "refactor_patrol" => { "enabled" => true }
        }.to_yaml
      )
      project = {
        "name" => "demo", "project_id" => "project-1",
        "path" => root, "hive_state_path" => state
      }
      write_migration_state(project, owner)
      yield(project)
    end
  end

  def write_migration_state(project, owner)
    cfg = Hive::Config.load(project.fetch("path"))
    timestamp = NOW.iso8601(6)
    state = {
      "schema" => "hive-module-migration", "schema_version" => 1,
      "project" => project.fetch("name"), "project_root" => project.fetch("path"),
      "epoch" => 1, "status" => owner == "module" ? "module" : "shadowing",
      "owners" => Hive::Modules::Migration::Patrols::MODULES.to_h { |name| [ name, owner ] },
      "admissions" => Hive::Modules::Migration::Patrols::MODULES.to_h { |name| [ name, true ] },
      "bindings" => Hive::Modules::Migration::Patrols::MODULES.to_h do |name|
        [ name, {
          "reviewed_config" => cfg,
          "reviewed_config_digest" => Digest::SHA256.hexdigest(
            Hive::Modules::Migration::Patrols.canonical(cfg)
          )
        } ]
      end,
      "blockers" => {}, "cutover_selections" => {}, "watermarks" => {},
      "shadow_started_at" => timestamp, "cutover_at" => nil, "rollback_at" => nil,
      "updated_at" => timestamp
    }
    path = Hive::Modules::Migration::Patrols.state_file(
      project.fetch("path"), hive_state_path: project.fetch("hive_state_path")
    )
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, Hive::Modules::Migration::Patrols.canonical(state))
  end

  def candidate
    {
      job_id: "job-7", action_phase: :discovery,
      manifest_path: "/project/manifest.json",
      source: { "manifest_checksum" => DIGEST }
    }
  end

  def configuration(shadow:)
    Configuration.new(
      settings: { "shadow_mode" => shadow, "dry_run" => false },
      grants: {
        "repository_write" => true, "github_mutations" => %w[issues pull_requests],
        "external_commands" => %w[gh git], "network_hosts" => [ "api.github.com" ],
        "filesystem_read" => [ "repository" ],
        "filesystem_write" => [
          ".hive-state/refactor_patrol/**", ".hive-state/stages/**"
        ], "secrets" => []
      }, digest: "d" * 64,
      generation: { "source_commit" => "a" * 40 }
    )
  end

  def schedule_event = event("schedule", "payload" => { "schedule" => "*/10 * * * *" })

  def merged_event
    event(
      "pull_request.merged",
      "payload" => { "job_id" => "job-7", "manifest_digest" => DIGEST }
    )
  end

  def event(name, overrides = {})
    {
      "event_id" => "evt-#{'a' * 64}", "event_name" => name,
      "project_id" => "project-1", "project" => "demo",
      "occurred_at" => NOW.iso8601(6), "payload" => {}
    }.merge(overrides)
  end

  def finalized_capture(selection: nil)
    selection ||=
      Hive::Modules::Migration::PatrolDecisionProjection.build(
        module_name: "architecture-patrol",
        rationale: "due",
        job_id: "job-7",
        phase: "discovery"
      )
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "architecture-patrol",
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "acme/demo"
      },
      trigger: {
        "kind" => "finalized_scheduler",
        "id" => "reservation-1",
        "schedule" => "*/10 * * * *",
        "phase" => "discovery"
      },
      reservation: {
        "kind" => "architecture",
        "id" => "reservation-1",
        "job_id" => "job-7",
        "phase" => "discovery",
        "outcome" => { "status" => "classified" }
      },
      owner: "legacy",
      owner_epoch: 1,
      selection_input: {
        "kind" => "candidate",
        "job_id" => "job-7",
        "phase" => "discovery"
      },
      selection:
        selection,
      outcome_class: "scheduler_outcome",
      outcome: { "status" => "classified" },
      occurred_at: NOW,
      recorded_at: NOW
    )
  end
end
