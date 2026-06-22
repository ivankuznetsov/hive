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

  def test_marker_actions_map_to_commit_and_status
    {
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
end
