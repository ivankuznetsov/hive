require "test_helper"
require "hive/modules/event_publisher"

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

  def test_post_merge_events_have_batch_identity_and_bounded_provenance_projection
    ledger = RecordingLedger.new
    publisher = Hive::Modules::EventPublisher.new(
      ledger_factory: ->(_entry) { ledger }, clock: -> { NOW }
    )
    entry = { "name" => "demo", "project_id" => "project-1", "hive_state_path" => "/state" }
    source = {
      "url" => "https://github.com/owner/repo/pull/7", "number" => 7,
      "repository" => "owner/repo", "registration" => "demo",
      "base_branch" => "main", "base_sha" => "a" * 40, "merge_sha" => "b" * 40,
      "merged_at" => NOW.iso8601
    }
    classification = {
      "occurrence_id" => "c" * 64, "snapshot_digest" => "d" * 64,
      "changed_paths_digest" => "e" * 64, "decision" => "feature",
      "reason" => "llm", "rationale" => "Feature", "evidence" => [ "behavior" ],
      "model_receipt" => "fake:model", "attempts" => 1,
      "classified_at" => NOW.iso8601,
      "prefilter" => { "decision" => "ambiguous", "reason" => "no_match", "evidence" => [] }
    }
    provenance = {
      "merges" => [ {
        "repository" => "owner/repo", "number" => 7, "merge_sha" => "b" * 40,
        "merged_at" => NOW.iso8601, "classification_occurrence_id" => "c" * 64,
        "path_mappings" => [ { "path" => "lib/demo.rb", "slice_ids" => [ "slice-demo" ] } ]
      } ]
    }
    manifests = %w[first second].map do |identity|
      Hive::RefactorPatrol::PrManifest.build(
        source: source,
        files: [ { "path" => "lib/demo.rb", "status" => "modified", "patch" => "@@" } ],
        lane: "post_merge", classification: classification, provenance: provenance,
        identity: identity
      )
    end

    manifests.each { |manifest| publisher.pull_request_merged(entry, manifest) }

    first, second = ledger.records
    refute_equal first.fetch(:idempotency_key), second.fetch(:idempotency_key)
    assert first.fetch(:idempotency_key).end_with?(manifests.first.fetch("job_id"))
    assert_equal "post_merge", first.dig(:payload, "post_merge", "lane")
    assert_equal 1, first.dig(:payload, "post_merge", "path_count")
    assert_equal "c" * 64,
                 first.dig(:payload, "post_merge", "merges", 0, "classification_occurrence_id")
    assert_equal Hive::RefactorPatrol::PrManifest.checksum(provenance),
                 first.dig(:payload, "post_merge", "provenance_digest")
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
end
