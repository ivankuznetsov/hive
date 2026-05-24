require "eval/eval_helper"

class HiveEvalCodexJudgeTest < Minitest::Test
  def test_judge_passes_clear_good_reply
    rubric = "Pass only when the reply mentions tasks and uses no more than two sentences."
    verdict = Hive::Eval::CodexJudge.new(rubric: rubric).verdict(text: "Two tasks need input. No other work is blocked.")

    assert verdict.pass, "expected judge pass, got #{verdict.inspect}"
    assert_operator verdict.score, :>=, 3
    refute_empty verdict.transcript
  end

  def test_judge_fails_empty_reply
    rubric = "Pass only when the reply mentions tasks and uses no more than two sentences."
    verdict = Hive::Eval::CodexJudge.new(rubric: rubric).verdict(text: "")

    refute verdict.pass, "expected judge failure, got #{verdict.inspect}"
    refute_empty verdict.transcript
  end
end
