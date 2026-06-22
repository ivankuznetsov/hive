require "test_helper"
require "hive/markers"
require "hive/stages/agent"

class StagesAgentTest < Minitest::Test
  include HiveTestHelper

  TaskStub = Struct.new(
    :project_root, :folder, :state_file, :stage_name, :slug,
    :stage_index, :log_dir, :project_name, :workflow,
    keyword_init: true
  )

  RaisingProfile = Struct.new(:name, keyword_init: true) do
    def format_skill_invocation(_skill)
      raise "format_skill_invocation should not be called"
    end
  end

  def task_for(project, stage_name, descriptor: Hive::Workflows::Registry.default)
    stage = descriptor.stage_named(stage_name)
    output_file = stage.state_file
    folder = File.join(project, ".hive-state", "stages", stage.dir, "demo-260619-aaaa")
    FileUtils.mkdir_p(folder)
    TaskStub.new(
      project_root: project,
      folder: folder,
      state_file: File.join(folder, output_file),
      stage_name: stage_name,
      slug: "demo-260619-aaaa",
      stage_index: 99,
      log_dir: File.join(project, ".hive-state", "logs", "demo-260619-aaaa"),
      project_name: File.basename(project),
      workflow: descriptor
    )
  end

  def with_stubbed_spawn(marker: "<!-- COMPLETE -->\n")
    captured = []
    original = Hive::Stages::Base.method(:spawn_agent)
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |task, prompt:, **kwargs|
      captured << { task: task, prompt: prompt, kwargs: kwargs }
      File.write(task.state_file, marker)
      { status: :ok }
    end
    yield captured
  ensure
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |*args, **kwargs, &block|
      original.call(*args, **kwargs, &block)
    end
  end

  def with_fixed_user_supplied_tag(tag = "user_supplied_testtag")
    original = Hive::Stages::Base.method(:user_supplied_tag)
    Hive::Stages::Base.define_singleton_method(:user_supplied_tag) { tag }
    yield tag
  ensure
    Hive::Stages::Base.define_singleton_method(:user_supplied_tag, original)
  end

  def test_prompt_wraps_prior_artifacts_and_excludes_own_output
    with_tmp_dir do |project|
      task = task_for(project, "plan")
      File.write(File.join(task.folder, "idea.md"), "seed idea\n")
      File.write(File.join(task.folder, "brainstorm.md"), "requirements\n")
      File.write(File.join(task.folder, "plan.md"), "old plan\n")

      with_fixed_user_supplied_tag do |tag|
        with_stubbed_spawn do |captured|
          Hive::Stages::Agent.run!(task, { "plan" => { "agent" => "codex" } })

          prompt = captured.first.fetch(:prompt)
          assert_includes prompt, "<#{tag} content_type=\"prior_artifacts\">"
          assert_includes prompt, "</#{tag}>"
          assert_includes prompt, "## brainstorm.md\nrequirements"
          assert_includes prompt, "## idea.md\nseed idea"
          # Prior artifacts are joined in sorted-basename order, so brainstorm.md must
          # precede idea.md. Asserting relative position (not just presence) is what
          # catches a dropped `.sort` in prior_artifacts.
          assert prompt.index("## brainstorm.md") < prompt.index("## idea.md"),
                 "prior artifacts must be ordered by sorted basename (brainstorm before idea)"
          refute_includes prompt, "## plan.md"
          refute_includes prompt, "old plan"
        end
      end
    end
  end

  def test_prior_artifacts_capped_at_8000_chars
    with_tmp_dir do |project|
      task = task_for(project, "plan")
      File.write(File.join(task.folder, "huge.md"), "x" * 20_000)

      prior = Hive::Stages::Agent.prior_artifacts(task, "plan.md")

      assert_equal 8000, prior.length,
                   "prior_artifacts must cap the joined string at 8000 chars"
    end
  end

  def test_prior_artifacts_cap_applies_to_joined_multi_file_string
    with_tmp_dir do |project|
      task = task_for(project, "plan")
      # Two under-cap files whose joined length (headers + 5k + 5k + separator)
      # exceeds 8000: proves the cap is on the joined string, not per file.
      File.write(File.join(task.folder, "a.md"), "a" * 5000)
      File.write(File.join(task.folder, "b.md"), "b" * 5000)

      prior = Hive::Stages::Agent.prior_artifacts(task, "plan.md")

      assert_equal 8000, prior.length,
                   "the 8000-char cap must apply to the joined multi-file string, not per file"
      assert prior.start_with?("## a.md\n"),
             "the joined string must begin with the first sorted file before truncation"
    end
  end

  def test_prior_artifacts_degrades_unreadable_sibling
    with_tmp_dir do |project|
      task = task_for(project, "plan")
      path = File.join(task.folder, "gone.md")
      File.write(path, "vanishing")
      original = File.method(:read)

      with_replaced_singleton_method(File, :read, lambda { |candidate, *args, **kwargs|
        raise Errno::ENOENT, "gone" if candidate == path

        original.call(candidate, *args, **kwargs)
      }) do
        prior = Hive::Stages::Agent.prior_artifacts(task, "plan.md")
        assert_includes prior, "## gone.md\n(unreadable: Errno::ENOENT)"
      end
    end
  end

  def test_run_raises_stage_error_when_stage_absent_from_registry
    with_tmp_dir do |project|
      folder = File.join(project, ".hive-state", "stages", "99-mystery", "demo-260619-aaaa")
      FileUtils.mkdir_p(folder)
      task = TaskStub.new(
        project_root: project,
        folder: folder,
        state_file: File.join(folder, "mystery.md"),
        stage_name: "mystery",
        slug: "demo-260619-aaaa",
        stage_index: 99,
        log_dir: File.join(project, ".hive-state", "logs", "demo-260619-aaaa"),
        project_name: File.basename(project),
        workflow: Hive::Workflows::Registry.default
      )

      error = assert_raises(Hive::StageError) do
        Hive::Stages::Agent.run!(task, {})
      end

      assert_equal "no agent stage mystery", error.message
    end
  end

  def test_empty_prior_artifacts_render_without_error
    with_tmp_dir do |project|
      task = task_for(project, "plan")

      with_fixed_user_supplied_tag do |tag|
        with_stubbed_spawn do |captured|
          Hive::Stages::Agent.run!(task, { "plan" => { "agent" => "codex" } })

          prompt = captured.first.fetch(:prompt)
          assert_includes prompt, "<#{tag} content_type=\"prior_artifacts\">\n\n</#{tag}>"
        end
      end
    end
  end

  def test_skill_present_uses_profile_formatted_invocation
    with_tmp_dir do |project|
      task = task_for(project, "brainstorm")

      with_stubbed_spawn do |captured|
        Hive::Stages::Agent.run!(task, { "brainstorm" => { "agent" => "pi" } })

        assert_includes captured.first.fetch(:prompt), "Use the /skill:ce-brainstorm skill"
        assert_equal :pi, captured.first.fetch(:kwargs).fetch(:profile).name
      end
    end
  end

  def test_skill_absent_uses_generic_instruction_without_formatting
    with_tmp_dir do |project|
      task = task_for(project, "plan")
      profile = RaisingProfile.new(name: :no_skill)

      with_replaced_singleton_method(Hive::Stages::Base, :stage_profile, ->(_cfg, _stage_name) { profile }) do
        with_stubbed_spawn do |captured|
          Hive::Stages::Agent.run!(task, {})

          assert_includes captured.first.fetch(:prompt), "Write `plan.md` - produce the best `plan` you can."
          assert_same profile, captured.first.fetch(:kwargs).fetch(:profile)
        end
      end
    end
  end

  def test_instruction_backed_stage_uses_instruction_body_without_skill_or_generic_fallback
    with_tmp_dir do |project|
      instruction_path = File.join(project, "workflow-work.md")
      File.write(instruction_path, "Write a concise implementation note.\n")
      descriptor = instruction_workflow(instruction_path)
      task = task_for(project, "work", descriptor: descriptor)
      File.write(File.join(task.folder, "idea.md"), "prior idea\n")

      with_stubbed_spawn do |captured|
        Hive::Stages::Agent.run!(task, {})

        prompt = captured.first.fetch(:prompt)
        assert_includes prompt, "Write a concise implementation note."
        assert_includes prompt, "## idea.md\nprior idea"
        refute_includes prompt, "Use the"
        refute_includes prompt, "produce the best `work`"
      end
    end
  end

  def test_descriptor_permissions_override_config_permission_spec
    with_tmp_dir do |project|
      instruction_path = File.join(project, "workflow-work.md")
      File.write(instruction_path, "Do scoped work.\n")
      descriptor = instruction_workflow(instruction_path, permissions: "read-only")
      task = task_for(project, "work", descriptor: descriptor)

      with_stubbed_spawn do |captured|
        Hive::Stages::Agent.run!(task, { "permissions" => "yolo" })

        kwargs = captured.first.fetch(:kwargs)
        assert_equal "default", kwargs.fetch(:permission_mode)
        assert_equal %w[Read LS Grep Glob], kwargs.fetch(:allowed_tools)
        assert_equal %w[Write Edit MultiEdit NotebookEdit Bash], kwargs.fetch(:disallowed_tools)
      end
    end
  end

  def test_descriptor_permissions_fail_closed_when_runner_cannot_enforce_scope
    with_tmp_dir do |project|
      instruction_path = File.join(project, "workflow-work.md")
      File.write(instruction_path, "Do scoped work.\n")
      descriptor = instruction_workflow(instruction_path, permissions: "read-only")
      task = task_for(project, "work", descriptor: descriptor)

      error = assert_raises(Hive::ConfigError) do
        Hive::Stages::Agent.run!(task, { "work" => { "agent" => "codex" } })
      end

      marker = Hive::Markers.current(task.state_file)
      assert_match(/cannot enforce tool scoping/, error.message)
      assert_equal :error, marker.name
      assert_equal "permission_config_error", marker.attrs.fetch("reason")
    end
  end

  def test_spawn_uses_task_folder_state_marker_mode_cfg_and_descriptor_defaults
    with_tmp_dir do |project|
      task = task_for(project, "brainstorm")

      with_stubbed_spawn do |captured|
        cfg = { "brainstorm" => { "agent" => "codex" } }
        Hive::Stages::Agent.run!(task, cfg)

        kwargs = captured.first.fetch(:kwargs)
        assert_equal [ task.folder ], kwargs.fetch(:add_dirs)
        assert_equal task.folder, kwargs.fetch(:cwd)
        assert_equal :state_file_marker, kwargs.fetch(:status_mode)
        assert_same cfg, kwargs.fetch(:cfg)
        assert_equal 50, kwargs.fetch(:max_budget_usd)
        assert_equal 1800, kwargs.fetch(:timeout_sec)
        assert_equal "brainstorm", kwargs.fetch(:log_label)
      end
    end
  end

  def test_spawn_uses_plan_descriptor_budget_and_timeout_defaults
    with_tmp_dir do |project|
      task = task_for(project, "plan")

      with_stubbed_spawn do |captured|
        Hive::Stages::Agent.run!(task, { "plan" => { "agent" => "codex" } })

        kwargs = captured.first.fetch(:kwargs)
        assert_equal 100, kwargs.fetch(:max_budget_usd),
                     "plan must fall back to its descriptor budget_usd (100)"
        assert_equal 3600, kwargs.fetch(:timeout_sec),
                     "plan must fall back to its descriptor timeout_sec (3600)"
      end
    end
  end

  def test_spawn_uses_task_workflow_descriptor_for_generic_stage
    with_tmp_dir do |project|
      descriptor = dispatch_workflow
      task = task_for(project, "gather", descriptor: descriptor)

      with_stubbed_spawn do |captured|
        Hive::Stages::Agent.run!(task, {})

        kwargs = captured.first.fetch(:kwargs)
        assert_equal 1.0, kwargs.fetch(:max_budget_usd)
        assert_equal 60, kwargs.fetch(:timeout_sec)
        assert_equal "gather", kwargs.fetch(:log_label)
        assert_equal File.join(task.folder, "gather.md"), task.state_file
      end
    end
  end

  def test_spawn_honors_cfg_budget_and_timeout_overrides
    with_tmp_dir do |project|
      task = task_for(project, "brainstorm")

      with_stubbed_spawn do |captured|
        cfg = {
          "brainstorm" => { "agent" => "codex" },
          "budget_usd" => { "brainstorm" => 12 },
          "timeout_sec" => { "brainstorm" => 34 }
        }
        Hive::Stages::Agent.run!(task, cfg)

        kwargs = captured.first.fetch(:kwargs)
        assert_equal 12, kwargs.fetch(:max_budget_usd)
        assert_equal 34, kwargs.fetch(:timeout_sec)
      end
    end
  end

  def test_run_accepts_nil_cfg
    # Exercises the `cfg ||= {}` guard in `run!`: a nil cfg must be coerced to
    # {} and run identically to an empty config.
    with_tmp_dir do |project|
      task = task_for(project, "plan")

      with_stubbed_spawn do
        assert_equal(
          { commit: "complete", status: :complete },
          Hive::Stages::Agent.run!(task, nil),
          "nil cfg must be coerced to {} and run like an empty config"
        )
      end
    end
  end

  def test_run_stamps_error_marker_when_descriptor_instruction_unreadable
    # A descriptor instruction can be renamed/deleted/chmod'd between parse and
    # run (a normal authoring edit). The stage's OWN instruction going missing is
    # fatal, so the runner must stamp an attributed :error marker and stop —
    # never die with a raw Errno or silently re-classify the row as ready_to_run.
    with_tmp_dir do |project|
      instruction_path = File.join(project, "workflow-work.md")
      File.write(instruction_path, "Do the work.\n")
      descriptor = instruction_workflow(instruction_path)
      task = task_for(project, "work", descriptor: descriptor)
      original = File.method(:read)

      with_replaced_singleton_method(File, :read, lambda { |candidate, *args, **kwargs|
        raise Errno::EACCES, candidate if candidate == instruction_path

        original.call(candidate, *args, **kwargs)
      }) do
        result = Hive::Stages::Agent.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result)
        assert_equal :error, marker.name
        assert_equal "instruction_unreadable", marker.attrs.fetch("reason")
        assert_includes marker.attrs.fetch("message"), "Errno::EACCES"
      end
    end
  end

  def test_run_turns_error_envelope_without_marker_into_error_marker
    with_tmp_dir do |project|
      task = task_for(project, "plan")

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |_task, **_kwargs|
        { status: :error, error_message: "profile unavailable" }
      }) do
        result = Hive::Stages::Agent.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result)
        assert_equal :error, marker.name
        assert_equal "agent_preflight_failed", marker.attrs["reason"]
        assert_equal "profile unavailable", marker.attrs["message"]
      end
    end
  end

  def test_rerun_overwrites_a_stale_complete_marker_when_preflight_fails
    # On a re-run of an already-markered stage, a {status: :error} preflight
    # failure must OVERWRITE the stale :complete rather than leave it in place —
    # otherwise `hive run` exits 0 reporting :complete and the failure is
    # unobservable (NO-SILENT-CAPS). The spawn wrote no marker this run, so
    # clobbering the stale one is correct (this is what dropping the
    # `marker.name == :none` guard buys).
    with_tmp_dir do |project|
      task = task_for(project, "plan")
      File.write(task.state_file, "<!-- COMPLETE -->\n")

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |_task, **_kwargs|
        { status: :error, error_message: "version too old" }
      }) do
        result = Hive::Stages::Agent.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result,
                     "a preflight failure on re-run must report :error, not the stale :complete")
        assert_equal :error, marker.name
        assert_equal "agent_preflight_failed", marker.attrs["reason"]
      end
    end
  end

  def test_rerun_overwrites_a_stale_marker_when_instruction_unreadable
    # Same NO-SILENT-CAPS guarantee for the instruction-read failure path: a
    # stale :waiting from a prior run must not survive when the stage's own
    # instruction has since become unreadable (the read happens before any
    # spawn, so no agent wrote a marker this run).
    with_tmp_dir do |project|
      instruction_path = File.join(project, "workflow-work.md")
      File.write(instruction_path, "Do the work.\n")
      descriptor = instruction_workflow(instruction_path)
      task = task_for(project, "work", descriptor: descriptor)
      File.write(task.state_file, "<!-- WAITING -->\n")
      original = File.method(:read)

      with_replaced_singleton_method(File, :read, lambda { |candidate, *args, **kwargs|
        raise Errno::EACCES, candidate if candidate == instruction_path

        original.call(candidate, *args, **kwargs)
      }) do
        result = Hive::Stages::Agent.run!(task, {})

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result,
                     "an unreadable instruction on re-run must report :error, not the stale :waiting")
        assert_equal :error, marker.name
        assert_equal "instruction_unreadable", marker.attrs.fetch("reason")
      end
    end
  end

  def test_marker_actions_map_to_commit_and_status
    {
      "" => [ nil, :none ],
      "<!-- WAITING -->\n" => [ "round_waiting", :waiting ],
      "<!-- COMPLETE -->\n" => [ "complete", :complete ],
      "<!-- ERROR -->\n" => [ "error", :error ],
      "<!-- AGENT_WORKING -->\n" => [ "agent_working", :agent_working ]
    }.each do |marker_text, expected|
      with_tmp_dir do |project|
        task = task_for(project, "plan")

        with_stubbed_spawn(marker: marker_text) do
          assert_equal({ commit: expected.first, status: expected.last }, Hive::Stages::Agent.run!(task, {}))
        end
      end
    end
  end

  def test_constructing_binding_does_not_define_readers_on_the_shared_class
    # Deterministic regression guard for the seed-dependent NameError flake.
    # The old TemplateBindings lazily ran `attr_reader k` on the SHARED class
    # for each passed key, so a shared template that referenced a key some
    # binding omitted (e.g. agent_prompt.md.erb's `instruction_body`) only
    # rendered if a key-bearing binding was constructed earlier in the suite.
    # A unique sentinel key proves construction must NOT mutate the class —
    # order-independent, so this catches a revert regardless of test ordering.
    klass = Hive::Stages::Base::TemplateBindings
    refute klass.method_defined?(:flake_regression_sentinel),
           "precondition: the sentinel reader must not pre-exist on the class"

    klass.new(flake_regression_sentinel: "x")

    refute klass.method_defined?(:flake_regression_sentinel),
           "TemplateBindings.new must not lazily define per-key readers on the shared class"
  end

  def test_shared_template_renders_when_binding_omits_a_referenced_key
    # A binding that omits instruction_body must resolve it to nil and let the
    # shared agent_prompt template (which references it) render without raising.
    bindings = Hive::Stages::Base::TemplateBindings.new(
      stage_name: "execute", output_file: "task.md",
      user_supplied_tag: "U", prior_context: "", skill_invocation: nil
    )

    assert_respond_to bindings, :instruction_body
    assert_nil bindings.instruction_body, "an unset binding key must read as nil"
    assert_kind_of String, Hive::Stages::Base.render("agent_prompt.md.erb", bindings)
  end

  private

    def instruction_workflow(instruction_path, permissions: nil)
      Hive::Workflow.new(
        id: :instruction,
        stages: [
          Hive::Workflow::Stage.new(name: "inbox", index: 1, state_file: "idea.md", kind: :inert),
          Hive::Workflow::Stage.new(
            name: "work",
            index: 2,
            state_file: "work.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "work"),
            kind: :agent,
            instruction: instruction_path,
            permissions: permissions
          )
        ]
      )
    end
end
