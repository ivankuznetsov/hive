require "test_helper"
require "fileutils"
require "json"
require "tmpdir"
require "yaml"
require "hive/commands/approve"
require "hive/commands/run"
require "hive/commands/stage_action"
require "hive/daemon/dispatcher"
require "hive/daemon/plan_approval"
require "hive/daemon/policy"
require "hive/daemon/status_consumer"
require "hive/markers"
require "hive/plan_dependency_correction"
require "hive/plan_review/identity"
require "hive/plan_review/policy"
require "hive/plan_review/projection"
require "hive/plan_review/store"
require "hive/plan_review/transition_guard"
require "hive/recovery"
require "hive/stages/plan"
require "hive/task"
require "hive/task_action"
require "hive/task_meta"

class PlanDependencyCorrectionTest < Minitest::Test
  include HiveTestHelper

  REPO_IDENTITY = "github.com/acme/app".freeze

  def with_project_env
    Dir.mktmpdir("hive-u2-correction-") do |root|
      FileUtils.mkdir_p(File.join(root, ".hive-state", "stages", "3-plan"))
      prepare_test_runtime_project(root)
      File.write(
        File.join(root, ".hive-state", "config.yml"),
        YAML.dump(
          "plan_review" => { "enabled" => true, "minimum_level" => "skip" },
          "rebase" => { "enabled" => false }
        )
      )
      registry = [
        {
          "name" => "app",
          "path" => root,
          "hive_state_path" => File.join(root, ".hive-state"),
          "repository_identity" => REPO_IDENTITY
        }
      ]
      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { registry }) do
        with_replaced_singleton_method(Hive::RepositoryIdentity, :current, ->(_) { REPO_IDENTITY }) do
          yield root
        end
      end
    end
  end

  def create_task(root, slug, stage: "3-plan", id:, depends_on: nil, idempotency_key: nil,
                  plan_content: nil, plan_review_required: nil)
    folder = File.join(root, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(
      folder,
      id: id,
      slug: slug,
      display_name: slug,
      workflow: "coding",
      depends_on: depends_on,
      idempotency_key: idempotency_key,
      plan_review_required: plan_review_required
    )
    File.write(File.join(folder, "plan.md"), plan_content) if plan_content
    Hive::Task.new(folder)
  end

  def stub_no_git_commit
    fake_ops = Object.new
    fake_ops.define_singleton_method(:hive_commit) { |**| nil }
    with_replaced_singleton_method(Hive::GitOps, :new, ->(*, **) { fake_ops }) do
      with_replaced_singleton_method(Hive::Stages::Plan, :with_source_checkout, ->(_t, &blk) { blk.call(nil) }) do
        yield
      end
    end
  end

  def publish_cleared_review(task, cfg)
    store = Hive::PlanReview::Store.new(task_folder: task.folder)
    plan_digest = Digest::SHA256.file(task.state_file).hexdigest
    generation = Hive::PlanReview::Identity.task_generation(task)
    review_id = Hive::PlanReview::Identity.logical(
      task_id: task.id,
      plan_generation: "#{generation}:#{plan_digest}",
      policy_fingerprint: "c" * 64
    )
    common = {
      "schema" => "hive-plan-review", "schema_version" => 1,
      "review_id" => review_id, "prior_review_id" => nil,
      "task_id" => task.id.to_s, "task_generation" => generation,
      "plan_digest" => plan_digest, "policy_fingerprint" => "c" * 64,
      "computed_level" => "standard", "effective_level" => "standard",
      "created_at" => "2026-10-30T12:00:00Z"
    }
    store.create_review!(Hive::PlanReview::Record.new(common.merge("kind" => "manifest")))
    policy = store.write_review_artifact!(
      review_id:, basename: "policy.json", json: true,
      content: {
        "configuration_fingerprint" => Hive::PlanReview::Policy.configuration_fingerprint(cfg)
      }
    )
    store.publish_current!(Hive::PlanReview::Record.new(common.merge(
      "kind" => "projection", "version" => 1, "candidate_plan_digest" => nil,
      "state" => "cleared", "outcome" => "cleared", "attempt_ids" => [],
      "current_attempt_id" => nil, "coverage" => [], "findings" => [],
      "decisions" => [], "routes" => [], "artifacts" => { "policy" => policy },
      "blockers" => [], "required_action" => nil,
      "degradation_reason" => nil, "execution_allowed" => true,
      "policy_reasons" => [],
      "level_sources" => { "computed" => "standard", "project" => "skip", "workflow" => "skip", "run" => nil },
      "retry_at" => nil, "updated_at" => "2026-10-30T12:00:00Z"
    )), expected_version: nil)
  end

  def test_initial_plan_invalid_list_gets_one_correction_prompt_with_hints_then_adopts
    with_project_env do |root|
      create_task(root, "f2-payments-261030-aaaa", stage: "9-done", id: 10)
      create_task(root, "f3-ledger-261030-bbbb", stage: "9-done", id: 11)
      task = create_task(root, "c5-root-261030-cccc", stage: "3-plan", id: 12)
      cfg = Hive::Config.load(root)

      prompts = []
      spawn_stub = lambda do |target, _cfg, prompt, _profile, **|
        prompts << prompt
        if prompts.length == 1
          File.write(target.state_file, "---\ndepends_on:\n  - F2\n  - F3\n---\n\n# Plan\n<!-- COMPLETE -->\n")
        else
          File.write(
            target.state_file,
            "---\ndepends_on:\n  - f2-payments-261030-aaaa\n  - f3-ledger-261030-bbbb\n---\n\n# Plan\n<!-- COMPLETE -->\n"
          )
        end
        { status: :ok }
      end

      stub_no_git_commit do
        with_replaced_singleton_method(Hive::Stages::Plan, :spawn_plan_agent, spawn_stub) do
          result = Hive::Stages::Plan.run!(task, cfg)

          assert_equal :complete, result[:status]
          assert_equal 2, prompts.length
          refute_includes prompts.first, "plan_dependency_diagnostic"
          assert_includes prompts.first, "full task slugs"
          assert_includes prompts.last, "plan_dependency_diagnostic"
          assert_includes prompts.last, "F2"
          assert_includes prompts.last, "F3"
          assert_includes prompts.last, "f2-payments-261030-aaaa"
          assert_includes prompts.last, "f3-ledger-261030-bbbb"
          assert_equal %w[f2-payments-261030-aaaa f3-ledger-261030-bbbb],
                       Hive::TaskMeta.read(task.folder)[:depends_on]
          refute Hive::PlanDependencyCorrection.initial_exhausted?(task.folder)
        end
      end
    end
  end

  def test_initial_plan_two_invalid_outputs_exhaust_and_block_subsequent_non_explicit_spawns
    with_project_env do |root|
      task = create_task(root, "c5-root-261030-cccc", stage: "3-plan", id: 12)
      cfg = Hive::Config.load(root)

      spawns = 0
      spawn_stub = lambda do |target, _cfg, _prompt, _profile, **|
        spawns += 1
        File.write(target.state_file, "---\ndepends_on:\n  - F2\n  - F3\n---\n\n# Plan\n<!-- COMPLETE -->\n")
        { status: :ok }
      end

      stub_no_git_commit do
        with_replaced_singleton_method(Hive::Stages::Plan, :spawn_plan_agent, spawn_stub) do
          result = Hive::Stages::Plan.run!(task, cfg)

          assert_equal :error, result[:status]
          assert_equal 2, spawns
          marker = Hive::Markers.current(task.state_file)
          assert_equal :error, marker.name
          assert_equal Hive::PlanDependencyCorrection::EXHAUSTED_REASON, marker.attrs["reason"]
          assert_includes marker.attrs["offending_ref"], "F2"
          assert_includes marker.attrs["message"], "hive plan c5-root-261030-cccc"
          assert_nil Hive::TaskMeta.read(task.folder)[:depends_on]
          assert Hive::PlanDependencyCorrection.initial_exhausted?(task.folder)
          assert Hive::Recovery.operator_owned_error?(marker.attrs)

          action = Hive::TaskAction.for(task, marker, config: cfg)
          assert_equal Hive::Schemas::TaskActionKind::ERROR, action.key
          assert_nil action.command

          # Simulate mtime bump / poll / restart: non-explicit Stages::Plan.run! spawns 0 times.
          FileUtils.touch(task.state_file, mtime: Time.now + 60)
          second = Hive::Stages::Plan.run!(task, cfg)
          assert_equal :error, second[:status]
          assert_equal 2, spawns
        end
      end
    end
  end

  def test_crash_after_correction_reservation_leaves_allowance_spent
    with_project_env do |root|
      task = create_task(root, "c5-root-261030-cccc", stage: "3-plan", id: 12)
      cfg = Hive::Config.load(root)
      Hive::TaskMeta.with_observation(task.folder) do |obs|
        assert Hive::PlanDependencyCorrection.reserve_initial_correction!(
          task.folder,
          observation: obs,
          invocation_id: "prior-inv",
          input_digest: "abc",
          diagnostic: { "reason_code" => "plan_dependency_invalid" }
        )
      end

      spawns = 0
      spawn_stub = lambda do |target, _cfg, _prompt, _profile, **|
        spawns += 1
        File.write(target.state_file, "---\ndepends_on: F2\n---\n\n# Plan\n<!-- COMPLETE -->\n")
        { status: :ok }
      end

      stub_no_git_commit do
        with_replaced_singleton_method(Hive::Stages::Plan, :spawn_plan_agent, spawn_stub) do
          result = Hive::Stages::Plan.run!(task, cfg)

          assert_equal :error, result[:status]
          assert_equal 1, spawns, "reserved allowance must not grant another correction after restart"
          assert Hive::PlanDependencyCorrection.initial_exhausted?(task.folder)
        end
      end
    end
  end

  def test_explicit_hive_plan_repairs_root_with_invalid_bytes_while_other_entries_still_refuse
    with_project_env do |root|
      create_task(root, "f2-payments-261030-aaaa", stage: "9-done", id: 10)
      root_task = create_task(
        root, "c5-root-261030-cccc", stage: "3-plan", id: 12,
        plan_content: "---\ndepends_on: F2\n---\n\n# Broken\n<!-- ERROR reason=plan_dependency_correction_exhausted -->\n"
      )
      child_task = create_task(
        root, "c6-child-261030-dddd", stage: "3-plan", id: 13,
        depends_on: "c5-root-261030-cccc",
        plan_content: "# Child\n<!-- WAITING -->\n"
      )
      Hive::TaskMeta.with_observation(root_task.folder) do |obs|
        Hive::PlanDependencyCorrection.mark_initial_exhausted!(
          root_task.folder, observation: obs, invocation_id: "old",
          input_digest: "deadbeef", diagnostic: { "reason_code" => "plan_dependency_invalid" }
        )
      end

      # 1. Generic `hive run` refuses root while invalid bytes remain on disk.
      assert_raises(Hive::DependencyAdmissionError) do
        Hive::Commands::Run.new(root_task.folder, project: "app", quiet: true).call
      end

      # 2. Automated daemon dispatch NEVER grants explicit plan-repair intent.
      old_env = ENV["HIVE_DAEMON_AUTOMATED_DISPATCH"]
      begin
        ENV["HIVE_DAEMON_AUTOMATED_DISPATCH"] = "1"
        assert_raises(Hive::DependencyAdmissionError) do
          Hive::Commands::StageAction.new(
            "plan", root_task.slug, project: "app", from: "3-plan", quiet: true
          ).call
        end
      ensure
        old_env.nil? ? ENV.delete("HIVE_DAEMON_AUTOMATED_DISPATCH") : ENV["HIVE_DAEMON_AUTOMATED_DISPATCH"] = old_env
      end

      # 3. Descendant running `hive plan <child> --project app --from 3-plan` STILL refuses.
      assert_raises(Hive::DependencyAdmissionError) do
        Hive::Commands::StageAction.new(
          "plan", child_task.slug, project: "app", from: "3-plan", quiet: true
        ).call
      end

      # 4. Forward approve / develop from 3-plan STILL refuses (plan review blocks clearance).
      approve_err = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::Commands::Approve.new(
          root_task.folder, to: "4-execute", from: "3-plan", project: "app", force: true, quiet: true
        ).call
      end
      assert_includes approve_err.message, "F2"
      assert_includes approve_err.message, "hive plan c5-root-261030-cccc --project app --from 3-plan"

      # 5. Real explicit `hive plan <root> --project app --from 3-plan` starts ONE new bounded
      # invocation, passes the existing diagnostic into attempt #1, allows 1 correction, and repairs!
      prompts = []
      spawn_stub = lambda do |target, _cfg, prompt, _profile, **|
        prompts << prompt
        if prompts.length == 1
          # Still invalid on attempt #1 -> exercises the single correction allowance
          File.write(target.state_file, "---\ndepends_on: missing-slug\n---\n\n# Attempt 1\n<!-- COMPLETE -->\n")
        else
          File.write(target.state_file, "---\ndepends_on: f2-payments-261030-aaaa\n---\n\n# Fixed\n<!-- COMPLETE -->\n")
        end
        { status: :ok }
      end

      stub_no_git_commit do
        with_replaced_singleton_method(Hive::Stages::Plan, :spawn_plan_agent, spawn_stub) do
          Hive::Commands::StageAction.new(
            "plan", root_task.slug, project: "app", from: "3-plan", quiet: true
          ).call
        end
      end

      assert_equal 2, prompts.length
      assert_includes prompts.first, "plan_dependency_diagnostic"
      assert_includes prompts.first, "F2"
      assert_includes prompts.first, "f2-payments-261030-aaaa"
      assert_includes prompts.last, "missing-slug"
      assert_equal "f2-payments-261030-aaaa", Hive::TaskMeta.read(root_task.folder)[:depends_on]
      assert_equal :complete, Hive::Markers.current(root_task.state_file).name
      refute Hive::PlanDependencyCorrection.initial_exhausted?(root_task.folder)
    end
  end

  def test_explicit_hive_plan_still_refuses_when_root_has_inherited_wait_or_unrelated_metadata_error
    with_project_env do |root|
      create_task(root, "upstream-261030-1111", stage: "2-brainstorm", id: 10)
      root_task = create_task(
        root, "c5-root-261030-cccc", stage: "3-plan", id: 12,
        depends_on: "upstream-261030-1111",
        plan_content: "---\ndepends_on: F2\n---\n\n# Broken plan with waiting prereq\n<!-- ERROR -->\n"
      )

      assert_raises(Hive::DependencyWaitError) do
        Hive::Commands::StageAction.new(
          "plan", root_task.slug, project: "app", from: "3-plan", quiet: true
        ).call
      end

      # Corrupt metadata is also never bypassed by explicit plan repair.
      File.write(root_task.meta_yml_path, ":\n  - [unclosed\n")
      assert_raises(Hive::DependencyAdmissionError) do
        Hive::Commands::StageAction.new(
          "plan", root_task.slug, project: "app", from: "3-plan", quiet: true
        ).call
      end
    end
  end

  def test_previously_cleared_invalid_plan_records_diagnostic_with_zero_spawns_and_unchanged_review
    with_project_env do |root|
      File.write(
        File.join(root, ".hive-state", "config.yml"),
        YAML.dump("plan_review" => { "enabled" => true }, "rebase" => { "enabled" => false })
      )
      task = create_task(
        root, "legacy-cleared-261030-eeee", stage: "3-plan", id: 20,
        plan_content: "---\ndepends_on:\n  - F2\n  - F3\n---\n\n# Legacy Cleared\n<!-- COMPLETE -->\n",
        plan_review_required: true
      )
      cfg = Hive::Config.load(root)
      publish_cleared_review(task, cfg)

      current_json_path = File.join(task.folder, "plan-review", "current.json")
      before_review_bytes = File.binread(current_json_path)
      before_plan_bytes = File.binread(task.state_file)
      before_meta_bytes = File.binread(task.meta_yml_path)

      spawns = 0
      spawn_stub = lambda do |*, **|
        spawns += 1
        { status: :ok }
      end

      with_replaced_singleton_method(Hive::Stages::Plan, :spawn_plan_agent, spawn_stub) do
        result = Hive::Stages::Plan.run!(task, cfg)

        assert_equal :error, result[:status]
        assert_nil result[:commit]
        assert_equal 0, spawns
        assert_equal before_review_bytes, File.binread(current_json_path)
        assert_equal before_plan_bytes, File.binread(task.state_file)
        assert_equal before_meta_bytes, File.binread(task.meta_yml_path)

        state = Hive::PlanDependencyCorrection.read(task.folder)
        assert_equal "plan_dependency_invalid",
                     state.dig("cleared_plan_diagnostic", "diagnostic", "reason_code")
      end
    end
  end

  def test_environmental_fault_spends_no_correction_and_does_not_exhaust
    with_project_env do |root|
      task = create_task(root, "cross-task-261030-ffff", stage: "3-plan", id: 25)
      cfg = Hive::Config.load(root)

      spawns = 0
      spawn_stub = lambda do |target, _cfg, _prompt, _profile, **|
        spawns += 1
        File.write(target.state_file, "---\ndepends_on: foreign:prereq-slug\n---\n\n# Plan\n<!-- COMPLETE -->\n")
        { status: :ok }
      end

      stub_no_git_commit do
        with_replaced_singleton_method(Hive::Stages::Plan, :spawn_plan_agent, spawn_stub) do
          result = Hive::Stages::Plan.run!(task, cfg)

          assert_equal :complete, result[:status]
          assert_equal 1, spawns
          assert_nil Hive::TaskMeta.read(task.folder)[:depends_on]
          refute File.exist?(Hive::PlanDependencyCorrection.path(task.folder))
        end
      end
    end
  end

  def test_post_clearance_metadata_drift_is_rejected_by_transition_guard_and_plan_approval
    with_project_env do |root|
      File.write(
        File.join(root, ".hive-state", "config.yml"),
        YAML.dump("plan_review" => { "enabled" => true }, "rebase" => { "enabled" => false })
      )
      create_task(root, "base-task", stage: "9-done", id: 10)
      create_task(root, "other-task", stage: "9-done", id: 11)
      task = create_task(
        root, "cleared-task", stage: "3-plan", id: 30,
        depends_on: "base-task",
        plan_content: "---\ndepends_on: base-task\n---\n\n# Plan\n<!-- WAITING -->\n",
        plan_review_required: true
      )
      cfg = Hive::Config.load(root)
      publish_cleared_review(task, cfg)

      # Mutate meta.yml after clearance. Because task_generation excludes depends_on,
      # freshness alone still reports "current", yet TransitionGuard and PlanApproval reject!
      Hive::TaskMeta.rewrite(task.folder, { depends_on: "other-task" })
      projection = Hive::PlanReview::Projection.load(task_folder: task.folder)
      assert_equal "current",
                   Hive::PlanReview::TransitionGuard.freshness(task:, projection:, config: cfg).fetch("status")

      guard_err = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.prepare_existing!(
          task: task, destination: "4-execute", config: cfg
        )
      end
      assert_includes guard_err.message, "plan_dependency_mismatch"

      approval_err = assert_raises(Hive::Daemon::PlanApproval::NotApprovable) do
        Hive::Daemon::PlanApproval.prepare("hive plan #{task.slug} --from 3-plan", task.state_file)
      end
      assert_includes approval_err.message, "plan_dependency_mismatch"
      assert_equal :waiting, Hive::Markers.current(task.state_file).name
    end
  end

  def test_task_action_and_dispatcher_treat_review_exhaustion_as_operator_owned_skip
    with_project_env do |root|
      File.write(
        File.join(root, ".hive-state", "config.yml"),
        YAML.dump("plan_review" => { "enabled" => true })
      )
      task = create_task(
        root, "exhausted-rev", stage: "3-plan", id: 31,
        plan_content: "# Plan\n<!-- WAITING -->\n",
        plan_review_required: true
      )
      cfg = Hive::Config.load(root)
      plan_review = {
        "state" => "blocked",
        "freshness" => { "status" => "current", "reason" => nil },
        "blockers" => [
          {
            "owner" => "operator",
            "reason" => Hive::PlanDependencyCorrection::EXHAUSTED_REASON,
            "diagnostic" => "invalid depends_on F2"
          }
        ],
        "routes" => [
          { "role" => "planner_revision", "attempt_id" => "att-1", "outcome" => "retryable_failure" }
        ],
        "required_action" => "repair invalid depends_on (F2) and rerun with `hive plan exhausted-rev --project app --from 3-plan`"
      }

      action = Hive::TaskAction.for(
        task, Hive::Markers.current(task.state_file),
        config: cfg, plan_review: plan_review
      )
      assert_equal Hive::Schemas::TaskActionKind::PLAN_REVIEW_BLOCKED, action.key
      assert_nil action.command

      row = Hive::Daemon::StatusConsumer::Row.new(
        project: "app", slug: "exhausted-rev", stage: "3-plan", workflow: "coding",
        marker: "waiting", marker_attrs: {}, action: action.key,
        suggested_command: nil, state_file_mtime: Time.now.utc,
        blocked: false, admission_error: nil, plan_review: plan_review
      )
      assert Hive::PlanDependencyCorrection.exhausted_row?(
        marker_attrs: row.marker_attrs, plan_review: row.plan_review
      )
      decision = Hive::Daemon::Policy.decide(
        action: row.action, stage: row.stage, workflow: row.workflow,
        command: row.suggested_command, state_file_mtime: row.state_file_mtime,
        last_dispatched_state_file_mtime: nil, now: Time.now.utc,
        admission_error: true, dependency_correction_exhausted: true
      )
      assert_equal :skip, decision
      disposition = Hive::Daemon::Policy.operational_disposition(
        decision, dependency_correction_exhausted: true
      )
      assert_equal "operator", disposition.fetch(:owner)
    end
  end
end
