require "test_helper"
require "hive/attempts/capability"
require "hive/attempts/store"
require "hive/commands/proposal"
require "hive/proposals/compiler"
require "hive/proposals/context_selector"
require "hive/proposals/evaluator_authority"
require "hive/task_activity"

class ProposalTrackingTest < Minitest::Test
  include HiveTestHelper

  FIXTURES = File.expand_path("../fixtures/proposals", __dir__).freeze
  TaskStub = Struct.new(
    :id, :slug, :folder, :project_root, :workflow, :project_name,
    keyword_init: true
  )

  def test_curated_lifecycle_flows_through_durable_sources_live_queries_and_pinned_views
    with_tmp_git_repo do |project|
      prepare_active_stores(project)
      active_before = active_store_bytes(project)
      ops = Hive::GitOps.new(project)
      ops.hive_state_init
      configure_proposals(ops)
      @config = Hive::Config.load(project)
      @attempt_store = Hive::Attempts::Store.new(
        root: tracked_tmp_dir("hive-test-proposal-attempts")
      )
      @attempt_sequence = 0
      @input_sequence = 0

      with_env("HIVE_ATTEMPT_STORE_ROOT" => @attempt_store.root) do
        accepted, accepted_evaluation = accepted_candidate(project, ops)
        assert_equal "accepted", live_store(ops).projection(accepted).status
        assert_active_stores_unchanged(project, active_before)

        rejected, rejected_attempt = rejected_candidate(project, ops)
        rejected_projection = live_store(ops).projection(rejected)
        assert_equal "rejected", rejected_projection.status
        assert_equal %w[pass fail],
                     rejected_projection.evaluations.map { |row| row.dig("result", "outcome") }
        assert_active_stores_unchanged(project, active_before)

        unevaluated = unevaluated_rejection(project, ops)
        assert_equal "no_evaluation",
                     live_store(ops).projection(unevaluated).decision.fetch("rationale_category")
        assert_active_stores_unchanged(project, active_before)

        successor = successor_and_rollback(project, ops, accepted, accepted_evaluation)
        predecessor = live_store(ops).projection(accepted)
        assert_equal "rolled_back", predecessor.status
        assert_equal "accepted", predecessor.decision.fetch("outcome")
        assert_equal successor, predecessor.superseded_by
        assert_includes live_store(ops).projection(successor).supersedes, accepted
        assert_equal "d" * 40, predecessor.rollback.dig("external_revert", "reference")
        assert_active_stores_unchanged(project, active_before)

        selection = Hive::Proposals::ContextSelector.new(
          query: Hive::Proposals::Query.new(store: live_store(ops))
        ).select(
          context: rejected_attempt, max_items: 20, max_bytes: 2_048,
          remaining_bytes: 2_048
        )
        assert_includes selection.selected_ids, rejected
        assert_includes selection.text, '"status":"rejected"'
        assert_includes selection.text, '"cost_ratio":1.42'
        refute_includes selection.text, "cost regression outweighs"
        refute_includes selection.text, "Broaden the planning prompt"
        assert_active_stores_unchanged(project, active_before)

        add_committed_malformed_neighbor(ops)
        first = File.join(tracked_tmp_dir("hive-test-proposal-compile-a"), "out")
        second = File.join(tracked_tmp_dir("hive-test-proposal-compile-b"), "out")
        source_commit = ops.hive_state_head_sha
        compiled = Hive::Proposals::Compiler.compile_at_ref(
          git_ops: ops, source_ref: source_commit, output_root: first
        )
        Hive::Proposals::Compiler.compile_at_ref(
          git_ops: ops, source_ref: source_commit, output_root: second
        )
        assert_equal File.binread(File.join(first, "wiki", "proposals.json")),
                     File.binread(File.join(second, "wiki", "proposals.json"))
        assert_equal File.binread(File.join(first, "wiki", "proposals.md")),
                     File.binread(File.join(second, "wiki", "proposals.md"))
        assert_equal 1, compiled.diagnostic_count
        statuses = compiled.index.fetch("proposals").to_h do |row|
          [ row.fetch("proposal_id"), row.fetch("status") ]
        end
        assert_equal "rolled_back", statuses.fetch(accepted)
        assert_equal "rejected", statuses.fetch(rejected)
        assert_equal "rejected", statuses.fetch(unevaluated)
        assert_equal "draft", statuses.fetch(successor)
        compiled.index.fetch("proposals").each do |row|
          live = live_store(ops).projection(row.fetch("proposal_id")).to_h
          assert_equal live, row, "compiled and live projections must have digest parity"
          assert_includes compiled.markdown, row.fetch("projection_digest") unless row["status"] == "draft"
        end
        refute_includes compiled.markdown, "Refine the accepted review prompt"
        assert_includes compiled.markdown, "Broaden the planning prompt"
        assert_includes compiled.markdown, "Rolled back"
        assert_active_stores_unchanged(project, active_before)

        show_output = StringIO.new
        Hive::Commands::Proposal.new(
          "show", rejected, input: nil, json: true, stdout: show_output,
          project_root: project
        ).call
        shown = JSON.parse(show_output.string).fetch("proposal")
        assert_equal "rejected", shown.fetch("status")
        assert_equal 2, shown.fetch("evaluations").length
        assert_includes shown.fetch("proposed_change"), "Broaden the planning prompt"
      end

      assert_equal active_before, active_store_bytes(project),
                   "tracking, compilation, and context must not mutate active stores"
    end
  end

  def test_read_only_discovery_does_not_backfill_history_and_first_typed_source_initializes_state
    with_tmp_git_repo do |project|
      ops = Hive::GitOps.new(project)
      ops.hive_state_init
      historical = File.join(
        ops.hive_state_path, "stages", "9-done", "historical-proposal-task",
        Hive::TaskJournal::JOURNAL_BASENAME
      )
      FileUtils.mkdir_p(File.dirname(historical))
      File.write(historical, "historical proposal-looking task bytes\n")
      ops.hive_commit(
        stage_name: "test", slug: "historical-proposal-task",
        action: "seeded pre-feature task history",
        pathspecs: [ "stages/9-done/historical-proposal-task/task-journal.jsonl" ]
      )
      proposal_root = File.join(ops.hive_state_path, "proposals", "v1")
      refute_path_exists proposal_root

      output = StringIO.new
      Hive::Commands::Proposal.new(
        "list", project, input: nil, json: true, stdout: output,
        project_root: project
      ).call

      assert_empty JSON.parse(output.string).fetch("proposals")
      refute_path_exists proposal_root,
                         "read-only discovery must not initialize or backfill proposal state"

      configure_proposals(ops)
      @config = Hive::Config.load(project)
      @attempt_store = Hive::Attempts::Store.new(
        root: tracked_tmp_dir("hive-test-proposal-lazy-attempts")
      )
      @attempt_sequence = 0
      @input_sequence = 0
      with_env("HIVE_ATTEMPT_STORE_ROOT" => @attempt_store.root) do
        task, = admitted_task(
          ops, slug: "first-new-proposal", subject: proposal_subject(
            kind: "skill", reference: "agent-skills/reviewer", revision: "v2"
          )
        )
        created = run_source(
          "submit", task, project,
          fixture("accepted-review-prompt", "submission.json")
        )

        assert_path_exists proposal_root
        assert_equal [ created.proposal_id ],
                     live_store(ops).load.projections.map(&:proposal_id)
      end
    end
  end

  private

  def accepted_candidate(project, ops)
    task, = admitted_task(
      ops, slug: "accepted-submit", subject: proposal_subject(
        kind: "skill", reference: "agent-skills/reviewer", revision: "v2"
      )
    )
    submitted = run_source(
      "submit", task, project,
      fixture("accepted-review-prompt", "submission.json")
    )
    proposal_id = submitted.proposal_id
    evaluation_task, = admitted_task(
      ops, slug: "accepted-evaluate", subject: proposal_subject(
        kind: "skill", reference: "agent-skills/reviewer", revision: "v2",
        proposal_id:
      ), evaluator: true
    )
    evaluated = run_source(
      "evaluate", evaluation_task, project,
      fixture("accepted-review-prompt", "evaluation.json")
    )
    evaluation_id = evaluated.ingestion.event_id
    run_lifecycle(
      "decide", proposal_id, project, ops,
      fixture("accepted-review-prompt", "decision.json"),
      considered: [ evaluation_id ]
    )
    [ proposal_id, evaluation_id ]
  end

  def rejected_candidate(project, ops)
    task, = admitted_task(
      ops, slug: "rejected-submit", subject: proposal_subject(
        kind: "workflow", reference: "workflows/coding", revision: "v4"
      )
    )
    proposal_id = run_source(
      "submit", task, project,
      fixture("rejected-planning-prompt", "submission.json")
    ).proposal_id
    evaluation_ids = []
    last_attempt = nil
    %w[evaluation-positive.json evaluation-negative.json].each_with_index do |name, index|
      evaluation_task, last_attempt = admitted_task(
        ops, slug: "rejected-evaluate-#{index + 1}", subject: proposal_subject(
          kind: "workflow", reference: "workflows/coding", revision: "v4",
          proposal_id:
        ), evaluator: true
      )
      evaluation_ids << run_source(
        "evaluate", evaluation_task, project,
        fixture("rejected-planning-prompt", name)
      ).ingestion.event_id
    end
    run_lifecycle(
      "decide", proposal_id, project, ops,
      fixture("rejected-planning-prompt", "decision.json"),
      considered: evaluation_ids
    )
    [ proposal_id, last_attempt ]
  end

  def unevaluated_rejection(project, ops)
    task, = admitted_task(
      ops, slug: "unevaluated-submit", subject: proposal_subject(
        kind: "skill", reference: "agent-skills/planner", revision: "v1"
      )
    )
    submission = JSON.parse(File.read(fixture("accepted-review-prompt", "submission.json")))
    submission["proposed_change"] = "Candidate that policy rejects before evaluation."
    submission["idempotency_key"] = "unevaluated-submission"
    proposal_id = run_source(
      "submit", task, project, write_input(project, submission)
    ).proposal_id
    decision = {
      "outcome" => "rejected", "rationale_category" => "no_evaluation",
      "rationale" => "The configured policy excludes this candidate class.",
      "links" => [], "idempotency_key" => "unevaluated-rejection"
    }
    run_lifecycle(
      "decide", proposal_id, project, ops, write_input(project, decision),
      considered: []
    )
    proposal_id
  end

  def successor_and_rollback(project, ops, predecessor_id, _evaluation_id)
    task, = admitted_task(
      ops, slug: "successor-submit", subject: proposal_subject(
        kind: "skill", reference: "agent-skills/reviewer", revision: "v3"
      )
    )
    submission = JSON.parse(File.read(fixture("accepted-review-prompt", "submission.json")))
    submission["proposed_change"] = "Refine the accepted review prompt in a distinct revision."
    submission["idempotency_key"] = "successor-submission"
    submission["lineage"] = { "requested_supersedes" => predecessor_id }
    successor_id = run_source(
      "submit", task, project, write_input(project, submission)
    ).proposal_id

    supersession = JSON.parse(File.read(fixture("superseded-rollback", "supersession.json")))
    supersession["successor_id"] = successor_id
    run_lifecycle(
      "supersede", predecessor_id, project, ops,
      write_input(project, supersession)
    )
    run_lifecycle(
      "rollback", predecessor_id, project, ops,
      fixture("superseded-rollback", "rollback.json")
    )
    successor_id
  end

  def admitted_task(ops, slug:, subject:, evaluator: false)
    @attempt_sequence += 1
    attempt_id = "proposal-attempt-#{@attempt_sequence}"
    task_id = (50_000 + @attempt_sequence).to_s
    folder = File.join(ops.hive_state_path, "stages", "4-execute", slug)
    FileUtils.mkdir_p(folder)
    task = TaskStub.new(
      id: task_id, slug:, folder:, project_root: ops.project_root,
      workflow: "coding", project_name: "hive"
    )
    proposal_authority = Hive::Proposals::EvaluatorAuthority.new(@config)
    evaluator_binding = if evaluator
      proposal_authority.bind!(
        identity: "benchmark-reviewer", workflow: "coding",
        stage: "4-execute", agent_profile: "codex"
      )
    end
    binding = {
      "schema_version" => 1, "subject" => subject,
      "actor" => { "id" => "alice", "kind" => "proposer", "binding" => "team:proposals" },
      "evaluator" => evaluator_binding,
      "configuration_fingerprint" => proposal_authority.configuration_fingerprint,
      "policy" => @config.dig("proposals", "evidence")
    }
    attempt = @attempt_store.create_launching(
      attempt_id:, request_id: "request-#{@attempt_sequence}", predecessor_attempt_id: nil,
      task_id:, project: "hive", task_slug: slug, intended_stage: "4-execute",
      task_generation: "owner-#{@attempt_sequence}",
      ownership_generation: "owner-#{@attempt_sequence}", task_input_epoch: 1,
      progress_token: "progress-#{@attempt_sequence}", provider: "codex",
      worker_argv: [ "hive", "proposal", evaluator ? "evaluate" : "submit", slug ],
      claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
      starting_revision: ops.head_sha, retry_charge: 0, inherited_outputs: [],
      launch_timeout_sec: 300, now: Time.utc(2026, 8, 30, 12, @attempt_sequence),
      subject: Hive::Attempts::Record.task_stage_subject(
        task_id:, task_slug: slug, intended_stage: "4-execute", proposal: binding
      )
    )
    Hive::TaskActivity.new(
      task_folder: folder, task: { "id" => task_id, "slug" => slug },
      workflow: "coding", stage: "4-execute", attempt_id:,
      task_generation: 1, ownership_generation: attempt.ownership_generation,
      attempt_store: @attempt_store,
      clock: -> { Time.utc(2026, 8, 30, 12, @attempt_sequence) }
    ).record(
      kind: "attempt_admitted", operation_id: "attempt-admitted:#{attempt_id}",
      reason: "durable proposal attempt admitted", source: "attempt_dispatcher",
      payload: { "provider" => "codex", "state" => "launching" }
    )
    [ task, attempt ]
  end

  def run_source(command, task, project, source_path)
    input = copy_input(project, source_path)
    Hive::Commands::Proposal.new(
      command, task.slug, input:, stdout: StringIO.new,
      task_resolver: ->(_target, _project) { task }
    ).call
  end

  def run_lifecycle(command, proposal_id, project, ops, source_path, considered: [])
    projection = live_store(ops).projection(proposal_id)
    authority = Hive::Proposals::Authority.new(@config)
    Hive::Commands::Proposal.new(
      command, proposal_id, input: copy_input(project, source_path),
      stdout: StringIO.new, project_root: project,
      expected_head_version: projection.lifecycle_head.fetch("version"),
      expected_head_digest: projection.lifecycle_head.fetch("digest"),
      considered_evaluation_ids: considered,
      authority_identity: "proposal-operator",
      policy_fingerprint: authority.fingerprint("proposal-operator")
    ).call
  end

  def proposal_subject(kind:, reference:, revision:, proposal_id: nil)
    { "kind" => kind, "reference" => reference, "revision" => revision, "proposal_id" => proposal_id }
  end

  def live_store(ops)
    Hive::Proposals::Store.new(root: File.join(ops.hive_state_path, "proposals", "v1"))
  end

  def configure_proposals(ops)
    File.write(File.join(ops.hive_state_path, "config.yml"), <<~YAML)
      proposals:
        evaluators:
          benchmark-reviewer:
            workflows: [coding]
            stages: [4-execute]
            agent_profiles: [codex]
        authorities:
          proposal-operator:
            kind: operator
            capabilities: [decide, supersede, rollback]
            version: 1
            revoked: false
        evidence:
          visibility: project
          retention: project
          allowed_link_schemes: [https]
    YAML
    ops.hive_commit(
      stage_name: "test", slug: "proposals", action: "configured proposal actors",
      pathspecs: [ "config.yml" ]
    )
  end

  def add_committed_malformed_neighbor(ops)
    path = File.join(ops.hive_state_path, "proposals", "v1", "records", "malformed.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, File.binread(fixture("mixed-validity", "malformed.json")))
    ops.hive_commit(
      stage_name: "test", slug: "proposals", action: "seeded malformed neighbor",
      pathspecs: [ "proposals/v1/records/malformed.json" ]
    )
  end

  def prepare_active_stores(project)
    FileUtils.mkdir_p(File.join(project, "config"))
    FileUtils.mkdir_p(File.join(project, "workflows"))
    File.write(File.join(project, "config", "agent-skills.yml"), "reviewer: v1\n")
    File.write(File.join(project, "workflows", "active.yml"), "coding: v1\n")
    run!("git", "-C", project, "add", "config/agent-skills.yml", "workflows/active.yml")
    run!("git", "-C", project, "commit", "-m", "test: seed active stores", "--quiet")
  end

  def active_store_bytes(project)
    %w[config/agent-skills.yml workflows/active.yml].to_h do |path|
      [ path, File.binread(File.join(project, path)) ]
    end
  end

  def assert_active_stores_unchanged(project, expected)
    assert_equal expected, active_store_bytes(project),
                 "proposal tracking must not mutate active skill or workflow stores"
  end

  def fixture(directory, name) = File.join(FIXTURES, directory, name)

  def copy_input(project, source_path)
    @input_sequence += 1
    directory = File.join(project, "proposal-test-inputs")
    FileUtils.mkdir_p(directory)
    destination = File.join(directory, format("%03d-%s", @input_sequence, File.basename(source_path)))
    FileUtils.cp(source_path, destination)
    destination
  end

  def write_input(project, payload)
    @input_sequence += 1
    directory = File.join(project, "proposal-test-inputs")
    FileUtils.mkdir_p(directory)
    path = File.join(directory, format("%03d-dynamic.json", @input_sequence))
    File.write(path, JSON.generate(payload))
    path
  end
end
