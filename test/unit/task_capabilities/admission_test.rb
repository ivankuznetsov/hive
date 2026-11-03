require "test_helper"
require "hive/task_capabilities/admission"
require "hive/stages/base"

class TaskCapabilitiesAdmissionTest < Minitest::Test
  include HiveTestHelper
  def test_running_attempt_cannot_supply_operator_authorization
    with_replaced_singleton_method(Hive::Attempts::Context, :operator_context?, -> { true }) do
      error = assert_raises(Hive::TaskCapabilities::Admission::Error) do
        Hive::TaskCapabilities::Admission.authorize_operator!
      end
      assert_equal "task_capability_operator_required", error.reason
    end
  end
end

class TaskCapabilitiesAdmissionTest
  def with_plan(blockers: [])
    with_tmp_dir do |root|
      prepare_test_runtime_project(root)
      folder = File.join(root, ".hive-state/stages/1-inbox/task")
      task_id = Hive::TaskCounter.next_or_nil
      catalog = Hive::TaskCapabilities::Catalog.new(workflow: Hive::Workflows::Coding::DESCRIPTOR)
      data = Hive::TaskCapabilities::Plan.minimal(task_identity: { "id" => task_id.to_s, "slug" => "task", "workflow" => "coding" }, catalog: catalog, policy: {}, source: {}).to_h.merge("blockers" => blockers)
      plan = Hive::TaskCapabilities::Plan.new(data)
      Hive::TaskMeta.write(folder, id: task_id, slug: "task", display_name: nil, workflow: "coding", task_capabilities: plan.adoption)
      Hive::TaskCapabilities::Store.new(folder).activate(plan, expected_version: nil)
      yield Struct.new(:folder).new(folder), plan
    end
  end

  def test_accepted_dispatch_blockers_reject_and_unavailable_approved_route_does_not
    with_plan(blockers: [ { "reason" => "task_capability_approval_required", "message" => "obtain approval", "phase" => "dispatch" } ]) do |task, _plan|
      error = assert_raises(Hive::TaskCapabilities::Admission::Error) { Hive::TaskCapabilities::Admission.enforce!(task) }
      assert_equal "task_capability_approval_required", error.reason
      assert_equal "obtain approval", error.message
      assert_equal Hive::ExitCodes::USAGE, error.exit_code
    end
    with_plan(blockers: [ { "reason" => "task_capability_route_unavailable", "message" => "restore approved route", "phase" => "finalization" } ]) do |task, _plan|
      assert Hive::TaskCapabilities::Admission.enforce!(task)
    end
    with_plan(blockers: [ { "reason" => "future-unrecognized-reason", "message" => "blocked" } ]) do |task, _plan|
      error = assert_raises(Hive::TaskCapabilities::Admission::Error) { Hive::TaskCapabilities::Admission.enforce!(task) }
      assert_equal "task_capability_blocked", error.reason
    end
    with_tmp_dir do |folder|
      assert Hive::TaskCapabilities::Admission.enforce!(Struct.new(:folder).new(folder))
    end
    assert Hive::TaskCapabilities::Admission.enforce!(Object.new)
    assert Hive::TaskCapabilities::Admission.authorize_operator!
  end

  def test_selected_skill_must_retain_its_verified_identity
    with_tmp_dir do |root|
      path = File.join(root, ".claude/skills/fixture/SKILL.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# Installed fixture\n")
      binding = { "id" => "ui", "skill" => "fixture", "actor" => { "profile" => "claude", "provider" => "anthropic", "model" => "model" } }
      identity = Hive::TaskCapabilities::Admission.skill_identity(binding, project_root: root, cfg: {})
      binding["skill_identity"] = identity
      assert_equal "/fixture", Hive::TaskCapabilities::Admission.verify_skill_binding!(binding, project_root: root, cfg: {})
      File.write(path, "# Changed fixture\n")
      assert_raises(Hive::TaskCapabilities::Admission::Error) { Hive::TaskCapabilities::Admission.verify_skill_binding!(binding, project_root: root, cfg: {}) }
      assert_raises(Hive::TaskCapabilities::Admission::Error) { Hive::TaskCapabilities::Admission.skill_identity({ "id" => "ui" }, project_root: root, cfg: {}) }
      File.unlink(path)
      assert_raises(Hive::TaskCapabilities::Admission::Error) { Hive::TaskCapabilities::Admission.skill_identity(binding, project_root: root, cfg: {}) }
    end
  end

  def test_direct_stage_spawn_cannot_bypass_admission
    with_plan(blockers: [ { "reason" => "task_capability_approval_required", "message" => "obtain approval", "phase" => "dispatch" } ]) do |task, _plan|
      assert_raises(Hive::TaskCapabilities::Admission::Error) do
        Hive::Stages::Base.spawn_agent(task, prompt: "must not launch", max_budget_usd: 1, timeout_sec: 1)
      end
      assert_raises(Hive::TaskCapabilities::Admission::Error) do
        Hive::Stages::Base.with_stage_events(task) { flunk "stage body ran" }
      end
    end
  end
end
