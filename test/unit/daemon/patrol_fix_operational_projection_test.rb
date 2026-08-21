require "test_helper"
require "hive/daemon/patrol_fix_operational_projection"

class DaemonPatrolFixOperationalProjectionTest < Minitest::Test
  NOW = Time.utc(2026, 8, 21, 12)

  class PagedArchitectureQuery
    PAGE_SIZE = 11

    def initialize(jobs)
      @jobs = jobs
    end

    def list_envelope(project:, project_root:, limit:, cursor: nil)
      offset = cursor ? Integer(cursor) : 0
      selected = @jobs.slice(offset, [ limit, PAGE_SIZE ].min) || []
      next_offset = offset + selected.length
      has_more = next_offset < @jobs.length
      {
        "project" => project, "project_root" => project_root,
        "count" => @jobs.length, "jobs" => selected,
        "page" => {
          "has_more" => has_more,
          "next_cursor" => has_more ? next_offset.to_s : nil
        }
      }
    end

    def show_envelope(**)
      raise "details should not be read for zero-finding fixtures"
    end
  end

  def test_normalizes_both_source_inventories_into_one_bounded_projection
    reader = Hive::Daemon::PatrolFixOperationalProjection.new(
      ordinary_reader: ->(**) { ordinary_payload },
      architecture_reader: ->(**) { architecture_payload },
      allowance_reader: ->(engine:, **) { allowance(engine) },
      admissions_reader: ->(**) { [] },
      batches_reader: ->(**) { [ { "status" => "claimed" }, { "status" => "finalized" } ] },
      scheduled_results_reader: ->(**) { [ { "created_at" => "2026-08-21T11:30:00Z" } ] },
      usage_reader: ->(**) { usage }
    )

    projection = reader.call(project: project, config: config, tasks: [], now: NOW)

    ordinary = projection.dig("discovery", "ordinary")
    architecture = projection.dig("discovery", "architecture")
    assert_equal "ordinary_patrol", ordinary.dig("items", 0, "engine")
    assert_equal "Reachable crash", ordinary.dig("items", 0, "summary")
    assert_equal "architecture_patrol", architecture.dig("items", 0, "engine")
    assert_equal [ "Duplicate owner", "Consolidate ownership" ],
                 architecture.dig("items", 0, "evidence")
    assert_equal 1, projection.dig("discovery", "post_merge", "queued")
    assert_equal 2, projection.dig("discovery", "post_merge", "batches")
    assert_equal "2026-08-21T11:30:00Z",
                 projection.dig("discovery", "coverage", "architecture", "observed_at")
    assert_equal 3, ordinary.dig("allowance", "remaining")
    assert_equal 34, projection.dig("tokens", "total")
    assert_equal 4, projection.dig("tokens", "launches")
  end

  def test_source_failure_is_bounded_and_does_not_erase_other_lane
    reader = Hive::Daemon::PatrolFixOperationalProjection.new(
      ordinary_reader: ->(**) { raise Hive::ConfigError, "/secret/project corrupt" },
      architecture_reader: ->(**) { architecture_payload },
      allowance_reader: ->(engine:, **) { allowance(engine) },
      admissions_reader: ->(**) { [] },
      batches_reader: ->(**) { [] }, scheduled_results_reader: ->(**) { [] },
      usage_reader: ->(**) { { available: false } }
    )

    projection = reader.call(project: project, config: config, tasks: [], now: NOW)

    assert_equal "unavailable", projection.dig("discovery", "ordinary", "health")
    assert_equal 1, projection.dig("discovery", "architecture", "items").size
    assert_equal "partial", projection.fetch("completeness")
    diagnostic = projection.fetch("diagnostics").fetch(0)
    assert_equal "ordinary_discovery_unavailable", diagnostic.fetch("code")
    refute_includes diagnostic.fetch("summary"), "/secret/project"
    assert_equal false, projection.dig("tokens", "available")
    assert_nil projection.dig("tokens", "total")
    assert projection.fetch("diagnostics").any? do |entry|
      entry.fetch("code") == "token_telemetry_unavailable"
    end
  end

  def test_usage_failure_does_not_erase_discovery
    reader = Hive::Daemon::PatrolFixOperationalProjection.new(
      ordinary_reader: ->(**) { ordinary_payload },
      architecture_reader: ->(**) { architecture_payload },
      allowance_reader: ->(engine:, **) { allowance(engine) },
      admissions_reader: ->(**) { [] },
      batches_reader: ->(**) { [] }, scheduled_results_reader: ->(**) { [] },
      usage_reader: ->(**) { raise IOError, "private database path" }
    )

    projection = reader.call(project: project, config: config, tasks: [], now: NOW)

    assert_equal 1, projection.dig("discovery", "ordinary", "total")
    assert_equal false, projection.dig("tokens", "available")
    assert_equal 1, projection.fetch("diagnostics").count do |entry|
      entry.fetch("source") == "token_telemetry"
    end
    refute_includes projection.fetch("diagnostics").last.fetch("summary"), "private database path"
  end

  def test_architecture_totals_and_post_merge_are_complete_beyond_item_limit
    Dir.mktmpdir("hive-patrol-fix-operations") do |dir|
      states = ([ "queued" ] * 10) + ([ "analyzing" ] * 4) +
        ([ "classified" ] * 3) + ([ "acting" ] * 2) +
        ([ "blocked" ] * 7) + ([ "complete" ] * 4)
      jobs = states.each_with_index.map do |state, index|
        {
          "job_id" => format("job-%03d", index), "state" => state,
          "complete" => state == "complete",
          "source" => { "number" => index + 1 },
          "analysis_sha" => "b" * 40,
          "counts" => { "fix" => 0, "discuss" => 0, "pending_actions" => 0 },
          "blockers" => [],
          "created_at" => (NOW - 3600 + index).iso8601,
          "updated_at" => (NOW - 3600 + index).iso8601
        }
      end
      reader = Hive::Daemon::PatrolFixOperationalProjection.new(
        ordinary_reader: ->(**) { ordinary_payload },
        architecture_query_factory: ->(_store) { PagedArchitectureQuery.new(jobs) },
        allowance_reader: ->(engine:, **) { allowance(engine) },
        admissions_reader: ->(**) { [] },
        batches_reader: ->(**) { [] }, scheduled_results_reader: ->(**) { [] },
        usage_reader: ->(**) { usage }
      )
      scoped_project = project.merge(
        "path" => dir, "hive_state_path" => File.join(dir, ".hive-state")
      )

      projection = reader.call(
        project: scoped_project, config: config, tasks: [], now: NOW
      )

      architecture = projection.dig("discovery", "architecture")
      assert_equal 30, architecture.fetch("total")
      assert_equal 25, architecture.fetch("items").length
      assert_equal true, architecture.fetch("truncated")
      assert_equal 10, architecture.dig("counts", "queued")
      assert_equal 7, architecture.dig("counts", "blocked")
      assert_equal 10, projection.dig("discovery", "post_merge", "queued")
      assert_equal 9, projection.dig("discovery", "post_merge", "in_flight")
      assert_equal 7, projection.dig("discovery", "post_merge", "blocked")
    end
  end

  private

  def project
    { "name" => "demo", "project_id" => "project-1", "path" => "/demo",
      "hive_state_path" => "/demo/.hive-state" }
  end

  def config
    { "patrol" => { "mode" => "medium" }, "refactor_patrol" => { "enabled" => true } }
  end

  def allowance(engine)
    { engine: engine.to_s, utc_date: "2026-08-21", limit: 4, used: 1,
      remaining: 3, status: "available", retry_at: nil }
  end

  def ordinary_payload
    {
      "count" => 1, "counts" => { "active" => 1 }, "truncated" => false,
      "last_run_at" => "2026-08-21T10:00:00Z", "feature_review_active" => false,
      "findings" => [ {
        "id" => "finding-1", "lifecycle_state" => "active", "title" => "Repair crash",
        "description" => "Reachable crash", "severity" => "high", "confidence" => "high",
        "feature_id" => "auth", "analysis_sha" => "a" * 40,
        "updated_at" => "2026-08-21T10:00:00Z"
      } ]
    }
  end

  def architecture_payload
    {
      "count" => 1, "counts" => { "queued" => 1 }, "truncated" => false,
      "last_run_at" => "2026-08-21T11:00:00Z",
      "jobs" => [ {
        "job_id" => "job-1", "state" => "queued", "analysis_sha" => "b" * 40,
        "source" => { "number" => 42, "url" => "https://github.com/acme/demo/pull/42" },
        "counts" => { "fix" => 1, "discuss" => 0, "pending_actions" => 1 },
        "blockers" => [], "updated_at" => "2026-08-21T11:00:00Z",
        "findings" => [ {
          "id" => "thesis-1", "route" => "fix", "problem" => "Duplicate owner",
          "proposed_refactor" => "Consolidate ownership"
        } ]
      } ]
    }
  end

  def usage
    { available: true, input: 10, output: 24, cached: 5, tokens: 34,
      agent_spawns: 4, unmetered_spawns: 1 }
  end
end
