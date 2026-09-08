require "test_helper"
require "hive/proposals/producer"

class ProposalProducerTest < Minitest::Test
  include HiveTestHelper

  FakeAttempt = Struct.new(:proposal_binding, :provider) do
    def [](key) = key.to_s == "provider" ? provider : nil
  end

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
      unrelated = "stages/1-inbox/unrelated/prestaged.txt"
      FileUtils.mkdir_p(File.dirname(File.join(ops.hive_state_path, unrelated)))
      File.write(File.join(ops.hive_state_path, unrelated), "preserve me\n")
      run!("git", "-C", ops.hive_state_path, "add", unrelated)

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
      refute_includes source_paths, unrelated
      refute_includes canonical_paths, unrelated
      assert_equal "A  #{unrelated}", run!(
        "git", "-C", ops.hive_state_path, "status", "--porcelain=v1", "--", unrelated
      ).strip
    end
  end

  def test_failed_source_commit_after_staging_restores_files_and_the_prior_index
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      activity = activity_for(ops)
      producer = producer_for(ops, activity: activity)
      unrelated = File.join(ops.hive_state_path, "stages", "1-idea", "prior.txt")
      FileUtils.mkdir_p(File.dirname(unrelated))
      File.write(unrelated, "staged before proposal\n")
      run!("git", "-C", ops.hive_state_path, "add", "stages/1-idea/prior.txt")
      leftover_log = File.join(ops.hive_state_path, "logs", "leftover.log")
      File.write(leftover_log, "unrelated log\n")
      original_commit = ops.method(:hive_commit)
      ops.define_singleton_method(:hive_commit) do |**options|
        original_commit.call(
          **options.merge(after_stage: -> { raise Hive::GitError, "simulated source commit failure" })
        )
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
      assert_equal [ "A  stages/1-idea/prior.txt", "?? logs/leftover.log" ].sort,
                   run!("git", "-C", ops.hive_state_path, "status", "--porcelain=v1")
                     .lines.map(&:chomp).sort
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
      binding = Marshal.load(Marshal.dump(proposal_binding))
      binding.dig("subject")["reference"] = "agent-skills/hash-bound-reviewer"
      producer = Hive::Proposals::Producer.new(
        project_root: ops.project_root, git_ops: ops, activity: activity_for(ops),
        attempt: { "subject" => { "proposal" => binding } },
        proposal_id_generator: -> { proposal_id }
      )

      result = producer.submit(
        proposed_change: "Use durable binding", motivation: "Reject caller spoofing",
        evidence: [ evidence ], source_event_id: "pse-#{'9' * 64}"
      )
      store = Hive::Proposals::Store.new(
        root: File.join(ops.hive_state_path, "proposals", "v1")
      )

      assert_equal proposal_id, result.proposal_id
      assert_equal "agent-skills/hash-bound-reviewer",
                   store.projection(proposal_id).subject.fetch("reference")
    end
  end

  def test_rejects_an_unsafe_task_journal_before_appending_activity
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      activity = activity_for(ops)
      outside = File.join(dir, "outside-journal.jsonl")
      File.write(outside, "outside\n")
      File.symlink(outside, File.join(activity.task_folder, "task-journal.jsonl"))
      producer = producer_for(ops, activity:)

      assert_raises(Hive::Proposals::Error) do
        producer.submit(
          proposed_change: "Change review", motivation: "Improve recall",
          evidence: [ evidence ], source_event_id: "pse-#{'8' * 64}"
        )
      end
      assert_equal "outside\n", File.read(outside)
      assert File.symlink?(File.join(activity.task_folder, "task-journal.jsonl"))
    end
  end

  def test_revoked_evaluator_cannot_admit_new_events_but_committed_exact_retry_survives
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      config = Hive::Config.merge_defaults(
        "proposals" => {
          "evaluators" => {
            "benchmark-reviewer" => {
              "workflows" => [ "coding" ], "stages" => [ "4-execute" ],
              "agent_profiles" => [ "codex" ]
            }
          }
        }
      )
      evaluator = Hive::Proposals::EvaluatorAuthority.new(config).bind!(
        identity: "benchmark-reviewer", workflow: "coding",
        stage: "4-execute", agent_profile: "codex"
      )
      binding = Marshal.load(Marshal.dump(proposal_binding))
      binding["subject"]["proposal_id"] = proposal_id
      binding["evaluator"] = evaluator.to_h
      binding["configuration_fingerprint"] = evaluator.fetch("configuration_fingerprint")
      root = File.join(ops.hive_state_path, "proposals", "v1")
      source_store = Hive::Proposals::SourceEventStore.new(root: root)
      store = Hive::Proposals::Store.new(root: root)
      record = store.create_record!(
        proposal_id:, subject_kind: "skill", subject_ref: "agent-skills/reviewer",
        revision: "v2", proposed_change: "Change review", motivation: "Improve recall",
        evidence: [ evidence ], author: binding.fetch("actor"), lineage: {},
        provenance: {
          "task_id" => "43059", "task_generation" => 1,
          "ownership_generation" => "owner-1", "attempt_id" => "attempt-1",
          "workflow_id" => "coding", "stage" => "4-execute",
          "actor" => { "id" => "alice", "kind" => "proposer" },
          "source_commit" => "a" * 40
        },
        source_event_id: "pse-#{'e' * 64}", created_at: "2026-08-30T12:00:00Z",
        policy: binding.fetch("policy")
      )
      ops.hive_commit(
        stage_name: "proposals", slug: "fixture", action: "recorded candidate",
        pathspecs: [ "proposals/v1/records/#{record.proposal_id}.json" ]
      )
      activity = activity_for(ops)
      attempt = FakeAttempt.new(binding, "codex")
      build = lambda do |cfg|
        Hive::Proposals::Producer.new(
          project_root: dir, git_ops: ops, activity:, attempt:, config: cfg,
          source_store:, store:
        )
      end
      attributes = {
        method: { "kind" => "benchmark", "label" => "held-out" },
        result: { "outcome" => "pass", "metrics" => {} }, rationale: "Measured",
        evidence: [ evidence ], source_event_id: "pse-#{'f' * 64}"
      }
      first = build.call(config).evaluate(**attributes)
      revoked = Hive::Config.merge_defaults("proposals" => { "evaluators" => {} })

      replay = build.call(revoked).evaluate(**attributes)
      assert_equal first, replay
      assert_raises(Hive::Proposals::Unauthorized) do
        build.call(revoked).evaluate(**attributes.merge(source_event_id: "pse-#{'1' * 64}"))
      end
    end
  end

  def test_changed_evaluator_identity_fails_closed
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      binding = Marshal.load(Marshal.dump(proposal_binding))
      binding["evaluator"] = {
        "id" => "benchmark-reviewer", "fingerprint" => "d" * 64,
        "configuration_fingerprint" => "c" * 64,
        "admission" => {
          "workflows" => [ "coding" ], "stages" => [ "4-execute" ],
          "agent_profiles" => [ "codex" ]
        }
      }
      producer = Hive::Proposals::Producer.new(
        project_root: dir, git_ops: ops, activity: activity_for(ops),
        attempt: FakeAttempt.new(binding, "codex")
      )
      authority = Object.new
      authority.define_singleton_method(:bind!) { |**_attributes| { "id" => "replacement" } }
      replacement = ->(*_arguments, **_options) { authority }

      with_replaced_singleton_method(Hive::Proposals::EvaluatorAuthority, :new, replacement) do
        assert_raises(Hive::Proposals::Unauthorized) do
          producer.send(:ensure_evaluator_currently_authorized!)
        end
      end
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
