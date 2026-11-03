require "test_helper"
require "hive/stages/plan"
require "hive/stages/execute"
require "hive/task_capabilities/resolver"

class TaskCapabilityGuidanceTest < Minitest::Test
  include HiveTestHelper

  TaskStub = Struct.new(:project_root, :folder, :state_file, keyword_init: true)

  def with_guidance(stages: %w[plan execute], actor: nil, instruction: false, definition_options: {})
    with_tmp_dir do |root|
      prepare_test_runtime_project(root)
      task_id = Hive::TaskCounter.next_or_nil
      folder = File.join(root, ".hive-state/stages/3-plan/task")
      skill = File.join(root, ".claude/skills/ui-fixture/SKILL.md")
      FileUtils.mkdir_p(File.dirname(skill))
      File.write(skill, "# Pinned UI guidance\n")
      cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
      cfg["agents"]["claude"]["bin"] = "ruby"
      cfg["plan"].merge!("model" => "approved", "effort" => "high")
      cfg["execute"].merge!("model" => "approved", "effort" => "high")
      definition = { "id" => "presentation", "kind" => "guidance", "stages" => stages,
        "actor" => actor || { "profile" => "claude", "provider" => "anthropic", "model" => "approved", "effort" => "high" } }.merge(definition_options)
      if instruction
        File.write(File.join(root, "guidance.md"), "Preserve keyboard navigation.\n")
        definition["instruction"] = File.join(root, "guidance.md")
      else
        definition["skill"] = "ui-fixture"
      end
      cfg["task_capabilities"]["catalog"] = [ definition ]
      resolution = Hive::TaskCapabilities::Resolver.new(workflow: Hive::Workflows::Coding::DESCRIPTOR,
        cfg: cfg, project_root: root).resolve(task_identity: { "id" => task_id.to_s, "slug" => "task", "workflow" => "coding" },
          selections: [ "qa=off", "presentation=on" ], qa_waiver_reason: "fixture", qa_waiver_checks: [ "all" ])
      plan = resolution.plan
      Hive::TaskMeta.write(folder, id: task_id, slug: "task", display_name: nil, workflow: "coding", task_capabilities: plan.adoption)
      Hive::TaskCapabilities::Store.new(folder).activate(plan, expected_version: nil)
      File.write(File.join(folder, "brainstorm.md"), "Add an accessible screen.\n")
      File.write(File.join(folder, "plan.md"), "Implement the accessible screen.\n")
      task = TaskStub.new(project_root: root, folder: folder, state_file: File.join(folder, "plan.md"))
      yield task, cfg, plan, skill
    end
  end

  def guidance(task, cfg, stage: "plan", **options)
    profile = Hive::Stages::Base.stage_profile(cfg, stage)
    launch = Hive::Stages::Base.model_launch_arguments(cfg, stage == "execute" ? "execute_implementation" : stage,
      profile, current: Hive::Stages::Base.model_routing_current(cfg[stage]))
    Hive::Stages::Base.task_capability_guidance(task, cfg, stage: stage,
      profile: profile, launch_arguments: launch, **options)
  end

  def test_matching_executor_receives_verified_pinned_guidance_on_plan_and_execute
    with_guidance do |task, cfg, plan, _skill|
      captured = []
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |agent_task, **kwargs|
        captured << kwargs
        File.write(agent_task.state_file, "<!-- WAITING -->\n")
        { status: :ok }
      }) do
        Hive::Stages::Plan.run_with_source!(task, cfg, nil, observation: nil)
        Hive::Stages::Execute.spawn_implementation(task, cfg, task.project_root)
      end
      assert_equal 2, captured.length
      captured.each do |spawn|
        assert_includes spawn.fetch(:prompt), "/ui-fixture"
        assert_includes spawn.fetch(:prompt), plan.digest
        assert_includes spawn.fetch(:prompt), "presentation"
        assert_equal [ "--model", "approved", "--effort", "high" ], spawn.fetch(:identity_arguments)
      end
    end
  end

  def test_missing_or_changed_skill_blocks_before_launch_and_retry_keeps_accepted_binding
    with_guidance do |task, cfg, plan, skill|
      original = File.binread(skill)
      first, = guidance(task, cfg)
      cfg["task_capabilities"]["catalog"].clear
      second, = guidance(task, cfg)
      assert_equal first, second
      assert_includes first, plan.digest
      File.write(skill, "# Changed skill\n")
      assert_raises(Hive::TaskCapabilities::Admission::Error) { guidance(task, cfg) }
      File.unlink(skill)
      assert_raises(Hive::TaskCapabilities::Admission::Error) { guidance(task, cfg) }
      File.write(skill, original)
      assert_equal first, guidance(task, cfg).first
    end
  end

  def test_other_profile_provider_model_or_effort_requires_a_specialist
    [ { "profile" => "codex", "provider" => "openai", "model" => "approved" },
      { "profile" => "claude", "provider" => "unapproved", "model" => "approved", "effort" => "high" },
      { "profile" => "claude", "provider" => "anthropic", "model" => "other", "effort" => "high" },
      { "profile" => "claude", "provider" => "anthropic", "model" => "approved", "effort" => "low" } ].each do |actor|
      with_guidance(actor: actor, instruction: true) do |task, cfg|
        error = assert_raises(Hive::TaskCapabilities::Admission::Error) { guidance(task, cfg) }
        assert_match(/specialist|route unavailable/, error.message)
      end
    end
  end

  def test_specialist_contribution_is_bounded_in_the_existing_plan_prompt_and_keeps_primary_identity
    actor = { "profile" => "claude", "provider" => "anthropic", "model" => "specialist", "effort" => "high" }
    with_guidance(actor: actor, instruction: true) do |task, cfg, plan|
      context = Hive::Attempts::Context.send(:new, attempt_id: "parent", task_generation: 0)
      calls = []
      specialist = Object.new
      specialist.define_singleton_method(:run) do |binding, prompt:|
        calls << [ binding, prompt ]
        { status: :ok, final_message: "Label the controls. " * 1_000 }
      end
      captured = []
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        with_replaced_singleton_method(Hive::TaskCapabilities::ActorRunner, :new, ->(**) { specialist }) do
          with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, ->(_task, **kwargs) { captured << kwargs; { status: :ok } }) do
            Hive::Stages::Plan.run_with_source!(task, cfg, nil, observation: nil)
          end
        end
      end
      assert_equal 1, calls.size
      assert_equal actor, calls.first.first.fetch("actor")
      assert_includes calls.first.last, "Preserve keyboard navigation."
      assert_equal 1, captured.size
      primary = captured.first
      assert_includes primary.fetch(:prompt), "specialist contribution"
      assert_includes primary.fetch(:prompt), plan.digest
      assert_operator primary.fetch(:prompt).scan("Label the controls.").size, :<=, 432
      assert_equal [ "--model", "approved", "--effort", "high" ], primary.fetch(:identity_arguments)
      assert_instance_of Hive::TaskCapabilities::ActorRunner::Session, primary.fetch(:capability_session)
    ensure
      context&.close
    end
  end

  def test_runtime_fingerprint_drift_is_not_a_matching_executor
    with_guidance do |task, cfg|
      cfg["agents"]["claude"]["bin"] = "different-runtime"
      error = assert_raises(Hive::TaskCapabilities::Admission::Error) { guidance(task, cfg) }
      assert_match(/runtime.*changed/, error.message)
    end
  end

  def test_missing_skill_prevents_both_stage_launches
    with_guidance do |task, cfg, _plan, skill|
      File.unlink(skill)
      before = File.binread(task.state_file)
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, ->(*) { flunk "agent launched" }) do
        assert_raises(Hive::TaskCapabilities::Admission::Error) do
          Hive::Stages::Plan.run_with_source!(task, cfg, nil, observation: nil)
        end
        assert_raises(Hive::TaskCapabilities::Admission::Error) do
          Hive::Stages::Execute.spawn_implementation(task, cfg, task.project_root)
        end
      end
      assert_equal before, File.binread(task.state_file)
    end
  end

  def test_primary_spawn_cannot_exceed_the_selected_resource_or_permission_envelope
    with_guidance do |task, cfg|
      budget = cfg.dig("budget_usd", "plan")
      cfg["budget_usd"]["plan"] = budget + 1
      assert_raises(Hive::TaskCapabilities::Admission::Error) { guidance(task, cfg) }
      cfg["budget_usd"]["plan"] = nil
      assert_raises(Hive::TaskCapabilities::Admission::Error) { guidance(task, cfg) }
      cfg["budget_usd"]["plan"] = budget
      cfg["timeout_sec"]["plan"] += 1
      assert_raises(Hive::TaskCapabilities::Admission::Error) { guidance(task, cfg) }
    end
    with_guidance(definition_options: { "permissions" => "read-only" }) do |task, cfg|
      assert_raises(Hive::TaskCapabilities::Admission::Error) { guidance(task, cfg) }
      cfg["plan"]["permissions"] = { "preset" => "scoped", "tools" => [ "Read" ] }
      assert_includes guidance(task, cfg).first, "/ui-fixture"
      cfg["plan"]["permissions"]["tools"] << "Edit"
      assert_raises(Hive::TaskCapabilities::Admission::Error) { guidance(task, cfg) }
    end
    with_guidance(definition_options: { "targets" => [ "fixtures/local" ] }) do |task, cfg|
      assert_raises(Hive::TaskCapabilities::Admission::Error) { guidance(task, cfg) }
    end
    with_guidance(definition_options: { "permissions" => { "tools" => [ "Read" ], "directories" => [], "domains" => [] } }) do |task, cfg|
      assert_raises(Hive::TaskCapabilities::Admission::Error) { guidance(task, cfg) }
    end
  end

  def test_pinned_instruction_is_read_from_the_plan_snapshot
    with_guidance(instruction: true) do |task, cfg, _plan|
      File.unlink(File.join(task.project_root, "guidance.md"))
      assert_includes guidance(task, cfg).first, "Preserve keyboard navigation."
    end
  end

  def test_schema_valid_binding_with_wrong_instruction_digest_is_not_executed
    with_guidance(instruction: true) do |task, cfg, plan|
      bindings = Marshal.load(Marshal.dump(plan.data.fetch("bindings")))
      bindings.first["instruction_content"] = "Unaccepted replacement."
      revised = Hive::TaskCapabilities::Plan.new(plan.to_h.merge("version" => 2, "bindings" => bindings))
      Hive::TaskCapabilities::Store.new(task.folder).activate(revised, expected_version: 1)
      error = assert_raises(Hive::TaskCapabilities::Admission::Error) { guidance(task, cfg) }
      assert_match(/instruction identity/, error.message)
    end
  end

  def test_outer_account_route_cannot_be_borrowed_by_an_attachment
    with_guidance do |task, cfg|
      profile = Hive::Stages::Base.stage_profile(cfg, "plan")
      context = Hive::Attempts::Context.send(:new, attempt_id: "unadmitted-parent", task_generation: 0,
        routing: { "mode" => "explicit", "route" => { "adapter" => "claude", "model" => "approved", "effort" => "high" } })
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        error = assert_raises(Hive::TaskCapabilities::Admission::Error) do
          Hive::Stages::Base.task_capability_guidance(task, cfg, stage: "plan", profile: profile,
            launch_arguments: { model: "approved", effort: "high" })
        end
        assert_match(/parent attempt/, error.message)
      end
    ensure
      context&.close
    end
  end

  def test_routed_model_is_verified_and_keeps_its_typed_route
    with_guidance do |task, cfg|
      cfg["models"] = { "plan" => { "model" => "approved", "effort" => "high" } }
      _text, launch = guidance(task, cfg)
      assert_equal "approved", launch.fetch(:routing_arguments).model
      assert_equal "high", launch.fetch(:routing_arguments).effort
    end
  end

  def test_provider_native_default_is_pinned_or_blocks_when_unavailable
    with_guidance do |task, cfg|
      cfg["plan"].delete("model")
      cfg["claude"]["model"] = "inherit"
      File.write(File.join(task.project_root, ".claude/settings.json"), JSON.generate("model" => "approved"))
      _text, launch = guidance(task, cfg)
      assert_equal [ "--model", "approved", "--effort", "high" ], launch.fetch(:identity_arguments)
      File.unlink(File.join(task.project_root, ".claude/settings.json"))
      error = assert_raises(Hive::TaskCapabilities::Admission::Error) { guidance(task, cfg) }
      assert_match(/exact matching/, error.message)
    end
  end

  def test_unconsumed_guidance_attachment_is_a_durable_dispatch_blocker
    with_guidance(stages: [ "inbox" ]) do |task, _cfg, plan|
      assert plan.data.fetch("blockers").any? { |blocker| blocker["message"].include?("inbox") }
      assert_raises(Hive::TaskCapabilities::Admission::Error) { Hive::TaskCapabilities::Admission.enforce!(task) }
    end
  end

  def test_same_named_generic_runner_cannot_silently_drop_guidance
    stages = Hive::Workflows::Coding::DESCRIPTOR.stages.map do |stage|
      stage.name == "plan" ? stage.with(runner: nil) : stage
    end
    workflow = Hive::Workflow.new(id: :coding, stages: stages, task_capabilities: [])
    refute Hive::TaskCapabilities::Admission.guidance_stage_supported?(workflow, "plan")
    cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
    cfg["task_capabilities"]["catalog"] = [ { "id" => "presentation", "kind" => "guidance", "stages" => [ "plan" ] } ]
    preview = Hive::TaskCapabilities::Resolver.new(workflow: workflow, cfg: cfg).preview(selections: [ "qa=off", "presentation=on" ],
      qa_waiver_reason: "fixture", qa_waiver_checks: [ "all" ])
    assert preview.fetch("blockers").any? { |blocker| blocker["message"].include?("no execution attachment at plan") }
    with_guidance do |task, _cfg|
      task.define_singleton_method(:workflow) { workflow }
      assert_raises(Hive::TaskCapabilities::Admission::Error) { Hive::TaskCapabilities::Admission.enforce!(task) }
    end
  end
