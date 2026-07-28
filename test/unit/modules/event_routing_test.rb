require "test_helper"
require "hive/modules/event_publisher"
require "hive/modules/event_router"

class ModulesEventRoutingTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 22, 10)
  Stage = Data.define(:dir)
  Workflow = Data.define(:id, :stages)
  Task = Data.define(:project_name, :project_root, :id, :slug, :workflow, :state_file)

  class RecordingLedger
    attr_reader :records

    def initialize
      @records = []
    end

    def record(**attributes)
      append(prepare(**attributes))
    end

    def prepare(**attributes)
      attributes.transform_keys(&:to_s).merge(
        "event_id" => "evt-#{'a' * 64}", "payload" => attributes.fetch(:payload)
      )
    end

    def append(event)
      @records << event.each_with_object({}) do |(key, value), record|
        record[key.to_sym] = value unless key == "event_id"
      end
      Hive::Modules::EventResult.new(status: :created, event: event)
    end
  end

  def test_router_persists_each_supported_occurrence_before_dispatch
    ledger = RecordingLedger.new
    dispatched = []
    dispatcher = Object.new
    dispatcher.define_singleton_method(:dispatch_event) do |event|
      dispatched << event
      [ { "outcome" => "skip" } ]
    end
    router = Hive::Modules::EventRouter.new(
      ledger: ledger, dispatcher: dispatcher, project_id: "project-1", project: "demo",
      clock: -> { NOW }
    )

    task = router.task_completed(
      task_id: "task-1", task_generation: "generation-1", occurred_at: NOW
    )
    merged = router.pull_request_merged(
      repository: "owner/repo", number: 7, merge_commit: "b" * 40,
      manifest_digest: "c" * 64, occurred_at: NOW.iso8601
    )
    registered = router.project_registered(registration_id: "registration-1", occurred_at: NOW)
    scheduled = router.schedule(
      schedule: "0 * * * *", due_at: NOW.iso8601, missed_windows: 2
    )

    assert_equal 4, ledger.records.size
    assert_equal 4, dispatched.size
    assert_equal "task.completed", task.fetch(:occurrence).event.fetch("event_name")
    assert_equal "pull_request.merged", merged.fetch(:occurrence).event.fetch("event_name")
    assert_equal "project.registered", registered.fetch(:occurrence).event.fetch("event_name")
    assert_equal 2, scheduled.fetch(:occurrence).event.dig("payload", "missed_windows")
    assert_equal "2026-07-22T10:00:00.000000Z", scheduled.fetch(:occurrence).event.fetch("occurred_at")

    assert_raises(Hive::ConfigError) do
      router.schedule(schedule: "0 * * * *", due_at: "not-a-time")
    end
  end

  def test_publisher_validates_merged_manifest_and_project_identity
    ledger = RecordingLedger.new
    publisher = Hive::Modules::EventPublisher.new(
      ledger_factory: ->(_entry) { ledger }, clock: -> { NOW }
    )
    entry = { "name" => "demo", "project_id" => "project-1", "hive_state_path" => "/state" }
    manifest = Hive::RefactorPatrol::PrManifest.build(
      source: {
        "url" => "https://github.com/owner/repo/pull/7", "number" => 7,
        "repository" => "owner/repo", "registration" => "demo",
        "base_branch" => "main", "base_sha" => "a" * 40, "merge_sha" => "b" * 40,
        "merged_at" => NOW.iso8601
      },
      files: [ { "path" => "lib/demo.rb", "status" => "modified" } ]
    )

    publisher.pull_request_merged(entry, manifest)
    record = ledger.records.fetch(0)
    assert_equal "pull_request.merged", record.fetch(:event_name)
    assert_equal "owner/repo#7", record.dig(:source, "id")
    assert_equal manifest.fetch("manifest_checksum"), record.dig(:payload, "manifest_digest")
    assert_equal(
      {
        "decision" => {
          "rationale" => "due",
          "job_id" => manifest.fetch("job_id"),
          "phase" => "discovery"
        },
        "effects" => [
          { "kind" => "job", "id" => manifest.fetch("job_id") }
        ]
      },
      record.dig(:payload, "legacy_enqueue_provenance"),
      "the merge event records immutable enqueue provenance, not a later scheduler outcome"
    )
    assert_equal(
      "pull-request:owner/repo:7:#{'b' * 40}",
      record.fetch(:idempotency_key)
    )

    without_identity = { "name" => "demo", "path" => File.expand_path("/project") }
    with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [ without_identity ] }) do
      assert_raises(Hive::ConfigError) do
        publisher.send(:project_entry, "demo", "/project")
      end
    end
    with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [] }) do
      assert_raises(Hive::ConfigError) do
        publisher.send(:project_entry, "demo", "/project")
      end
    end
  end

  def test_publisher_links_exact_patrol_captures_to_targeted_schedule_events
    ledger = RecordingLedger.new
    publisher = Hive::Modules::EventPublisher.new(
      ledger_factory: ->(_entry) { ledger }, clock: -> { NOW }
    )
    entry = {
      "name" => "demo",
      "project_id" => "project-1",
      "hive_state_path" => "/state"
    }
    ordinary = capture("patrol", decision: { "rationale" => "due" })
    architecture = capture(
      "architecture-patrol",
      decision: {
        "rationale" => "not_due",
        "job_id" => nil,
        "phase" => nil
      }
    )

    publisher.patrol_reserved(entry, ordinary, schedule: "*/10 * * * *")
    publisher.architecture_patrol_finalized(
      entry,
      architecture,
      schedule: "*/10 * * * *",
      target_hook: "scheduled-discovery"
    )

    patrol = ledger.records.fetch(0)
    assert_equal ordinary.to_h,
                 patrol.dig(:payload, "legacy_mutator_capture")
    assert_equal "patrol", patrol.dig(:payload, "target_module")
    architecture_record = ledger.records.fetch(1)
    assert_equal architecture.to_h,
                 architecture_record.dig(:payload, "legacy_mutator_capture")
    assert_equal "architecture-patrol",
                 architecture_record.dig(:payload, "target_module")
    assert_equal "scheduled-discovery",
                 architecture_record.dig(:payload, "target_hook")

    assert_raises(Hive::ConfigError) do
      publisher.prepare_patrol_finalized(
        entry, architecture, schedule: "*/10 * * * *"
      )
    end
    assert_raises(Hive::ConfigError) do
      publisher.prepare_architecture_patrol_finalized(
        entry.merge("name" => "other"),
        architecture,
        schedule: "*/10 * * * *",
        target_hook: "scheduled-discovery"
      )
    end
  end

  def test_publisher_persists_registration_with_default_ledger_factory
    with_tmp_dir do |root|
      entry = {
        "name" => "demo", "path" => root, "project_id" => "project-1",
        "hive_state_path" => File.join(root, ".hive-state"),
        "registered_at" => NOW.iso8601(6), "registration_id" => "registration-1"
      }
      result = Hive::Modules::EventPublisher.new(clock: -> { NOW }).project_registered(entry)
      ledger = Hive::Modules::EventLedger.new(
        root: File.join(entry.fetch("hive_state_path"), "module-runtime")
      )

      assert_equal :created, result.status
      event = ledger.all.fetch(0)
      assert_equal "project.registered", event.fetch("event_name")
      assert_equal "registration-1", event.dig("source", "id")
    end
  end

  def test_publisher_derives_task_completion_from_registered_project_and_terminal_workflow
    with_tmp_dir do |root|
      ledger = RecordingLedger.new
      entry = {
        "name" => "demo", "path" => File.expand_path(root),
        "project_id" => "project-1", "hive_state_path" => File.join(root, ".hive-state")
      }
      task = Task.new(
        project_name: "demo", project_root: root, id: 7, slug: "task-7",
        workflow: Workflow.new(id: :coding, stages: [ Stage.new(dir: "8-finalize") ]),
        state_file: File.join(root, "task.md")
      )
      File.write(task.state_file, "# Task\n")
      publisher = Hive::Modules::EventPublisher.new(
        ledger_factory: ->(_entry) { ledger }, clock: -> { NOW }
      )
      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [ entry ] }) do
        with_replaced_singleton_method(
          Hive::Attempts::Generation, :artifact_token, ->(_task) { "generation-7" }
        ) do
          publisher.task_completed(task)
        end
      end

      record = ledger.records.fetch(0)
      assert_equal "task.completed", record.fetch(:event_name)
      assert_equal "task:7:generation-7:completed", record.fetch(:idempotency_key)
      assert_equal "coding", record.dig(:payload, "workflow")
      assert_equal "8-finalize", record.dig(:payload, "terminal_stage")
    end
  end

  private

  def capture(module_name, decision:)
    identity = "#{module_name}-reservation"
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: module_name,
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: { "kind" => "schedule", "id" => identity },
      reservation: {
        "kind" => module_name == "patrol" ? "ordinary" : "architecture",
        "id" => identity
      },
      owner: "legacy",
      owner_epoch: 1,
      decision_class: "scheduler_outcome",
      decision: decision,
      occurred_at: NOW,
      recorded_at: NOW
    )
  end
end
