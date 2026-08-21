require "test_helper"
require "hive/patrol_fix/operational_projection"
require "open3"
require "rbconfig"

class PatrolFixOperationalProjectionTest < Minitest::Test
  NOW = Time.utc(2026, 8, 21, 12)

  def test_unique_root_cohorts_ignore_aliases_and_separate_created_from_open_prs
    projection = build(
      admissions: [
        admission("ordinary-1", created_at: "2026-08-20T10:00:00Z", task: "repair-auth"),
        admission("architecture-1", created_at: "2026-08-20T11:00:00Z", task: "repair-auth"),
        admission("ordinary-2", created_at: "2026-08-21T09:00:00Z", decision: "distinct")
      ],
      tasks: [
        task("repair-auth", publication_state: "closed", aliases: 8),
        task("repair-cache", publication_state: "open", aliases: 5)
      ]
    )

    assert_equal 2, projection.dig("admission", "unique_roots")
    assert_equal 1, projection.dig("delivery", "task_conversion", "converted")
    assert_equal 2, projection.dig("delivery", "task_conversion", "denominator")
    assert_equal 1, projection.dig("delivery", "pr_created")
    assert_equal 0, projection.dig("delivery", "pr_open")
    assert_equal [ "2026-08-20", "2026-08-21" ],
                 projection.dig("delivery", "cohorts").map { |row| row.fetch("utc_date") }
  end

  def test_unresolved_admission_is_separate_and_makes_conversion_partial
    projection = build(admissions: [
      admission("blocked-1", decision: "insufficient_evidence", status: "blocked")
    ])

    assert_equal 0, projection.dig("admission", "unique_roots")
    assert_equal 1, projection.dig("admission", "unresolved")
    assert_equal "partial", projection.fetch("completeness")
    assert_nil projection.dig("delivery", "task_conversion", "rate")
  end

  def test_stage_latency_excludes_parked_and_provider_intervals
    projection = build(tasks: [
      task("repair-auth").merge(
        "mtime" => "2026-08-21T11:30:00Z",
        "held" => { "reason" => "quota", "provider" => "codex", "retry_after" => "2026-08-21T13:00:00Z" },
        "patrol_fix" => task("repair-auth").fetch("patrol_fix").merge(
          "timing" => {
            "started_at" => "2026-08-21T10:00:00Z",
            "stage_started_at" => "2026-08-21T10:00:00Z",
            "parked_seconds" => 900,
            "parked_since" => nil,
            "rework_count" => 2
          }
        )
      )
    ])

    latency = projection.dig("workflow", "latency")
    assert_equal 7_200, latency.fetch("total_seconds")
    assert_equal 900, latency.fetch("parked_seconds")
    assert_nil latency.fetch("provider_seconds")
    assert_nil latency.fetch("active_seconds")
    assert_equal "unavailable", latency.fetch("provider_history")
    assert_equal 1, latency.dig("current_provider", "tasks")
    assert_equal "2026-08-21T13:00:00Z", latency.dig("current_provider", "next_retry_at")
    assert_equal 2, projection.dig("workflow", "counts", "rework")
  end

  def test_discovery_lanes_and_post_merge_are_kept_independent_and_bounded
    ordinary = lane("ordinary", 30)
    architecture = lane("architecture", 3)
    projection = build(
      discovery: {
        "ordinary" => ordinary,
        "architecture" => architecture,
        "post_merge" => { "queued" => 2, "in_flight" => 1, "blocked" => 1, "batches" => 4 },
        "coverage" => { "ordinary" => nil, "architecture" => nil }
      }
    )

    assert_equal 25, projection.dig("discovery", "ordinary", "items").size
    assert projection.dig("discovery", "ordinary", "truncated")
    assert_equal 3, projection.dig("discovery", "architecture", "items").size
    assert_equal 2, projection.dig("discovery", "post_merge", "queued")
  end

  def test_item_evidence_is_capped_to_three_one_kib_snippets
    ordinary = lane("ordinary", 1)
    ordinary.fetch("items").first["evidence"] = Array.new(5, "x" * 1_024)
    projection = build(discovery: {
      "ordinary" => ordinary, "architecture" => lane("architecture", 0),
      "post_merge" => {}, "coverage" => {}
    })

    evidence = projection.dig("discovery", "ordinary", "items", 0, "evidence")
    assert_equal 3, evidence.length
    assert evidence.all? { |value| value.bytesize == 1_024 }
  end

  def test_document_validator_rejects_cross_project_extensions_and_nested_overflow
    projection = build
    assert Hive::PatrolFix::OperationalProjection.valid_document?(projection, project: "demo")

    refute Hive::PatrolFix::OperationalProjection.valid_document?(
      projection.merge("project" => "other"), project: "demo"
    )
    refute Hive::PatrolFix::OperationalProjection.valid_document?(
      projection.merge("extension" => true), project: "demo"
    )
    overflow = Marshal.load(Marshal.dump(projection))
    overflow.dig("discovery", "ordinary", "items").concat(
      Array.new(Hive::PatrolFix::OperationalProjection::MAX_ITEMS_PER_LANE + 1) do |index|
        lane("ordinary", 1).dig("items", 0).merge("identity" => "overflow-#{index}")
      end
    )
    refute Hive::PatrolFix::OperationalProjection.valid_document?(overflow, project: "demo")

    malformed_tokens = Marshal.load(Marshal.dump(projection))
    malformed_tokens.fetch("tokens")["available"] = true
    refute Hive::PatrolFix::OperationalProjection.valid_document?(malformed_tokens, project: "demo")
    missing_lane_key = Marshal.load(Marshal.dump(projection))
    missing_lane_key.dig("discovery", "ordinary").delete("allowance")
    refute Hive::PatrolFix::OperationalProjection.valid_document?(missing_lane_key, project: "demo")
    invalid_time = Marshal.load(Marshal.dump(projection))
    invalid_time["generated_at"] = "yesterday"
    refute Hive::PatrolFix::OperationalProjection.valid_document?(invalid_time, project: "demo")
  end

  def test_standalone_require_does_not_depend_on_test_helper_load_order
    _out, error, status = Open3.capture3(
      RbConfig.ruby, "-Ilib", "-e",
      "require 'hive/patrol_fix/operational_projection'; puts Hive::PatrolFix::OperationalProjection::SCHEMA"
    )

    assert status.success?, error
  end

  def test_rejects_unbounded_sources_and_duplicate_task_identities
    oversized = lane("ordinary", 1)
    oversized.fetch("items").first["source"] = { "url" => "x" * 4_097 }
    assert_raises(ArgumentError) { build(discovery: {
      "ordinary" => oversized, "architecture" => lane("architecture", 0),
      "post_merge" => {}, "coverage" => {}
    }) }

    duplicate = task("repair-auth")
    assert_raises(ArgumentError) { build(tasks: [ duplicate, duplicate ]) }
    assert_raises(ArgumentError) do
      build(admissions: Array.new(Hive::PatrolFix::AdmissionStore::MAX_RECORDS + 1, {}))
    end
  end

  def test_parked_task_does_not_also_accrue_provider_time
    row = task("repair-auth")
    row["mtime"] = "2026-08-21T11:30:00Z"
    row["held"] = { "reason" => "quota" }
    row.fetch("patrol_fix")["outcome"] = {
      "kind" => "blocked", "receipt_id" => "blocked-1",
      "rationale" => "Needs evidence", "blocker_owner" => "operator"
    }
    row.fetch("patrol_fix").fetch("timing")["parked_seconds"] = 900

    latency = build(tasks: [ row ]).dig("workflow", "latency")
    assert_nil latency.fetch("provider_seconds")
    assert_equal 900, latency.fetch("parked_seconds")
  end

  def test_done_task_latency_stops_at_publication_observation
    row = task("repair-auth", publication_state: "closed")
    projection = build(tasks: [ row ])

    assert_equal 3_600, projection.dig("workflow", "latency", "total_seconds")
    assert_equal 3_600,
                 projection.dig("workflow", "latency", "by_stage", "6-done", "total_seconds")
  end

  def test_missing_task_timing_is_explicitly_unavailable_and_partial
    row = task("repair-auth")
    row.fetch("patrol_fix").fetch("timing")["started_at"] = nil

    projection = build(tasks: [ row ])

    assert_equal "partial", projection.fetch("completeness")
    assert_equal 0, projection.dig("workflow", "latency", "sample_count")
    assert_equal 1, projection.dig("workflow", "latency", "unavailable_count")
  end

  def test_token_telemetry_is_bounded_and_never_changes_discovery_allowance
    projection = build(tokens: {
      available: true, input: 11, output: 13, cached: 17, tokens: 24,
      agent_spawns: 3, unmetered_spawns: 1
    })

    assert_equal({
      "available" => true, "utc_date" => "2026-08-21",
      "input" => 11, "output" => 13, "cached" => 17, "total" => 24,
      "launches" => 3, "unmetered_launches" => 1
    }, projection.fetch("tokens"))
    assert_equal 3, projection.dig("discovery", "ordinary", "allowance", "remaining")

    unavailable = build.fetch("tokens")
    assert_equal false, unavailable.fetch("available")
    assert_nil unavailable.fetch("total")
    assert_nil unavailable.fetch("launches")
  end

  private

  def build(tasks: [], admissions: [], discovery: nil, tokens: nil)
    Hive::PatrolFix::OperationalProjection.new(
      project: "demo", tasks: tasks, admissions: admissions,
      discovery: discovery || {
        "ordinary" => lane("ordinary", 0), "architecture" => lane("architecture", 0),
        "post_merge" => { "queued" => 0, "in_flight" => 0, "blocked" => 0, "batches" => 0 },
        "coverage" => { "ordinary" => nil, "architecture" => nil }
      },
      migration: { "status" => "committed", "candidate_count" => 0, "group_count" => 0,
                   "disposition_count" => 0, "acknowledgement_count" => 0, "manifest_digest" => "a" * 64 },
      tokens: tokens, now: NOW
    ).to_h
  end

  def lane(engine, count)
    {
      "enabled" => true, "health" => "healthy", "total" => count,
      "counts" => {}, "last_run_at" => nil, "truncated" => false,
      "allowance" => {
        "engine" => engine, "utc_date" => "2026-08-21", "limit" => 4,
        "used" => 1, "remaining" => 3, "status" => "available", "retry_at" => nil
      },
      "items" => count.times.map do |index|
        {
          "engine" => "#{engine}_patrol", "identity" => "#{engine}-#{index}",
          "state" => "active", "title" => "Finding #{index}", "summary" => "Evidence",
          "route" => nil, "severity" => nil, "confidence" => nil,
          "feature_id" => nil, "target_revision" => nil, "source" => nil,
          "updated_at" => nil, "evidence" => [], "blocker" => nil
        }
      end
    }
  end

  def admission(id, created_at: "2026-08-21T09:00:00Z", task: nil,
                decision: task ? "same_root" : "distinct", status: task ? "acknowledged" : "decided")
    {
      "occurrence_id" => id, "status" => status, "created_at" => created_at,
      "decision" => {
        "decision" => decision,
        "candidate_identity" => decision == "same_root" ? task : nil
      },
      "task" => task && { "slug" => task },
      "retry" => nil
    }
  end

  def task(slug, publication_state: nil, aliases: 0)
    publication = publication_state && {
      "state" => publication_state, "id" => "github:acme/demo#1",
      "observed_at" => "2026-08-21T11:00:00Z"
    }
    {
      "slug" => slug, "stage" => publication ? "6-done" : "2-fix",
      "mtime" => "2026-08-21T10:00:00Z", "held" => nil,
      "patrol_fix" => {
        "state" => "current", "stage" => publication ? "6-done" : "2-fix",
        "aliases" => aliases.times.map { |index| { "kind" => "ordinary_finding", "value" => "alias-#{index}" } },
        "outcome" => nil, "successor" => nil, "publication" => publication,
        "timing" => {
          "started_at" => "2026-08-21T10:00:00Z", "stage_started_at" => "2026-08-21T10:00:00Z",
          "parked_seconds" => 0, "parked_since" => nil, "rework_count" => 0
        }
      }
    }
  end
end