end

class TaskCapabilityGuidanceTest
  def test_specialist_rejects_a_changed_pinned_instruction_before_launch
    actor = { "profile" => "claude", "provider" => "anthropic", "model" => "specialist" }
    with_guidance(actor: actor, instruction: true) do |task, cfg, plan|
      bindings = Marshal.load(Marshal.dump(plan.data.fetch("bindings")))
      bindings.first["instruction_content"] = "Unaccepted specialist instructions."
      revised = Hive::TaskCapabilities::Plan.new(plan.to_h.merge("version" => 2, "bindings" => bindings))
      Hive::TaskCapabilities::Store.new(task.folder).activate(revised, expected_version: 1)
      context = Hive::Attempts::Context.send(:new, attempt_id: "parent", task_generation: 0)
      specialist = Object.new
      test = self
      specialist.define_singleton_method(:run) { |*| test.flunk "changed instruction reached launcher" }
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        with_replaced_singleton_method(Hive::TaskCapabilities::ActorRunner, :new, ->(**) { specialist }) do
          error = assert_raises(Hive::TaskCapabilities::Admission::Error) { guidance(task, cfg) }
          assert_includes error.message, "instruction identity changed"
        end
      end
    ensure
      context&.close
    end
  end

  def test_specialist_skill_body_is_hashed_after_read_before_it_enters_the_prompt
    actor = { "profile" => "claude", "provider" => "anthropic", "model" => "specialist" }
    with_guidance(actor: actor) do |task, cfg, _plan, skill|
      context = Hive::Attempts::Context.send(:new, attempt_id: "parent", task_generation: 0)
      original = File.method(:binread)
      changed_read = ->(path, *args) { path == skill ? "Changed after verification" : original.call(path, *args) }
      specialist = Object.new
      test = self
      specialist.define_singleton_method(:run) { |*| test.flunk "changed skill body reached launcher" }
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        with_replaced_singleton_method(Hive::TaskCapabilities::ActorRunner, :new, ->(**) { specialist }) do
          with_replaced_singleton_method(File, :binread, changed_read) do
            error = assert_raises(Hive::TaskCapabilities::Admission::Error) { guidance(task, cfg) }
            assert_equal "task_capability_missing_skill", error.reason
          end
        end
      end
    ensure
      context&.close
    end
  end
end

class TaskCapabilityGuidanceTest
  def test_verified_specialist_skill_and_failure_are_consumed_without_changing_primary_model
    actor = { "profile" => "claude", "provider" => "anthropic", "model" => "specialist" }
    with_guidance(actor: actor) do |task, cfg|
      context = Hive::Attempts::Context.send(:new, attempt_id: "parent", task_generation: 0)
      prompts = []
      result = { status: :ok, final_message: "Use native labelled controls." }
      specialist = Object.new
      specialist.define_singleton_method(:run) { |_binding, prompt:| prompts << prompt; result }
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        with_replaced_singleton_method(Hive::TaskCapabilities::ActorRunner, :new, ->(**) { specialist }) do
          text, arguments = guidance(task, cfg)
          assert_includes prompts.first, "# Pinned UI guidance"
          assert_includes text, "Use native labelled controls."
          assert_equal [ "--model", "approved", "--effort", "high" ], arguments.fetch(:identity_arguments)
          result.replace(status: :error, error_reason: "provider_route_preflight_failed")
          error = assert_raises(Hive::TaskCapabilities::Admission::Error) { guidance(task, cfg) }
          assert_includes error.message, "did not produce verified guidance"
        end
      end
    ensure
      context&.close
    end
  end
end
