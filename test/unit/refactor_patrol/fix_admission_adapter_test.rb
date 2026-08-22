require "test_helper"
require "tmpdir"
require "hive/refactor_patrol/fix_admission_adapter"
require "hive/refactor_patrol/job_store"

class RefactorPatrolFixAdmissionAdapterTest < Minitest::Test
  NOW = Time.utc(2026, 8, 20, 12)

  def test_actionable_disposition_is_a_bounded_architecture_snapshot
    Dir.mktmpdir do |dir|
      adapter = Hive::RefactorPatrol::FixAdmissionAdapter.new(root: dir)
      entry = adapter.publish_disposition!(aggregate, disposition, accepted_at: NOW)

      assert_equal "architecture_patrol", entry.dig("source", "engine")
      assert_equal "job-1:thesis-1", entry.dig("source", "identity")
      assert_equal [ "lib/refresh.rb" ], entry.dig("source", "affected_code")
      assert_equal [ entry ], adapter.store.pending
      %i[pending park! defer! resume! acknowledge! settle!].each do |method|
        refute_respond_to adapter, method
      end
    end
  end

  def test_job_store_acceptance_boundary_calls_direct_admission_without_changing_v4
    Dir.mktmpdir do |dir|
      published = []
      adapter = Object.new
      adapter.define_singleton_method(:publish_disposition!) do |aggregate, item|
        published << [ aggregate.fetch("job_id"), item.fetch("id") ]
      end
      store = Hive::RefactorPatrol::JobStore.new(
        dir, patrol_fix_admission_adapter: adapter
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

  def test_job_store_and_daemon_share_the_project_admission_root
    Dir.mktmpdir do |dir|
      hive_state = File.join(dir, ".hive-state")
      store = Hive::RefactorPatrol::JobStore.new(dir, hive_state_path: hive_state)

      assert_equal File.join(hive_state, "patrol-fix", "admissions"),
                   store.patrol_fix_admission_adapter.store.root
    end
  end

  def test_invalid_source_time_and_non_json_evidence_fall_back_safely
    Dir.mktmpdir do |dir|
      adapter = Hive::RefactorPatrol::FixAdmissionAdapter.new(root: dir)
      source = Marshal.load(Marshal.dump(aggregate))
      source["source"]["merged_at"] = "not-a-time"
      item = Marshal.load(Marshal.dump(disposition))
      item.fetch("thesis")["evidence"] = [ Float::NAN ]

      entry = adapter.publish_disposition!(source, item, accepted_at: NOW)

      assert_equal NOW.iso8601, entry.dig("source", "accepted_at")
      assert_equal [ "Recovery has two owners" ], entry.dig("source", "evidence")
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
