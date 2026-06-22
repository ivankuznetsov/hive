require "test_helper"
require "hive/workflows/coding"

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
    assert_equal :agent, stages_by_name.fetch("open-pr").kind
    assert_equal :"review-council", stages_by_name.fetch("review").kind
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
end
