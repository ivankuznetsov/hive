require "test_helper"
require "hive/daemon/patrol_fix_runtime"
require "hive/patrol_fix/source_snapshot"

class HiveDaemonPatrolFixRuntimeTest < Minitest::Test
  include HiveTestHelper

  def test_registry_changes_are_visible_without_restarting_the_daemon
    with_tmp_dir do |dir|
      entries = [ {
        "name" => "alpha", "path" => File.join(dir, "alpha"),
        "hive_state_path" => File.join(dir, "alpha", ".hive-state")
      } ]
      runtime = Hive::Daemon::PatrolFixRuntime.new(
        registry: -> { entries }, config_loader: ->(_path) { {} }
      )

      assert_equal [ "alpha" ], runtime.sources.map(&:project).uniq
      assert_equal 1, runtime.sources.length
      entries << {
        "name" => "beta", "path" => File.join(dir, "beta"),
        "hive_state_path" => File.join(dir, "beta", ".hive-state")
      }

      assert_equal %w[alpha beta], runtime.sources.map(&:project).uniq
      assert_equal 2, runtime.sources.length
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
        end
      )
      source = runtime.sources.fetch(0)
      store = source.store
      assert_instance_of Hive::PatrolFix::AdmissionStore, store
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
