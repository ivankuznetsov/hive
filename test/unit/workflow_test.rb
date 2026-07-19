require "test_helper"
require "hive/workflow"
require "hive/workflows/registry"

class WorkflowTest < Minitest::Test
  def test_stage_dir_joins_index_and_name
    stage = Hive::Workflow::Stage.new(name: "execute", index: 4, state_file: "task.md")

    assert_equal "4-execute", stage.dir
  end

  def test_stage_defaults_optional_descriptor_fields
    stage = Hive::Workflow::Stage.new(name: "plan", index: 3, state_file: "plan.md")

    assert_nil stage.advance_verb
    assert_nil stage.kind
    assert_nil stage.skill
    assert_nil stage.instruction
    assert_nil stage.permissions
    assert_nil stage.status_mode
    assert_nil stage.budget_usd
    assert_nil stage.timeout_sec
    assert_nil stage.capability
    assert_nil stage.agent
    assert_nil stage.model
    assert_nil stage.effort
    assert_nil stage.input
    assert_nil stage.reviewers
    assert_nil stage.council
    assert_nil stage.deliverable
  end

  def test_known_kinds_include_coding_runtime_primitives
    assert_includes Hive::Workflow::KNOWN_KINDS, :council
    assert_includes Hive::Workflow::KNOWN_KINDS, :execute
    assert_includes Hive::Workflow::KNOWN_KINDS, :review_council
    assert_includes Hive::Workflow::KNOWN_KINDS, :finalize
    # The actual behavior change: `:marker` was retired (the
    # workflow_helpers.rb / resolver_test.rb edits exist precisely because the
    # kind no longer exists). Pin its absence so a re-introduction is caught.
    refute_includes Hive::Workflow::KNOWN_KINDS, :marker
  end

  def test_stage_carries_user_descriptor_instruction_and_permissions
    stage = Hive::Workflow::Stage.new(
      name: "work",
      index: 2,
      state_file: "work.md",
      kind: :agent,
      instruction: "/tmp/hive-work.md",
      permissions: "read-only",
      agent: "codex",
      model: "opus",
      effort: "high"
    )

    assert_equal "/tmp/hive-work.md", stage.instruction
    assert_equal "read-only", stage.permissions
    assert_equal "codex", stage.agent
    assert_equal "opus", stage.model
    assert_equal "high", stage.effort
  end

  def test_advance_verb_defaults_flags_to_false
    verb = Hive::Workflow::AdvanceVerb.new(name: "plan")

    assert_equal "plan", verb.name
    refute verb.force_source
    refute verb.interactive
  end

  def test_advance_verb_can_flag_interactive
    verb = Hive::Workflow::AdvanceVerb.new(name: "manual-review", interactive: true)

    assert verb.interactive, "interactive: true must surface on the value object the VERBS derivation reads"
    assert verb.frozen?
  end

  def test_workflow_freezes_stage_array
    stages = [
      Hive::Workflow::Stage.new(name: "inbox", index: 1, state_file: "idea.md")
    ]

    workflow = Hive::Workflow.new(id: :coding, stages: stages)

    assert workflow.frozen?
    assert workflow.stages.frozen?
    refute stages.frozen?, "the caller's array must stay unfrozen — the workflow freezes its own dup"
  end

  def test_stage_named_returns_stage_by_name
    workflow = Hive::Workflows::Registry.default

    assert_equal 2, workflow.stage_named("brainstorm").index
    assert_nil workflow.stage_named("nope")
  end

  def test_next_stage_after_uses_descriptor_order
    coding = Hive::Workflows::Registry.default

    assert_equal "execute", coding.next_stage_after("plan").name
    assert_equal "4-execute", coding.next_stage_after("plan").dir

    research = research_workflow

    assert_equal "report", research.next_stage_after("gather").name
    assert_equal "3-report", research.next_stage_after("gather").dir
  end

  def test_next_stage_after_returns_nil_for_terminal_stage
    coding = Hive::Workflows::Registry.default
    research = research_workflow

    assert_nil coding.next_stage_after("done")
    assert_nil research.next_stage_after("report")
  end

  def test_next_stage_after_returns_nil_for_unknown_stage
    coding = Hive::Workflows::Registry.default

    assert_nil coding.next_stage_after("nope")
  end

  def test_advance_verb_for_returns_descriptor_verb_name
    coding = Hive::Workflows::Registry.default

    assert_equal "plan", coding.advance_verb_for("plan")
    assert_equal "develop", coding.advance_verb_for("execute")
    assert_nil coding.advance_verb_for("inbox")
  end

  def test_advance_verb_for_nil_means_mv_only
    research = research_workflow

    assert_nil research.advance_verb_for("gather")
    assert_nil research.advance_verb_for("report")
    assert_nil research.advance_verb_for("nope")
  end

  def test_stage_for_dir_returns_stage_by_descriptor_dir
    coding = Hive::Workflows::Registry.default
    research = research_workflow

    assert_equal 3, coding.stage_for_dir("3-plan").index
    assert_equal "plan", coding.stage_for_dir("3-plan").name
    assert_equal 2, research.stage_for_dir("2-gather").index
    assert_equal "gather", research.stage_for_dir("2-gather").name
    assert_nil coding.stage_for_dir("99-nope")
  end

  def test_resolve_stage_ref_accepts_full_dir_and_short_name
    coding = Hive::Workflows::Registry.default
    research = research_workflow

    assert_equal "3-plan", coding.resolve_stage_ref("3-plan")
    assert_equal "3-plan", coding.resolve_stage_ref("plan")
    assert_equal "3-report", research.resolve_stage_ref("3-report")
    assert_equal "3-report", research.resolve_stage_ref("report")
    assert_nil coding.resolve_stage_ref("nope")
  end

  def test_has_stage_accepts_full_dir_and_short_name
    coding = Hive::Workflows::Registry.default
    research = research_workflow

    assert coding.has_stage?("3-plan")
    assert coding.has_stage?("plan")
    assert research.has_stage?("2-gather")
    assert research.has_stage?("gather")
    refute coding.has_stage?("2-gather")
    refute research.has_stage?("3-plan")
  end

  def test_state_file_for_returns_stage_state_file
    workflow = Hive::Workflows::Registry.default

    assert_equal "plan.md", workflow.state_file_for("plan")
    assert_equal "task.md", workflow.state_file_for("execute")
  end

  def test_state_file_for_unknown_stage_raises
    workflow = Hive::Workflows::Registry.default

    error = assert_raises(KeyError) { workflow.state_file_for("nope") }

    assert_match(/unknown stage "nope"/, error.message)
    assert_match(/:coding/, error.message)
  end

  def test_stage_names_returns_descriptor_stage_names
    workflow = Hive::Workflows::Registry.default

    # Anchor to an independent literal — comparing against workflow.stages.map(&:name)
    # would be tautological since stage_names IS that expression.
    assert_equal %w[inbox brainstorm plan execute open-pr review artifacts finalize done],
                 workflow.stage_names
  end

  def test_stage_dirs_returns_descriptor_stage_dirs
    workflow = Hive::Workflows::Registry.default
    dirs = workflow.stage_dirs

    # Anchor to an independent literal — comparing against workflow.stages.map(&:dir)
    # would be tautological since stage_dirs IS that expression. A reorder or
    # rename in the descriptor must break this.
    assert_equal %w[1-inbox 2-brainstorm 3-plan 4-execute 5-open-pr 6-review 7-artifacts 8-finalize 9-done],
                 dirs
    assert dirs.frozen?
  end

  def test_executable_slots_cover_managed_stage_reviewer_and_revise_topology
    reviewer = Hive::Workflow::Reviewer.new(name: "security")
    revise = Hive::Workflow::Revise.new
    workflow = Hive::Workflow.new(
      id: :managed,
      stages: [
        Hive::Workflow::Stage.new(
          name: "inbox", index: 1, state_file: "idea.md", kind: :inert
        ),
        Hive::Workflow::Stage.new(
          name: "draft", index: 2, state_file: "draft.md", kind: :agent
        ),
        Hive::Workflow::Stage.new(
          name: "review", index: 3, state_file: "review.md", kind: :council,
          reviewers: [ reviewer ],
          council: Hive::Workflow::Council.new(quorum: 1, revise: revise)
        )
      ]
    )

    assert_equal [
      [ "stages.draft", :stage, "development" ],
      [ "stages.review", :stage, "development" ],
      [ "stages.review.reviewers.security", :reviewer, "reviewer" ],
      [ "stages.review.revise", :revise, "development" ]
    ], workflow.executable_slots.map { |slot| [ slot.id, slot.kind, slot.default_role ] }
  end

  def test_single_stage_workflow_has_no_next_stage
    assert_nil single_stage_workflow.next_stage_after("only")
  end

  def test_workflow_rejects_empty_stage_list
    error = assert_raises(ArgumentError) { Hive::Workflow.new(id: :empty, stages: []) }
    assert_match(/at least one stage/, error.message)
  end

  def test_workflow_rejects_gapped_or_unordered_indices
    error = assert_raises(ArgumentError) do
      Hive::Workflow.new(
        id: :gapped,
        stages: [
          Hive::Workflow::Stage.new(name: "a", index: 1, state_file: "a.md", kind: :inert),
          Hive::Workflow::Stage.new(name: "b", index: 3, state_file: "b.md", kind: :agent)
        ]
      )
    end
    assert_match(/stage indices must be \[1, 2\]/, error.message)
  end

  def test_workflow_rejects_duplicate_stage_names
    error = assert_raises(ArgumentError) do
      Hive::Workflow.new(
        id: :dupes,
        stages: [
          Hive::Workflow::Stage.new(name: "draft", index: 1, state_file: "a.md", kind: :inert),
          Hive::Workflow::Stage.new(name: "draft", index: 2, state_file: "b.md", kind: :agent)
        ]
      )
    end
    assert_match(/duplicate stage names/, error.message)
  end

  def test_workflow_rejects_duplicate_stage_dirs
    stage = Struct.new(:name, :index, :state_file, :kind, :advance_verb) do
      def dir = "same-dir"
    end

    error = assert_raises(ArgumentError) do
      Hive::Workflow.new(
        id: :dupedirs,
        stages: [
          stage.new("draft", 1, "draft.md", :inert, nil),
          stage.new("review", 2, "review.md", :agent, nil)
        ]
      )
    end
    assert_match(/duplicate stage dirs/, error.message)
  end

  def test_workflow_rejects_unknown_stage_kind
    error = assert_raises(ArgumentError) do
      Hive::Workflow.new(
        id: :badkind,
        stages: [
          Hive::Workflow::Stage.new(name: "draft", index: 1, state_file: "a.md", kind: :agnet)
        ]
      )
    end
    assert_match(/unknown kind :agnet/, error.message)
  end

  def test_workflow_rejects_first_stage_advance_verb
    error = assert_raises(ArgumentError) do
      Hive::Workflow.new(
        id: :badfirst,
        stages: [
          Hive::Workflow::Stage.new(
            name: "draft", index: 1, state_file: "a.md", kind: :agent,
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "draft")
          )
        ]
      )
    end
    assert_match(/first stage "draft" must not declare an advance_verb/, error.message)
  end

  def test_value_objects_are_immutable_and_copyable
    stage = Hive::Workflow::Stage.new(
      name: "brainstorm",
      index: 2,
      state_file: "brainstorm.md",
      advance_verb: Hive::Workflow::AdvanceVerb.new(name: "brainstorm", force_source: true)
    )

    assert stage.frozen?
    assert_raises(FrozenError) { stage.instance_variable_set(:@name, "plan") }

    copy = stage.with(index: 3, name: "plan", state_file: "plan.md")

    assert_equal "3-plan", copy.dir
    assert_equal "2-brainstorm", stage.dir
  end
end
