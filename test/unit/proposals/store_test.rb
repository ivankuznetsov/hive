require "test_helper"
require "hive/proposals/store"

class ProposalStoreTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("proposal-store")
    @root = File.join(@tmp, "proposals", "v1")
    @ids = %w[
      00000000-0000-4000-8000-000000000001
      00000000-0000-4000-8000-000000000002
      00000000-0000-4000-8000-000000000003
    ]
    @store = Hive::Proposals::Store.new(root: @root, id_generator: -> { @ids.shift })
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_immutable_record_creation_is_idempotent_and_conflicts_on_changed_content
    first = @store.create_record!(**record_attributes)
    replay = @store.write_record!(first)

    assert_equal first.to_h, replay.to_h
    assert_equal 1, Dir.glob(File.join(@root, "records", "*.json")).length

    changed = first.to_h.merge("motivation" => "Different")
    assert_raises(Hive::Proposals::Conflict) do
      @store.write_record!(Hive::Proposals::Record.new(changed))
    end
    assert_equal first.to_h, @store.fetch_record(first.proposal_id).to_h
  end

  def test_independently_quarantines_invalid_oversize_and_symlinked_neighbors
    valid = @store.create_record!(**record_attributes)
    records = File.join(@root, "records")
    File.write(File.join(records, "prp-00000000-0000-4000-8000-000000000099.json"), "{")
    File.write(
      File.join(records, "prp-00000000-0000-4000-8000-000000000098.json"),
      "x" * (Hive::Proposals::Store::MAX_FILE_BYTES + 1)
    )
    File.symlink(
      File.join(records, "#{valid.proposal_id}.json"),
      File.join(records, "prp-00000000-0000-4000-8000-000000000097.json")
    )

    snapshot = @store.load

    assert_equal [ valid.proposal_id ], snapshot.records.map(&:proposal_id)
    assert_equal %w[invalid_json oversize symlink], snapshot.diagnostics.map(&:code).sort
    snapshot.diagnostics.each do |diagnostic|
      refute_match(/x{32}/, diagnostic.to_h.to_s)
      assert_operator diagnostic.to_h.to_s.bytesize, :<, 1_024
    end
  end

  def test_malformed_event_filename_reserves_its_numeric_slot
    proposal = @store.create_record!(**record_attributes)
    events = File.join(@root, "events", proposal.proposal_id)
    FileUtils.mkdir_p(events)
    File.write(File.join(events, "00000000000000000007-not-an-event.json"), "{}")

    event = @store.append_event!(
      proposal_id: proposal.proposal_id, type: "evaluation",
      source_event_id: "pse-#{'b' * 64}", provenance: provenance,
      occurred_at: "2026-08-30T12:01:00Z",
      data: evaluation_data
    )

    assert_equal 8, event.version
    assert File.file?(File.join(events, "00000000000000000008-#{event.event_id}.json"))
    assert_equal "invalid_event_filename", @store.load.diagnostics.first.code
  end

  def test_changed_source_event_payload_conflicts_without_appending
    proposal = @store.create_record!(**record_attributes)
    first = @store.append_event!(
      proposal_id: proposal.proposal_id, type: "evaluation",
      source_event_id: "pse-#{'b' * 64}", provenance: provenance,
      occurred_at: "2026-08-30T12:01:00Z", data: evaluation_data
    )
    replay = @store.append_event!(
      proposal_id: proposal.proposal_id, type: "evaluation",
      source_event_id: "pse-#{'b' * 64}", provenance: provenance,
      occurred_at: "2026-08-30T12:01:00Z", data: evaluation_data
    )
    assert_equal first.event_id, replay.event_id

    assert_raises(Hive::Proposals::Conflict) do
      @store.append_event!(
        proposal_id: proposal.proposal_id, type: "evaluation",
        source_event_id: "pse-#{'b' * 64}", provenance: provenance,
        occurred_at: "2026-08-30T12:01:00Z",
        data: evaluation_data.merge("rationale" => "changed")
      )
    end
    assert_equal 1, @store.load.events.fetch(proposal.proposal_id).length
  end

  private

  def record_attributes
    {
      subject_kind: "workflow", subject_ref: "coding", revision: "v2",
      proposed_change: "Change review", motivation: "Improve recall",
      evidence: [
        {
          "label" => "score", "content" => "0.91", "visibility" => "project",
          "retention" => "task", "media_type" => "text/plain"
        }
      ],
      author: { "id" => "alice", "kind" => "proposer", "binding" => "team" },
      provenance:, source_event_id: "pse-#{'a' * 64}",
      created_at: "2026-08-30T12:00:00Z",
      policy: { "visibility" => "project", "retention" => "project" }
    }
  end

  def provenance
    {
      "task_id" => "43059", "task_generation" => 1,
      "ownership_generation" => "owner-1", "attempt_id" => "attempt-1",
      "workflow_id" => "coding", "stage" => "4-execute",
      "actor" => { "id" => "alice", "kind" => "configured_identity" },
      "source_commit" => "a" * 40
    }
  end

  def evaluation_data
    {
      "evaluator" => { "id" => "reviewer", "binding_fingerprint" => "b" * 64 },
      "method" => { "kind" => "benchmark", "label" => "recall" },
      "result" => { "outcome" => "pass", "metrics" => { "recall" => 0.91 } },
      "rationale" => "Improved", "evidence" => [], "links" => []
    }
  end
end
