require "test_helper"
require "tmpdir"
require "hive/refactor_patrol/fix_admission_outbox"
require "hive/refactor_patrol/job_store"

class RefactorPatrolFixAdmissionOutboxTest < Minitest::Test
  NOW = Time.utc(2026, 8, 20, 12)

  def test_actionable_disposition_is_a_bounded_architecture_snapshot
    Dir.mktmpdir do |dir|
      outbox = Hive::RefactorPatrol::FixAdmissionOutbox.new(root: dir)
      entry = outbox.publish_disposition!(aggregate, disposition, accepted_at: NOW)

      assert_equal "architecture_patrol", entry.dig("snapshot", "engine")
      assert_equal "job-1:thesis-1", entry.dig("snapshot", "identity")
      assert_equal [ "lib/refresh.rb" ], entry.dig("snapshot", "affected_code")
      assert_equal [ entry ], outbox.pending
      outbox.acknowledge!(
        occurrence_id: entry.fetch("occurrence_id"),
        admission_id: entry.fetch("occurrence_id"),
        task: { "slug" => "repair-refresh-abc123", "generation" => 1,
                "evidence_digest" => "a" * 64 }, now: NOW
      )
    end
  end

  def test_job_store_acceptance_boundary_calls_auxiliary_outbox_without_changing_v4
    Dir.mktmpdir do |dir|
      published = []
      outbox = Object.new
      outbox.define_singleton_method(:publish_disposition!) do |aggregate, item|
        published << [ aggregate.fetch("job_id"), item.fetch("id") ]
      end
      store = Hive::RefactorPatrol::JobStore.new(
        dir, patrol_fix_admission_outbox: outbox
      )
      aggregate = {
        "job_id" => "job-1", "analysis_sha" => "2" * 40,
        "source" => {}, "feature_results" => [],
        "dispositions" => { "fix" => [], "discuss" => [], "dismiss" => [] }
      }
      payload = {
        "feature_results" => [ {
          "feature_id" => "refresh", "complete" => true,
          "thesis_ids" => [ "thesis-1" ], "errors" => []
        } ],
        "fix" => [ disposition ], "discuss" => [], "dismiss" => []
      }

      store.send(:merge_discovery_progress!, aggregate, payload)

      assert_equal [ [ "job-1", "thesis-1" ] ], published
      assert_equal [ "thesis-1" ], aggregate.dig("dispositions", "fix").map { |item| item.fetch("id") }
    end
  end

  private

  def aggregate
    {
      "job_id" => "job-1", "analysis_sha" => "2" * 40,
      "updated_at" => NOW.iso8601,
      "source" => { "changed_paths" => [ "lib/refresh.rb" ] }
    }
  end

  def disposition
    {
      "id" => "thesis-1", "feature_id" => "refresh", "fingerprint" => "refresh-root",
      "route" => "fix", "admissible" => true, "reasons" => [],
      "thesis" => {
        "id" => "thesis-1", "feature_id" => "refresh", "feature" => "Refresh",
        "problem" => "Recovery has two owners", "cost" => "Repeated failures",
        "evidence" => [ "Reachable failure" ],
        "proposed_refactor" => "Consolidate recovery", "fingerprint" => "refresh-root",
        "feature_boundary" => { "owned_files" => [ "lib/refresh.rb" ] },
        "architecture_effects" => [ "one recovery owner" ], "route" => "fix",
        "confidence" => "high", "risk" => { "flags" => [] },
        "required_validation" => { "commands" => [ "bin/test refresh" ] },
        "admissible" => true, "admissibility_reason" => "",
        "follow_up_approval_state" => "pending"
      }
    }
  end
end
