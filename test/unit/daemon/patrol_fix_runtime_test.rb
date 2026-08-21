require "test_helper"
require "hive/daemon/patrol_fix_runtime"
require "hive/patrol_fix/source_snapshot"

class HiveDaemonPatrolFixRuntimeTest < Minitest::Test
  include HiveTestHelper

  Row = Data.define(:project, :slug, :stage, :marker, :marker_attrs, :patrol_fix)

  class Projection
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(**arguments)
      @calls << arguments
      {
        "schema" => "hive-patrol-fix-operational-projection",
        "project" => arguments.fetch(:project).fetch("name"),
        "tasks" => arguments.fetch(:tasks)
      }
    end

    def unavailable(**)
      raise "unexpected unavailable projection"
    end
  end

  def test_groups_final_task_rows_by_project_and_preserves_only_current_hold
    with_tmp_dir do |dir|
      projection = Projection.new
      entries = %w[alpha beta].map do |name|
        root = File.join(dir, name)
        {
          "name" => name, "path" => root,
          "hive_state_path" => File.join(root, ".hive-state")
        }
      end
      runtime = Hive::Daemon::PatrolFixRuntime.new(
        registry: -> { entries }, config_loader: ->(_path) { { "loaded" => true } },
        operational_projection: projection
      )
      held = Row.new(
        project: "alpha", slug: "repair-auth", stage: "2-fix", marker: "error",
        marker_attrs: {
          "reason" => "limits_reached", "provider" => "codex",
          "retry_after" => "2026-08-21T14:00:00Z"
        },
        patrol_fix: { "state" => "current" }
      )

      rows = runtime.operational_projections(tasks: [ held ], now: Time.utc(2026, 8, 21, 12))

      assert_equal %w[alpha beta], rows.keys
      task = rows.dig("alpha", "tasks", 0)
      assert_equal "repair-auth", task.fetch("slug")
      assert_equal "codex", task.dig("held", "provider")
      assert_equal "2026-08-21T14:00:00Z", task.dig("held", "retry_after")
      assert_empty rows.dig("beta", "tasks")
      assert_equal 2, projection.calls.length
    end
  end

  def test_provider_is_constructed_only_by_reserved_child_execution
    with_tmp_git_repo do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(hive_state)
      entry = {
        "name" => "demo", "path" => project_root,
        "hive_state_path" => hive_state
      }
      provider_constructions = 0
      provider_calls = 0
      runtime = Hive::Daemon::PatrolFixRuntime.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { { "default_branch" => "HEAD" } },
        decision_runner_factory: lambda do |**_arguments|
          provider_constructions += 1
          lambda do |_input|
            provider_calls += 1
            {
              "decision" => "distinct", "candidate_identity" => nil,
              "rationale" => "No existing Patrol Fix task",
              "evidence" => [ "The owned inventory is empty" ],
              "model_receipt" => "fake:runtime-child"
            }
          end
        end,
        operational_projection: Projection.new
      )
      source = runtime.sources.find { |item| item.source == "ordinary_patrol" }
      store = runtime.admission_store(source: source)
      semantic = runtime.semantic_admission(store: store, source: source)
      snapshot = Hive::PatrolFix::SourceSnapshot.build(
        engine: "ordinary_patrol", identity: "finding-1", title: "Repair refresh",
        summary: "Refresh fails", target_revision: Hive::GitOps.new(project_root).head_sha,
        evidence: [ "Reachable refresh failure" ], affected_code: [ "lib/refresh.rb" ],
        reproduction_guidance: "Run refresh spec", discovery_run: "run-1",
        semantic_lineage: [ "refresh" ], aliases: [], external_issues: [],
        existing_pull_requests: [], accepted_at: Time.utc(2026, 8, 21, 12).iso8601
      )
      semantic.prepare(
        occurrence_id: "ordinary:finding-1:v1", snapshot: snapshot,
        reservation_id: "a" * 64,
        lease_expires_at: Time.now.utc + 60, now: Time.now.utc
      )

      assert_equal 0, provider_constructions
      assert_equal 0, provider_calls
      result = runtime.run_semantic_decision(
        project: "demo", source_name: "ordinary_patrol",
        occurrence_id: "ordinary:finding-1:v1", reservation_id: "a" * 64
      )

      assert_equal "decided", result.fetch("status")
      assert_equal 1, provider_constructions
      assert_equal 1, provider_calls
    end
  end
end
