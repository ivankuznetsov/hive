require "test_helper"
require "hive/attempts/dispatcher"
require "hive/attempts/entrypoint"
require "hive/attempts/repository"
require "hive/commands/proposal"
require "hive/proposals/compiler"
require "hive/proposals/context_selector"

class ProposalTrackingTest < Minitest::Test
  include HiveTestHelper

  FIXTURES = File.expand_path("../fixtures/proposals", __dir__).freeze
  PROPOSAL_SOURCES = [
    File.expand_path("../../lib/hive/proposals.rb", __dir__),
    *Dir[File.expand_path("../../lib/hive/proposals/**/*.rb", __dir__)]
  ].freeze
  ACTIVE_STORE_DEPENDENCIES = %w[
    Hive::AgentSkills
    Hive::Commands::Workflow
    Hive::WorkflowPackage
    Hive::Workflows::Bench
    hive/agent_skills/
    hive/commands/workflow
    hive/workflow_package/
  ].freeze

  class AdmissionLauncher
    def preflight! = true

    def launch(_record, claim_capability:) = { "claimed" => !claim_capability.empty? }
  end

  def test_proposal_subsystem_cannot_depend_on_active_skill_or_workflow_store_mutators
    violations = PROPOSAL_SOURCES.flat_map do |path|
      source = File.read(path)
      ACTIVE_STORE_DEPENDENCIES.filter_map do |dependency|
        "#{path.delete_prefix("#{ROOT}/")}: #{dependency}" if source.include?(dependency)
      end
    end

    assert_empty violations,
                 "proposal tracking must not depend on active skill or workflow store mutators"
  end

  def test_curated_lifecycle_flows_through_durable_sources_live_queries_and_pinned_views
    with_tmp_git_repo do |project|
      ops = Hive::GitOps.new(project)
      ops.hive_state_init
      configure_proposals(ops)
      @config = Hive::Config.load(project)
      state_home = tracked_tmp_dir("hive-test-proposal-attempts")
      @attempt_store = Hive::Attempts::Repository.new(root: state_home, migrate: true)
      register_runtime_project(
        database: @attempt_store.database, name: File.basename(project), path: project,
        state_root_path: ops.hive_state_path
      )
      @attempt_sequence = 0
      @input_sequence = 0

      with_env("HIVE_HOME" => state_home) do
        accepted, accepted_evaluation = accepted_candidate(project, ops)
        assert_equal "accepted", live_store(ops).projection(accepted).status

        rejected, rejected_attempt = rejected_candidate(project, ops)
        rejected_projection = live_store(ops).projection(rejected)
        assert_equal "rejected", rejected_projection.status
        assert_equal %w[pass fail],
                     rejected_projection.evaluations.map { |row| row.dig("result", "outcome") }

        unevaluated = unevaluated_rejection(project, ops)
        assert_equal "no_evaluation",
                     live_store(ops).projection(unevaluated).decision.fetch("rationale_category")

        successor = successor_and_rollback(project, ops, accepted, accepted_evaluation)
        predecessor = live_store(ops).projection(accepted)
        assert_equal "rolled_back", predecessor.status
        assert_equal "accepted", predecessor.decision.fetch("outcome")
        assert_equal successor, predecessor.superseded_by
        assert_includes live_store(ops).projection(successor).supersedes, accepted
        assert_equal "d" * 40, predecessor.rollback.dig("external_revert", "reference")

        selection = Hive::Proposals::ContextSelector.new(
          query: Hive::Proposals::Query.new(store: live_store(ops))
        ).select(
          context: rejected_attempt, max_items: 20, max_bytes: 2_048,
          remaining_bytes: 2_048
        )
        assert_includes selection.selected_ids, rejected
        assert_includes selection.text, '"status":"rejected"'
        assert_includes selection.text, '"method_kind":"benchmark"'
        refute_includes selection.text, "cost_ratio"
        refute_includes selection.text, "cost regression outweighs"
        refute_includes selection.text, "Broaden the planning prompt"

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
      state_home = tracked_tmp_dir("hive-test-proposal-lazy-attempts")
      @attempt_store = Hive::Attempts::Repository.new(root: state_home, migrate: true)
      register_runtime_project(
        database: @attempt_store.database, name: File.basename(project), path: project,
        state_root_path: ops.hive_state_path
      )
      @attempt_sequence = 0
      @input_sequence = 0
      with_env("HIVE_HOME" => state_home) do
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

        # A later command on the same task runs outside that (now idle)
        # attempt: it must admit a fresh source attempt for its own typed
        # options instead of reusing the earlier subject in-process.
        dispatches = []
        attempts = Object.new
        attempts.define_singleton_method(:dispatch) do |**attributes|
          dispatches << attributes
          Hive::Attempts::ClientResult.new(
            status: :terminal, exit_status: 0, outcome: "success",
            receipt: nil, attempt_id: "fresh-source-attempt"
          )
        end
        Hive::Commands::Proposal.new(
          "submit", task.slug,
          input: copy_input(project, fixture("rejected-planning-prompt", "submission.json")),
          stdout: StringIO.new, task_resolver: ->(_target, _project) { task },
          attempts_api: attempts,
          filters: { "kind" => "workflow", "subject" => "workflows/coding", "revision" => "v9" }
        ).call

        assert_equal 1, dispatches.length
        assert_equal(
          { "kind" => "workflow", "reference" => "workflows/coding", "revision" => "v9",
            "proposal_id" => nil },
          dispatches.first.dig(:proposal_admission, "subject")
        )
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
    Hive::TaskMeta.write(
      folder, id: task_id, slug:, display_name: nil, workflow: "coding"
    )
    File.write(File.join(folder, "task.md"), "# #{slug}\n")
    task = Hive::Task.new(folder)
    now = Time.utc(2026, 8, 30, 12, @attempt_sequence)
    dispatcher = Hive::Attempts::Dispatcher.new(
      store: @attempt_store, launcher: AdmissionLauncher.new,
      limits: { max_global: 100, max_per_project: 100, max_daily: 100 },
      clock: -> { now }, id_generator: -> { attempt_id },
      capability_generator: -> { "c" * 64 }
    )
    result = Hive::Attempts::Entrypoint.new(
      store: @attempt_store, dispatcher:, config_loader: ->(_root) { @config }
    ).dispatch(
      task:, intended_stage: "4-execute",
      argv: [ "hive", "proposal", evaluator ? "evaluate" : "submit", slug ],
      request_id: "request-#{@attempt_sequence}", provider: "codex",
      interactive: false, now:,
      proposal_admission: {
        "subject" => subject,
        "actor" => {
          "id" => "alice", "kind" => "proposer", "binding" => "team:proposals"
        },
        "evaluator_identity" => evaluator ? "benchmark-reviewer" : nil,
        "agent_profile" => "codex"
      }
    )
    assert_equal :accepted, result.status
    (@admitted_attempts ||= {})[task.folder] = result.attempt
    [ task, result.attempt ]
  end

  # Runs the source command as the admitted attempt's authenticated worker.
  def run_source(command, task, project, source_path)
    input = copy_input(project, source_path)
    attempt = @admitted_attempts.fetch(task.folder)
    with_attempt_context(
      attempt_id: attempt.attempt_id, task_generation: attempt.task_input_epoch,
      ownership_generation: attempt.ownership_generation
    ) do
      Hive::Commands::Proposal.new(
        command, task.slug, input:, stdout: StringIO.new,
        task_resolver: ->(_target, _project) { task }
      ).call
    end
  end

  def run_lifecycle(command, proposal_id, project, ops, source_path, considered: [])
    projection = live_store(ops).projection(proposal_id)
    authority = Hive::Proposals::Authority.new(@config)
    Hive::Commands::Proposal.new(
      command, proposal_id, input: copy_input(project, source_path),
      stdout: StringIO.new, project_root: project,
      expected_head_version: projection.lifecycle_head.fetch("version"),
      expected_head_digest: projection.lifecycle_head.fetch("digest"),
      considered_evaluations: considered.map do |evaluation_id|
        evaluation = projection.evaluations.find { |row| row.fetch("event_id") == evaluation_id }
        {
          "evaluation_id" => evaluation_id,
          "result_digest" => Hive::Proposals.digest(evaluation.fetch("result"))
        }
      end,
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
