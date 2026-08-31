require "test_helper"
require "hive/proposals/producer"

class ProposalProducerTest < Minitest::Test
  include HiveTestHelper

  FakeAttempt = Struct.new(:proposal_binding)

  class FakeActivity
    attr_reader :task_folder, :binding, :records

    def initialize(task_folder:, binding:)
      @task_folder = task_folder
      @binding = binding
      @records = {}
    end

    def record(**attributes)
      operation_id = attributes.fetch(:operation_id)
      existing = @records[operation_id]
      return existing if existing

      @records[operation_id] = attributes
      File.open(File.join(task_folder, "task-journal.jsonl"), "ab") do |file|
        file.write("#{JSON.generate(attributes.fetch(:payload))}\n")
      end
      attributes
    end
  end

  def test_commits_the_receipt_before_canonical_ingestion_and_replays_exactly_once
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      activity = activity_for(ops)
      producer = producer_for(ops, activity: activity)

      result = producer.submit(
        proposed_change: "Use a stricter review prompt", motivation: "Improve recall",
        evidence: [ evidence ], source_event_id: "pse-#{'a' * 64}"
      )
      replay = producer.submit(
        proposed_change: "Use a stricter review prompt", motivation: "Improve recall",
        evidence: [ evidence ], source_event_id: "pse-#{'a' * 64}"
      )

      assert_equal result, replay
      assert_equal proposal_id, result.proposal_id
      assert_equal "record", result.ingestion.kind
      assert_equal proposal_id, result.to_h.fetch("proposal_id")
      assert_equal 1, activity.records.length

      log = run!("git", "-C", ops.hive_state_path, "log", "--format=%H%x09%s")
      source_line = log.lines.find { |line| line.include?("admitted proposal source") }
      canonical_line = log.lines.find { |line| line.include?("ingested proposal source") }
      refute_nil source_line
      refute_nil canonical_line
      source_commit = source_line.split("\t", 2).first
      canonical_commit = canonical_line.split("\t", 2).first
      source_paths = changed_paths(ops, source_commit)
      canonical_paths = changed_paths(ops, canonical_commit)
      assert_includes source_paths, "proposals/v1/inbox/pse-#{'a' * 64}.json"
      assert_includes source_paths, "stages/4-execute/proposal-task/task-journal.jsonl"
      assert_includes canonical_paths, "proposals/v1/records/#{proposal_id}.json"
      refute_includes source_paths, "proposals/v1/records/#{proposal_id}.json"
    end
  end

  def test_failed_source_commit_restores_task_and_inbox_files
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      activity = activity_for(ops)
      producer = producer_for(ops, activity: activity)
      ops.define_singleton_method(:hive_commit) do |**options|
        options.fetch(:before_stage).call
        raise Hive::GitError, "simulated source commit failure"
      end
      ops.define_singleton_method(:run_git!) do |*_arguments|
        raise Hive::GitError, "simulated reset failure"
      end

      assert_raises(Hive::GitError) do
        producer.submit(
          proposed_change: "Change review", motivation: "Improve recall",
          evidence: [ evidence ], source_event_id: "pse-#{'b' * 64}"
        )
      end

      refute File.exist?(File.join(activity.task_folder, "task-journal.jsonl"))
      refute File.exist?(File.join(ops.hive_state_path, "proposals", "v1", "inbox", "index.json"))
      refute File.exist?(
        File.join(ops.hive_state_path, "proposals", "v1", "inbox", "pse-#{'b' * 64}.json")
      )
    end
  end

  def test_requires_the_committed_receipt_to_match_before_ingestion
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      activity = activity_for(ops)
      producer = producer_for(ops, activity: activity)
      ops.define_singleton_method(:hive_state_commit_for_path) { |_path| nil }

      assert_raises(Hive::Proposals::SourceUnavailable) do
        producer.submit(
          proposed_change: "Change review", motivation: "Improve recall",
          evidence: [ evidence ], source_event_id: "pse-#{'c' * 64}"
        )
      end
    end
  end

  def test_accepts_the_durable_binding_from_a_hash_backed_attempt
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      producer = Hive::Proposals::Producer.new(
        project_root: ops.project_root, git_ops: ops, activity: activity_for(ops),
        attempt: { "subject" => { "proposal" => proposal_binding } },
        proposal_id_generator: -> { proposal_id }
      )

      assert_instance_of Hive::Proposals::Producer, producer
    end
  end

  private

  def producer_for(ops, activity:)
    Hive::Proposals::Producer.new(
      project_root: ops.project_root, git_ops: ops, activity: activity,
      attempt: FakeAttempt.new(proposal_binding),
      proposal_id_generator: -> { proposal_id }
    )
  end

  def activity_for(ops)
    folder = File.join(ops.hive_state_path, "stages", "4-execute", "proposal-task")
    FileUtils.mkdir_p(folder)
    FakeActivity.new(
      task_folder: folder,
      binding: {
        "task" => { "id" => "43059", "slug" => "proposal-task" },
        "workflow" => "coding", "stage" => "4-execute", "attempt_id" => "attempt-1",
        "task_generation" => 1, "ownership_generation" => "owner-1",
        "commit_generation" => 0
      }
    )
  end

  def proposal_binding
    {
      "schema_version" => 1,
      "subject" => {
        "kind" => "skill", "reference" => "agent-skills/reviewer",
        "revision" => "v2", "proposal_id" => nil
      },
      "actor" => { "id" => "alice", "kind" => "proposer", "binding" => "team:skills" },
      "evaluator" => nil, "configuration_fingerprint" => "c" * 64,
      "policy" => {
        "visibility" => "project", "retention" => "project",
        "allowed_link_schemes" => [ "https" ]
      }
    }
  end

  def evidence
    { "label" => "benchmark", "content" => "score=0.91", "media_type" => "text/plain" }
  end

  def proposal_id = "prp-00000000-0000-4000-8000-000000000001"

  def changed_paths(ops, commit)
    run!(
      "git", "-C", ops.hive_state_path, "diff-tree", "--no-commit-id", "--name-only", "-r", commit
    ).lines.map(&:strip)
  end
end
