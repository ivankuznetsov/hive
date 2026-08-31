require "test_helper"
require "json_schemer"
require "hive/git_ops"
require "hive/proposals/compiler"

class ProposalCompilerTest < Minitest::Test
  include HiveTestHelper

  def setup
    @tmp = Dir.mktmpdir("proposal-compiler")
    @counter = 0
    @store = Hive::Proposals::Store.new(
      root: File.join(@tmp, "proposals", "v1"),
      id_generator: -> { @counter += 1; format("00000000-0000-4000-8000-%012d", @counter) }
    )
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_compilation_is_byte_stable_isolates_invalid_files_and_omits_drafts_from_markdown
    create_record(draft_id, change: "draft only")
    create_record(rejected_id, change: "Reject # heading <script>alert(1)</script>")
    reject_without_evaluation(rejected_id)
    FileUtils.mkdir_p(@store.records_root)
    File.write(File.join(@store.records_root, "malformed.json"), "{not json")
    first = File.join(@tmp, "first")
    second = File.join(@tmp, "second")
    compiler = Hive::Proposals::Compiler.new(store: @store)

    result = compiler.compile(output_root: first, source_commit: "a" * 40)
    compiler.compile(output_root: second, source_commit: "a" * 40)

    assert_equal File.binread(File.join(first, "wiki", "proposals.json")),
                 File.binread(File.join(second, "wiki", "proposals.json"))
    assert_equal File.binread(File.join(first, "wiki", "proposals.md")),
                 File.binread(File.join(second, "wiki", "proposals.md"))
    assert_equal 2, result.projection_count
    assert_equal 1, result.diagnostic_count
    assert_equal %w[draft rejected], result.index.fetch("proposals").map { |row| row.fetch("status") }
    refute_includes result.markdown, "draft only"
    assert_includes result.markdown, "Rejected"
    refute_includes result.markdown, "<script>"
    refute_match(/^# heading/m, result.markdown)

    schema = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-proposal-index")))
    )
    assert_empty schema.validate(result.index).to_a
  end

  def test_pinned_compilation_does_not_leak_later_state
    with_tmp_git_repo do |project|
      ops = Hive::GitOps.new(project)
      ops.hive_state_init
      store = Hive::Proposals::Store.new(
        root: File.join(ops.hive_state_path, "proposals", "v1")
      )
      create_record(draft_id, store:)
      ops.hive_commit(
        stage_name: "proposals", slug: "fixture", action: "recorded candidate",
        pathspecs: [ "proposals/v1/records/#{draft_id}.json" ]
      )
      pinned = ops.hive_state_head_sha
      create_record(rejected_id, store:)
      ops.hive_commit(
        stage_name: "proposals", slug: "fixture", action: "recorded later candidate",
        pathspecs: [ "proposals/v1/records/#{rejected_id}.json" ]
      )

      result = Hive::Proposals::Compiler.compile_at_ref(
        git_ops: ops, source_ref: pinned, output_root: File.join(project, "compiled")
      )

      assert_equal pinned, result.source_commit
      assert_equal [ draft_id ], result.index.fetch("proposals").map { |row| row.fetch("proposal_id") }
    end
  end

  def test_rejects_unavailable_pins_and_output_roots_that_cannot_contain_the_pair
    compiler = Hive::Proposals::Compiler.new(store: @store)
    assert_raises(Hive::Proposals::Error) do
      compiler.send(:write_pair, "/", json: "{}", markdown: "# Proposals\n")
    end

    with_tmp_git_repo do |project|
      ops = Hive::GitOps.new(project)
      ops.hive_state_init
      assert_raises(Hive::Proposals::Error) do
        Hive::Proposals::Compiler.compile_at_ref(
          git_ops: ops, source_ref: "missing-ref", output_root: File.join(project, "compiled")
        )
      end
    end
  end

  def test_pinned_compilation_materializes_symlinks_for_logical_quarantine
    with_tmp_git_repo do |project|
      ops = Hive::GitOps.new(project)
      ops.hive_state_init
      relative = "proposals/v1/records/#{draft_id}.json"
      path = File.join(ops.hive_state_path, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(File.join(File.dirname(path), "missing-record.json"), "target")
      File.symlink("missing-record.json", path)
      ops.hive_commit(
        stage_name: "proposals", slug: "fixture", action: "recorded malformed candidate",
        pathspecs: [ relative ]
      )

      result = Hive::Proposals::Compiler.compile_at_ref(
        git_ops: ops, source_ref: ops.hive_state_head_sha,
        output_root: File.join(project, "compiled")
      )

      assert_equal 0, result.projection_count
      assert_equal [ "symlink" ], result.index.fetch("diagnostics").map { |item| item.fetch("code") }
    end
  end

  private

  def draft_id = "prp-00000000-0000-4000-8000-000000000001"
  def rejected_id = "prp-00000000-0000-4000-8000-000000000002"

  def create_record(id, store: @store, change: "Change review")
    store.create_record!(
      proposal_id: id, subject_kind: "skill", subject_ref: "agent-skills/reviewer",
      revision: "v2", proposed_change: change, motivation: "Improve recall",
      evidence: [ evidence ], author: author, lineage: {}, provenance: provenance,
      source_event_id: source_id("record-#{id}"), created_at: "2026-08-30T12:00:00Z",
      policy: policy
    )
  end

  def reject_without_evaluation(id)
    projection = @store.projection(id)
    @store.append_event!(
      proposal_id: id, type: "decision",
      data: {
        "outcome" => "rejected", "considered_evaluation_ids" => [],
        "considered_evaluations" => [], "rationale_category" => "no_evaluation",
        "rationale" => "Not suitable | retain lesson", "authority" => authority,
        "links" => [], "observed_head" => projection.lifecycle_head
      },
      source_event_id: source_id("decision-#{id}"), provenance: provenance,
      occurred_at: "2026-08-30T12:10:00Z", policy: policy
    )
  end

  def source_id(seed) = "pse-#{Digest::SHA256.hexdigest(seed)}"

  def evidence
    {
      "label" => "benchmark", "content" => "score=0.8", "visibility" => "project",
      "retention" => "project", "media_type" => "text/plain"
    }
  end

  def author = { "id" => "alice", "kind" => "proposer", "binding" => "team:skills" }

  def authority
    {
      "id" => "operator", "kind" => "operator",
      "policy_fingerprint" => "b" * 64
    }
  end

  def policy
    {
      "visibility" => "project", "retention" => "project",
      "allowed_link_schemes" => [ "https" ]
    }
  end

  def provenance
    {
      "task_id" => "43059", "task_generation" => 1,
      "ownership_generation" => "owner-1", "attempt_id" => "attempt-1",
      "workflow_id" => "coding", "stage" => "4-execute",
      "actor" => { "id" => "alice", "kind" => "operator" },
      "source_commit" => "a" * 40
    }
  end
end
