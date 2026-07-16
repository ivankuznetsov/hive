require "test_helper"
require "hive/workflows/coding"
require "hive/task_action"

class WorkflowsCodingTest < Minitest::Test
  def test_descriptor_has_coding_id_and_ordered_stages
    descriptor = Hive::Workflows::Coding::DESCRIPTOR

    assert_equal :coding, descriptor.id
    assert_equal %w[inbox brainstorm plan execute open-pr review artifacts finalize done],
                 descriptor.stages.map(&:name)
    assert_equal (1..9).to_a, descriptor.stages.map(&:index)
    assert descriptor.stages.frozen?
  end

  def test_descriptor_carries_transition_verbs
    verbs = Hive::Workflows::Coding::DESCRIPTOR.stages.map { |stage| stage.advance_verb&.name }

    assert_equal [ nil, "brainstorm", "plan", "develop", "open-pr", "review", "artifacts", "finalize", "archive" ], verbs
    assert Hive::Workflows::Coding::DESCRIPTOR.stages.fetch(1).advance_verb.force_source
    refute Hive::Workflows::Coding::DESCRIPTOR.stages.fetch(1).advance_verb.interactive
  end

  def test_descriptor_carries_stage_kinds_and_metadata
    stages_by_name = Hive::Workflows::Coding::DESCRIPTOR.stages.to_h { |stage| [ stage.name, stage ] }

    assert_equal :inert, stages_by_name.fetch("inbox").kind
    assert_equal :agent, stages_by_name.fetch("brainstorm").kind
    assert_equal "/ce-brainstorm", stages_by_name.fetch("brainstorm").skill
    assert_equal :state_file_marker, stages_by_name.fetch("plan").status_mode
    assert_equal :execute, stages_by_name.fetch("execute").kind
    assert_equal :exit_code_only, stages_by_name.fetch("execute").status_mode
    assert_equal 500, stages_by_name.fetch("execute").budget_usd
    assert_equal 14400, stages_by_name.fetch("execute").timeout_sec
    assert_equal "execute_to_open_pr", stages_by_name.fetch("execute").condition_policy.transition
    assert stages_by_name.fetch("execute").condition_policy.authoritative_capable
    assert_equal :agent, stages_by_name.fetch("open-pr").kind
    assert_equal :review_council, stages_by_name.fetch("review").kind
    assert_nil stages_by_name.fetch("review").status_mode
    assert_equal :agent, stages_by_name.fetch("artifacts").kind
    assert_equal :finalize, stages_by_name.fetch("finalize").kind
    assert_equal :inert, stages_by_name.fetch("done").kind
  end

  # Pin the *absence* of metadata on the inert/runtime stages so a stray
  # `budget_usd`/`timeout_sec`/`skill` cannot drift in unnoticed. The
  # current runtime leaves these fields unread, but the golden contract
  # should still fail loud if the descriptor sprouts spurious config.
  def test_inert_and_runtime_stages_carry_no_spurious_metadata
    stages_by_name = Hive::Workflows::Coding::DESCRIPTOR.stages.to_h { |stage| [ stage.name, stage ] }

    inbox = stages_by_name.fetch("inbox")
    assert_nil inbox.advance_verb
    assert_nil inbox.skill
    assert_nil inbox.status_mode
    assert_nil inbox.budget_usd
    assert_nil inbox.timeout_sec
    assert_nil inbox.capability

    review = stages_by_name.fetch("review")
    assert_nil review.skill
    assert_nil review.budget_usd
    assert_nil review.timeout_sec
    assert_nil review.capability

    done = stages_by_name.fetch("done")
    assert_nil done.skill
    assert_nil done.status_mode
    assert_nil done.budget_usd
    assert_nil done.timeout_sec
    assert_nil done.capability
  end

  # U11 made Coding::ACTION_DISPATCH the source of truth for the user-facing
  # action of every coding :agent/:inert stage. Pin each row's shape so a
  # malformed or drifted entry fails here rather than as a runtime KeyError
  # (config.fetch(:default)) or a silent generic fall-through on a live
  # `hive status`/daemon tick.
  def test_action_dispatch_rows_are_well_formed
    stages_by_name = Hive::Workflows::Coding::DESCRIPTOR.stages.to_h { |stage| [ stage.name, stage ] }
    task_action_methods = Hive::TaskAction.instance_methods(false) +
                          Hive::TaskAction.private_instance_methods(false)

    Hive::Workflows::Coding::ACTION_DISPATCH.each do |name, config|
      stage = stages_by_name.fetch(name) do
        flunk "ACTION_DISPATCH row #{name.inspect} has no matching descriptor stage"
      end

      assert config.key?(:kind), "ACTION_DISPATCH row #{name.inspect} must declare :kind"
      assert_equal stage.kind, config.fetch(:kind),
                   "ACTION_DISPATCH row #{name.inspect} :kind must match its descriptor stage kind"

      assert config.key?(:handler) ^ config.key?(:default),
             "ACTION_DISPATCH row #{name.inspect} must have exactly one of :handler or :default"

      if config.key?(:handler)
        assert_includes task_action_methods, config.fetch(:handler),
                        "ACTION_DISPATCH row #{name.inspect} :handler must be a TaskAction method"
      else
        config.values_at(:default, :complete).compact.each do |action_key|
          assert Hive::TaskAction::ACTIONS.key?(action_key),
                 "ACTION_DISPATCH row #{name.inspect} references unknown ACTIONS key #{action_key.inspect}"
        end
      end
    end
  end

  # Guard the "parity-wall" regression: a future coding :agent/:inert stage
  # added without an ACTION_DISPATCH row would make coding_table_action return
  # nil and silently fall through to generic_action, emitting generic
  # run/approve commands the coding runner does not expect.
  def test_action_dispatch_covers_every_coding_agent_or_inert_stage
    table_stages = Hive::Workflows::Coding::ACTION_DISPATCH.keys
    classified_stages = Hive::Workflows::Coding::DESCRIPTOR.stages
                                                           .select { |stage| %i[agent inert].include?(stage.kind) }
                                                           .map(&:name)

    classified_stages.each do |name|
      assert_includes table_stages, name,
                      "coding :agent/:inert stage #{name.inspect} must have an ACTION_DISPATCH row"
    end
  end

  # task_action.rb's kind_action routes :execute/:review_council/:finalize straight
  # to the coding-hardcoded helpers (execute_action/review_action/finalize_action)
  # with NO coding_id? guard — unlike the :agent/:inert arm, which gates on
  # coding_id? via coding_table_action. That asymmetry is safe ONLY because no
  # non-coding descriptor declares those runtime kinds: parse_kind rejects them for
  # YAML descriptors (descriptor_parser_test pins the exact strings) and only
  # Workflows::Coding declares them via Stage.new. Pin the Ruby half of that
  # invariant across EVERY registered descriptor so a future Ruby-constructed
  # non-coding workflow carrying a coding runtime kind fails here, not by silently
  # misrouting to a coding helper on a live status/daemon tick.
  def test_no_non_coding_descriptor_declares_a_coding_runtime_kind
    coding_runtime_kinds = %i[execute review_council finalize]

    Hive::Workflows::Registry.all.reject { |descriptor| Hive::Workflows.coding_id?(descriptor.id) }.each do |descriptor|
      offending = descriptor.stages.select { |stage| coding_runtime_kinds.include?(stage.kind) }.map(&:name)

      assert_empty offending,
                   "non-coding descriptor #{descriptor.id.inspect} declares coding-only runtime kind(s) on " \
                   "stage(s) #{offending.inspect}; kind_action would misroute them to coding-hardcoded helpers"
    end
  end

  # Completeness pin for the OTHER half of the same asymmetry: kind_action has
  # explicit `when` arms only for :execute/:review_council/:finalize/:agent/:inert;
  # every other kind (including a future nil) drops to the generic `else` and emits
  # generic run/approve commands the coding runner never expects. Pin that every
  # kind the coding descriptor actually declares is covered by an explicit arm, so
  # a new coding stage with an unhandled kind fails here rather than silently
  # falling through to generic_action. The arm list mirrors kind_action's case.
  def test_every_coding_stage_kind_hits_an_explicit_kind_action_arm
    explicit_kind_action_arms = %i[execute review_council finalize agent inert]
    declared_kinds = Hive::Workflows::Coding::DESCRIPTOR.stages.map(&:kind).uniq

    unhandled = declared_kinds - explicit_kind_action_arms

    assert_empty unhandled,
                 "coding descriptor declares kind(s) #{unhandled.inspect} with no explicit kind_action arm; " \
                 "they would fall through to generic_action instead of a coding helper"
  end
end
