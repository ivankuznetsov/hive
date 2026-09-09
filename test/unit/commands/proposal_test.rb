require "test_helper"
require "hive/commands/proposal"

class ProposalCommandTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(:project_root, :folder, keyword_init: true)

  def test_submit_reads_a_bounded_regular_artifact_and_does_not_accept_actor_spoofing
    with_tmp_dir do |dir|
      task = FakeTask.new(project_root: dir, folder: File.join(dir, ".hive-state", "stages", "4-execute", "task"))
      FileUtils.mkdir_p(task.folder)
      input = File.join(dir, "candidate.json")
      File.write(input, JSON.generate(
        "proposed_change" => "Change review", "motivation" => "Improve recall",
        "evidence" => [ { "label" => "test", "content" => "pass", "media_type" => "text/plain" } ]
      ))
      calls = []
      result = Struct.new(:proposal_id, :source_event_id, :source_commit, :ingestion).new(
        "prp-00000000-0000-4000-8000-000000000001", "pse-#{'a' * 64}", "b" * 40,
        Struct.new(:kind, :event_id).new("record", nil)
      )
      producer = Object.new
      producer.define_singleton_method(:submit) { |**attributes| calls << attributes; result }
      output = StringIO.new

      Hive::Commands::Proposal.new(
        "submit", "task", input: input, json: true, stdout: output,
        task_resolver: ->(_target, _project) { task },
        producer_factory: ->(_task) { producer }, reconciler: ->(_task) { }
      ).call

      assert_equal 1, calls.length
      assert_equal "candidate.json", calls.first.dig(:artifact, "reference")
      assert_equal Digest::SHA256.file(input).hexdigest, calls.first.dig(:artifact, "digest")
      assert_equal true, JSON.parse(output.string).fetch("ok")

      File.write(input, JSON.generate(
        "proposed_change" => "Change review", "motivation" => "Improve recall",
        "evidence" => [], "actor" => "mallory"
      ))
      error = assert_raises(Hive::Proposals::InvalidRecord) do
        Hive::Commands::Proposal.new(
          "submit", "task", input: input,
          task_resolver: ->(_target, _project) { task },
          producer_factory: ->(_task) { producer }, reconciler: ->(_task) { }
        ).call
      end
      assert_match(/unknown fields: actor/, error.message)
    end
  end

  def test_rejects_symlinked_oversize_and_missing_source_artifacts_before_production
    with_tmp_dir do |dir|
      task = FakeTask.new(project_root: dir, folder: dir)
      real = File.join(dir, "real.json")
      link = File.join(dir, "link.json")
      File.write(real, "{}")
      File.symlink(real, link)
      factory = ->(_task) { flunk "producer must not be constructed" }

      error = assert_raises(Hive::Proposals::InvalidRecord) do
        Hive::Commands::Proposal.new(
          "submit", "task", input: link,
          task_resolver: ->(_target, _project) { task }, producer_factory: factory,
          reconciler: ->(_task) { }
        ).call
      end
      assert_match(/regular non-symlink/, error.message)

      File.write(real, "x" * (Hive::Commands::Proposal::MAX_INPUT_BYTES + 1))
      assert_match(/exceeds/, assert_raises(Hive::Proposals::InvalidRecord) do
        Hive::Commands::Proposal.new(
          "submit", "task", input: real,
          task_resolver: ->(_target, _project) { task }, producer_factory: factory,
          reconciler: ->(_task) { }
        ).call
      end.message)
    end
  end

  def test_refresh_compile_only_and_check_use_pinned_external_outputs
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      output = File.join(@tmpdir || Dir.tmpdir, "proposal-compiled-#{SecureRandom.hex(4)}")
      command_output = StringIO.new
      result = Hive::Commands::Proposal.new(
        "refresh", dir, input: nil, compile_only: true,
        source_ref: ops.hive_state_head_sha, output_root: output,
        json: true, stdout: command_output
      ).call

      assert_equal ops.hive_state_head_sha, result.source_commit
      assert File.file?(File.join(output, "wiki", "proposals.json"))
      assert_equal "compiled", JSON.parse(command_output.string).fetch("outcome")
      refreshed = Hive::Commands::Proposal.new(
        "refresh", dir, input: nil, stdout: StringIO.new,
        refresh_runner: lambda do |project_root, git_ops, source_ref|
          assert_equal dir, project_root
          Hive::Proposals::Compiler.compile_at_ref(
            git_ops:, source_ref:, output_root: output
          )
          publish_managed_wiki_pair(project_root, output, create: true)
        end
      ).call
      assert_equal "queued", refreshed.fetch("outcome")
      refute_path_exists File.join(dir, "wiki", "proposals.json")
      refute_path_exists File.join(dir, "wiki", "proposals.md")

      checked = Hive::Commands::Proposal.new(
        "refresh", dir, input: nil, check: true, stdout: StringIO.new
      ).call
      assert_equal ops.hive_state_head_sha, checked.source_commit

      publish_managed_wiki_pair(dir, output, stale: true)
      assert_raises(Hive::Proposals::StaleObservation) do
        Hive::Commands::Proposal.new(
          "refresh", dir, input: nil, check: true, stdout: StringIO.new
        ).call
      end
      refute Dir.children(dir).any? { |name| name.start_with?("hive-proposal-refresh-check-") }
    end
  end

  def test_decision_observations_require_uuid_v4_ids_and_result_digests
    command = Hive::Commands::Proposal.new(
      "decide", "prp-00000000-0000-4000-8000-000000000001", input: "decision.json",
      considered_evaluations: [ "pev-00000000-0000-4000-8000-000000000001" ]
    )
    error = assert_raises(Hive::Proposals::InvalidRecord) do
      command.send(:observed_evaluations)
    end
    assert_match(/EVENT_ID:RESULT_DIGEST/, error.message)

    command = Hive::Commands::Proposal.new(
      "decide", "prp-00000000-0000-4000-8000-000000000001", input: "decision.json",
      considered_evaluations: [ "pev-00000000-0000-1000-8000-000000000001:#{'a' * 64}" ]
    )
    assert_raises(Hive::Proposals::InvalidRecord) { command.send(:observed_evaluations) }

    command = Hive::Commands::Proposal.new(
      "decide", "prp-00000000-0000-4000-8000-000000000001", input: "decision.json",
      considered_evaluations: [
        "pev-00000000-0000-4000-8000-000000000001:#{'a' * 64}"
      ]
    )
    assert_equal [
      {
        "evaluation_id" => "pev-00000000-0000-4000-8000-000000000001",
        "result_digest" => "a" * 64
      }
    ], command.send(:observed_evaluations)
  end

  def test_refresh_without_check_enters_the_managed_publication_boundary
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      calls = []
      result = Hive::Commands::Proposal.new(
        "refresh", dir, input: nil, stdout: StringIO.new,
        refresh_runner: lambda do |project_root, git_ops, source_ref|
          calls << [ project_root, git_ops.hive_state_path, source_ref ]
        end
      ).call

      assert_equal "queued", result.fetch("outcome")
      assert_equal [ [ dir, ops.hive_state_path, ops.hive_state_head_sha ] ], calls
    end
  end

  def test_unknown_commands_and_json_error_envelopes_are_typed
    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Commands::Proposal.new("future", nil, input: nil).call
    end

    cases = [
      [ "list", Hive::Proposals::Unauthorized.new("unauthorized"), "hive-proposal-list", "unauthorized" ],
      [ "show", Hive::Proposals::StaleObservation.new("stale"), "hive-proposal-show", "stale" ],
      [ "decide", Hive::Proposals::Conflict.new("conflict"), "hive-proposal-mutation", "conflict" ],
      [ "decide", Hive::Proposals::QuotaExceeded.new("quota"), "hive-proposal-mutation", "quota" ],
      [ "decide", Hive::Proposals::QuarantinedSource.new("quarantine"),
        "hive-proposal-mutation", "quarantine" ],
      [ "decide", Hive::Proposals::SourceUnavailable.new("source"),
        "hive-proposal-mutation", "source_unavailable" ],
      [ "decide", Hive::ConfigError.new("config"), "hive-proposal-mutation", "config" ],
      [ "decide", Hive::Proposals::InvalidRecord.new("invalid"),
        "hive-proposal-mutation", "invalid" ]
    ]
    cases.each do |subcommand, error, schema, kind|
      output = StringIO.new
      command = Hive::Commands::Proposal.new(subcommand, nil, input: nil, json: true, stdout: output)
      command.send(:render_error, error)
      payload = JSON.parse(output.string)
      assert_equal schema, payload.fetch("schema")
      assert_equal kind, payload.fetch("error_kind")
    end
  end

  def test_mutating_commands_require_input_and_target_before_resolution
    error = assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Commands::Proposal.new("submit", "task", input: nil).call
    end
    assert_includes error.message, "--input FILE is required"

    error = assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Commands::Proposal.new("decide", nil, input: "decision.json").call
    end
    assert_includes error.message, "TARGET is required"
  end

  def test_refresh_rejects_uninitialized_and_incompatible_modes
    with_tmp_git_repo do |dir|
      uninitialized = File.join(dir, "uninitialized")
      FileUtils.mkdir_p(uninitialized)
      assert_raises(Hive::Proposals::SourceUnavailable) do
        Hive::Commands::Proposal.new("refresh", uninitialized, input: nil).call
      end

      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      assert_raises(Hive::Proposals::InvalidRecord) do
        Hive::Commands::Proposal.new("refresh", dir, input: nil, compile_only: true).call
      end
      assert_raises(Hive::Proposals::InvalidRecord) do
        Hive::Commands::Proposal.new(
          "refresh", dir, input: nil, output_root: File.join(dir, "compiled")
        ).call
      end
    end
  end

  def test_managed_refresh_requires_a_regular_runner_and_surfaces_bounded_failures
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      command = Hive::Commands::Proposal.new("refresh", dir, input: nil)
      assert_raises(Hive::Proposals::SourceUnavailable) do
        command.send(:run_managed_refresh, dir, ops)
      end

      script = File.join(dir, ".llm-wiki", "post-commit-refresh.sh")
      FileUtils.mkdir_p(File.dirname(script))
      File.write(script, "#!/usr/bin/env bash\nexit 0\n")
      assert_nil command.send(:run_managed_refresh, dir, ops)

      File.write(script, <<~SH)
        #!/usr/bin/env bash
        echo 'api_key=abcdefghijklmnopqrstuv failed' >&2
        exit 1
      SH
      error = assert_raises(Hive::Proposals::SourceUnavailable) do
        command.send(:run_managed_refresh, dir, ops)
      end
      assert_includes error.message, "managed proposal refresh failed"
      assert_includes error.message, "[REDACTED:generic_api_key]"
      refute_includes error.message, "abcdefghijklmnopqrstuv"

      File.write(script, "#!/usr/bin/env bash\nexit 1\n")
      error = assert_raises(Hive::Proposals::SourceUnavailable) do
        command.send(:run_managed_refresh, dir, ops)
      end
      assert_equal "managed proposal refresh failed", error.message
    end
  end

  def test_live_reads_and_lifecycle_options_fail_closed_without_authority_state
    with_tmp_dir do |dir|
      assert_raises(Hive::Proposals::SourceUnavailable) do
        Hive::Commands::Proposal.new("list", dir, input: nil, project_root: dir).call
      end
    end

    command = Hive::Commands::Proposal.new(
      "decide", "proposal", input: "decision.json",
      expected_head_version: "not-a-version", expected_head_digest: "d" * 64
    )
    assert_raises(Hive::Proposals::InvalidRecord) { command.send(:expected_head) }
    assert_raises(Hive::Proposals::InvalidRecord) do
      command.send(:required_option, nil, "--authority")
    end
  end

  def test_terminal_renderer_escapes_every_control_family
    command = Hive::Commands::Proposal.new("list", nil, input: nil)
    assert_equal "\\t\\n\\r\\u0001\\u007f", command.send(:terminal, "\t\n\r\u0001\u007f")
  end

  def test_artifact_reader_rejects_outside_raced_nonobject_missing_and_invalid_json
    with_tmp_dir do |outer|
      project = File.join(outer, "project")
      FileUtils.mkdir_p(project)
      command = Hive::Commands::Proposal.new("submit", "task", input: nil)
      outside = File.join(outer, "outside.json")
      File.write(outside, "{}")
      command.instance_variable_set(:@input, outside)
      assert_raises(Hive::Proposals::InvalidRecord) do
        command.send(:read_project_artifact, project)
      end

      input = File.join(project, "input.json")
      File.write(input, "{}")
      command.instance_variable_set(:@input, input)
      fake = Struct.new(:bytes) { def read(_limit) = bytes }.new("x" * (Hive::Commands::Proposal::MAX_INPUT_BYTES + 1))
      original_open = File.method(:open)
      replacement = lambda do |path, *arguments, **options, &block|
        path == input ? block.call(fake) : original_open.call(path, *arguments, **options, &block)
      end
      with_replaced_singleton_method(File, :open, replacement) do
        assert_raises(Hive::Proposals::InvalidRecord) do
          command.send(:read_project_artifact, project)
        end
      end

      File.write(input, "[]")
      assert_raises(Hive::Proposals::InvalidRecord) do
        command.send(:read_project_artifact, project)
      end
      File.unlink(input)
      assert_raises(Hive::Proposals::InvalidRecord) do
        command.send(:read_project_artifact, project)
      end
      File.write(input, "{not json")
      assert_raises(Hive::Proposals::InvalidRecord) do
        command.send(:read_project_artifact, project)
      end

      resolver = Struct.new(:resolved) { def resolve = resolved }.new(:task)
      with_replaced_singleton_method(Hive::TaskResolver, :new, ->(*_args, **_options) { resolver }) do
        assert_equal :task, command.send(:resolve_task, "task", "demo")
      end
    end
  end

  def test_live_list_show_filter_and_authority_decision_share_one_projection
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      File.write(File.join(ops.hive_state_path, "config.yml"), <<~YAML)
        proposals:
          authorities:
            proposal-operator:
              kind: operator
              capabilities: [decide, supersede, rollback]
              version: 1
              revoked: false
      YAML
      store = Hive::Proposals::Store.new(
        root: File.join(ops.hive_state_path, "proposals", "v1")
      )
      proposal_id = "prp-00000000-0000-4000-8000-000000000001"
      record = store.create_record!(
        proposal_id:, subject_kind: "workflow", subject_ref: "coding", revision: "v2",
        proposed_change: "Change planning\n# not a heading", motivation: "Improve target score",
        evidence: [ { "label" => "score", "content" => "0.9", "media_type" => "text/plain" } ],
        author: { "id" => "alice", "kind" => "proposer", "binding" => "team" },
        provenance: proposal_provenance, source_event_id: "pse-#{'1' * 64}",
        created_at: "2026-08-30T12:00:00Z"
      )
      evaluation = store.append_event!(
        proposal_id:, type: "evaluation",
        source_event_id: "pse-#{'2' * 64}", provenance: proposal_provenance,
        occurred_at: "2026-08-30T12:01:00Z",
        data: {
          "evaluator" => { "id" => "reviewer", "binding_fingerprint" => "b" * 64 },
          "method" => { "kind" => "benchmark", "label" => "cost-threshold" },
          "result" => { "outcome" => "pass", "metrics" => { "score" => 0.9 } },
          "rationale" => "Measured", "evidence" => [], "links" => []
        }
      )
      ops.hive_commit(
        stage_name: "test", slug: "proposal", action: "seeded proposal",
        pathspecs: [
          "config.yml", "proposals/v1/records/#{record.proposal_id}.json",
          store.path_for_event(evaluation).delete_prefix("#{ops.hive_state_path}/")
        ]
      )

      list_output = StringIO.new
      Hive::Commands::Proposal.new(
        "list", dir, input: nil, json: true, stdout: list_output,
        project_root: dir
      ).call
      assert_empty JSON.parse(list_output.string).fetch("proposals"), "drafts are excluded by default"

      filter_output = StringIO.new
      Hive::Commands::Proposal.new(
        "filter", dir, input: nil, json: true, stdout: filter_output,
        project_root: dir, filters: { "method" => "cost-threshold" }, include_drafts: true
      ).call
      assert_equal proposal_id,
                   JSON.parse(filter_output.string).fetch("proposals").first.fetch("proposal_id")

      config = Hive::Config.load(dir)
      authority = Hive::Proposals::Authority.new(config)
      fingerprint = authority.fingerprint("proposal-operator")
      observed = store.projection(proposal_id).lifecycle_head
      decision_path = File.join(dir, "decision.json")
      File.write(decision_path, JSON.generate(
        "outcome" => "accepted", "rationale_category" => "evaluated",
        "rationale" => "Threshold satisfied", "links" => [],
        "idempotency_key" => "accept-v2"
      ))
      mutation_output = StringIO.new
      Hive::Commands::Proposal.new(
        "decide", proposal_id, input: decision_path, json: true, stdout: mutation_output,
        project_root: dir, expected_head_version: observed.fetch("version"),
        expected_head_digest: observed.fetch("digest"),
        considered_evaluations: [
          {
            "evaluation_id" => evaluation.event_id,
            "result_digest" => Hive::Proposals.digest(evaluation.data.fetch("result"))
          }
        ],
        authority_identity: "proposal-operator", policy_fingerprint: fingerprint
      ).call
      mutation = JSON.parse(mutation_output.string)
      assert_equal "accepted", mutation.fetch("status")
      assert_equal "applied", mutation.fetch("outcome")

      show_output = StringIO.new
      Hive::Commands::Proposal.new(
        "show", proposal_id, input: nil, json: true, stdout: show_output,
        project_root: dir
      ).call
      shown = JSON.parse(show_output.string).fetch("proposal")
      assert_equal "accepted", shown.fetch("status")
      assert_equal %w[evaluation decision], shown.fetch("history").map { |row| row.fetch("type") }

      human_show = StringIO.new
      Hive::Commands::Proposal.new(
        "show", proposal_id, input: nil, stdout: human_show, project_root: dir
      ).call
      assert_includes human_show.string, '"status": "accepted"'

      File.write(File.join(store.records_root, "README.txt"), "invalid neighbor")
      query_result = Hive::Proposals::Query.new(store:).list(
        include_drafts: true, include_diagnostics: true
      )
      human_list = StringIO.new
      renderer = Hive::Commands::Proposal.new("filter", dir, input: nil, stdout: human_list)
      renderer.send(:render_list, query_result, schema: "hive-proposal-list")
      assert_includes human_list.string, proposal_id
      assert_includes human_list.string, "quarantine"

      File.write(decision_path, JSON.generate(
        "outcome" => "rejected", "rationale_category" => "evaluated",
        "rationale" => "Changed outcome", "links" => [],
        "idempotency_key" => "conflicting-v2"
      ))
      assert_raises(Hive::Proposals::Conflict) do
        Hive::Commands::Proposal.new(
          "decide", proposal_id, input: decision_path, project_root: dir,
          expected_head_version: observed.fetch("version"),
          expected_head_digest: observed.fetch("digest"),
          considered_evaluations: [
            {
              "evaluation_id" => evaluation.event_id,
              "result_digest" => Hive::Proposals.digest(evaluation.data.fetch("result"))
            }
          ],
          authority_identity: "proposal-operator", policy_fingerprint: fingerprint
        ).call
      end
    end
  end

  private

  def publish_managed_wiki_pair(project, compiled, create: false, stale: false)
    managed = File.join(Dir.tmpdir, "hive-managed-wiki-#{SecureRandom.hex(4)}")
    args = [ "worktree", "add" ]
    args.concat([ "-b", Hive::Commands::Proposal::MANAGED_WIKI_BRANCH ]) if create
    args.concat([ managed, Hive::Commands::Proposal::MANAGED_WIKI_BRANCH ]) unless create
    args.concat([ managed, "HEAD" ]) if create
    run!("git", "-C", project, *args)
    FileUtils.mkdir_p(File.join(managed, "wiki"))
    FileUtils.cp(File.join(compiled, "wiki", "proposals.json"), File.join(managed, "wiki"))
    if stale
      File.write(File.join(managed, "wiki", "proposals.md"), "stale\n")
    else
      FileUtils.cp(File.join(compiled, "wiki", "proposals.md"), File.join(managed, "wiki"))
    end
    run!("git", "-C", managed, "add", "wiki/proposals.json", "wiki/proposals.md")
    run!("git", "-C", managed, "commit", "-m", "wiki: publish proposal pair")
  ensure
    run!("git", "-C", project, "worktree", "remove", "--force", managed) if
      managed && File.directory?(managed)
  end

  def proposal_provenance
    {
      "task_id" => "43059", "task_generation" => 1,
      "ownership_generation" => "owner", "attempt_id" => "attempt",
      "workflow_id" => "coding", "stage" => "4-execute",
      "actor" => { "id" => "alice", "kind" => "configured_identity" },
      "source_commit" => "a" * 40
    }
  end
end
