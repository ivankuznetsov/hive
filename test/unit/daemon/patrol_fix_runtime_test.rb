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

  def test_missing_or_changed_semantic_source_fails_closed
    with_tmp_dir do |dir|
      entry = { "name" => "demo", "path" => dir, "hive_state_path" => ".state" }
      runtime = Hive::Daemon::PatrolFixRuntime.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { {} }
      )

      assert_raises(Hive::ConfigError) do
        runtime.run_semantic_decision(
          project: "missing", source_name: "ordinary_patrol",
          occurrence_id: "finding-1", reservation_id: "a" * 64
        )
      end
      assert_raises(Hive::ConfigError) do
        runtime.run_semantic_decision(
          project: "demo", source_name: "ordinary_patrol",
          occurrence_id: "finding-1", reservation_id: "a" * 64
        )
      end
    end
  end

  def test_builds_task_materializer_with_normalized_default_state_path
    with_tmp_git_repo do |dir|
      runtime = Hive::Daemon::PatrolFixRuntime.new(
        registry: -> { [ { "name" => "demo", "path" => dir } ] },
        config_loader: ->(_path) { { "default_branch" => "HEAD" } }
      )
      source = runtime.sources.fetch(0)

      materializer = runtime.task_materializer(store: source.store, source: source)

      assert_instance_of Hive::PatrolFix::TaskMaterializer, materializer
      assert_equal File.join(dir, ".hive-state"), source.entry.fetch("hive_state_path")
      assert_equal Hive::GitOps.new(dir).head_sha,
                   materializer.instance_variable_get(:@current_head).call
    end
  end

  def test_default_runtime_factories_use_project_configuration
    with_tmp_global_config do
      with_tmp_dir do |dir|
        runtime = Hive::Daemon::PatrolFixRuntime.new(registry: -> { [] })
        cfg = runtime.instance_variable_get(:@config_loader).call(dir)
        state = Hive::Patrol::StateStore.new(dir)
        budget = Object.new

        identity = Struct.new(:review).new(Object.new)
        runner = with_replaced_singleton_method(
          Hive::RefactorPatrol::AgentIdentity, :new, ->(**) { identity }
        ) do
          runtime.instance_variable_get(:@decision_runner_factory).call(
            project_root: dir, cfg: cfg, state: state, launch_budget: budget
          )
        end

        assert_instance_of Hive::Daemon::PatrolFixSemanticDecisionRunner, runner
      end
    end
  end

  def test_current_head_failure_is_reported_as_git_error
    with_tmp_dir do |dir|
      runtime = Hive::Daemon::PatrolFixRuntime.new(
        registry: -> { [ { "name" => "demo", "path" => dir } ] },
        config_loader: ->(_path) { { "default_branch" => "missing" } }
      )
      source = runtime.sources.fetch(0)

      assert_raises(Hive::GitError) { runtime.send(:current_head, source) }
    end
  end
end
