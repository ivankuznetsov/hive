require "test_helper"
require "hive/stages"

class StagesTest < Minitest::Test
  def test_dirs_short_names_and_short_to_full_round_trip
    expected_short_to_full = {
      "inbox" => "1-inbox", "brainstorm" => "2-brainstorm", "plan" => "3-plan",
      "execute" => "4-execute", "review" => "5-review",
      "pr" => "6-pr", "done" => "7-done"
    }
    assert_equal expected_short_to_full, Hive::Stages::SHORT_TO_FULL.to_h
    assert_equal %w[1-inbox 2-brainstorm 3-plan 4-execute 5-review 6-pr 7-done], Hive::Stages::DIRS
    assert_equal %w[inbox brainstorm plan execute review pr done], Hive::Stages::NAMES
    assert Hive::Stages::DIRS.frozen?
    assert Hive::Stages::NAMES.frozen?
    assert Hive::Stages::SHORT_TO_FULL.frozen?
  end

  def test_resolve_accepts_full_or_short_returns_canonical
    assert_equal "3-plan", Hive::Stages.resolve("3-plan")
    assert_equal "3-plan", Hive::Stages.resolve("plan")
    assert_nil Hive::Stages.resolve("plan-foo")
    assert_nil Hive::Stages.resolve("99-foo")
    assert_nil Hive::Stages.resolve("")
  end

  def test_next_dir_returns_following_stage_or_nil_at_end
    assert_equal "2-brainstorm", Hive::Stages.next_dir(1)
    assert_equal "5-review", Hive::Stages.next_dir(4)
    assert_equal "6-pr", Hive::Stages.next_dir(5)
    assert_equal "7-done", Hive::Stages.next_dir(6)
    assert_nil Hive::Stages.next_dir(7),
               "past the final stage must return nil so the caller can branch on it"
  end

  def test_next_dir_returns_nil_for_unknown_prefix
    # Prefix that doesn't exist in DIRS returns nil cleanly, not a
    # neighboring stage.
    assert_nil Hive::Stages.next_dir(99)
  end

  def test_next_dir_raises_on_invalid_index
    # Off-by-one bugs surface here rather than silently returning nil and
    # being indistinguishable from "final stage".
    assert_raises(ArgumentError) { Hive::Stages.next_dir(0) }
    assert_raises(ArgumentError) { Hive::Stages.next_dir(-1) }
    assert_raises(ArgumentError) { Hive::Stages.next_dir("3") }
    assert_raises(ArgumentError) { Hive::Stages.next_dir(nil) }
  end

  def test_parse_validates_dir_membership
    # Well-formed-but-unknown stage strings return nil rather than parsing
    # successfully, so a hand-constructed stage like "99-foo" can't slip
    # past validation downstream.
    assert_equal [ 3, "plan" ], Hive::Stages.parse("3-plan")
    assert_equal [ 1, "inbox" ], Hive::Stages.parse("1-inbox")
    assert_nil Hive::Stages.parse("99-foo")
    assert_nil Hive::Stages.parse("plan")
    assert_nil Hive::Stages.parse("")
    assert_nil Hive::Stages.parse("3-plan-extra")
  end
end
