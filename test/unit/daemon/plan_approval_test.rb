require "test_helper"
require "tmpdir"
require "hive/markers"
require "hive/daemon/plan_approval"

# Unit coverage for the shared helper that the dispatcher's
# plan-approval auto-dispatch path relies on. The dispatcher tests
# exercise the end-to-end flow; these tests pin each branch of
# PlanApproval#prepare individually so a refactor that breaks one
# arm surfaces in this file rather than in a noisier integration
# failure.
class HiveDaemonPlanApprovalTest < Minitest::Test
  PA = Hive::Daemon::PlanApproval

  def with_state_file(marker_line)
    Dir.mktmpdir("plan-approval-test") do |dir|
      path = File.join(dir, "plan.md")
      File.write(path, "# plan\n\n#{marker_line}\n")
      yield path
    end
  end

  # ---- rewrite_to_develop ----

  def test_rewrite_to_develop_swaps_verb
    assert_equal "hive develop slug --from 3-plan",
                 PA.rewrite_to_develop("hive plan slug --from 3-plan")
  end

  def test_rewrite_to_develop_preserves_quoting_on_complex_slugs
    # Shellwords round-trips quoted args safely so a slug with
    # special characters (unlikely but possible per the slug
    # regex) doesn't get mangled.
    cmd = "hive plan slug-with-dash --from 3-plan --project demo"
    assert_equal "hive develop slug-with-dash --from 3-plan --project demo",
                 PA.rewrite_to_develop(cmd)
  end

  def test_rewrite_to_develop_rejects_non_plan_verb
    err = assert_raises(ArgumentError) do
      PA.rewrite_to_develop("hive review slug --from 3-plan")
    end
    assert_match(/expects `hive plan/, err.message)
  end

  def test_rewrite_to_develop_rejects_empty_command
    assert_raises(ArgumentError) { PA.rewrite_to_develop("") }
    assert_raises(ArgumentError) { PA.rewrite_to_develop(nil) }
  end

  def test_rewrite_to_develop_rejects_command_with_only_two_argv_elements
    # `hive plan` alone (no slug) is malformed for our purposes.
    assert_raises(ArgumentError) { PA.rewrite_to_develop("hive plan") }
  end

  # ---- prepare (full flow) ----

  def test_prepare_flips_waiting_marker_to_complete_and_returns_develop_command
    with_state_file("<!-- WAITING -->") do |path|
      cmd = PA.prepare("hive plan slug --from 3-plan", path)
      assert_equal "hive develop slug --from 3-plan", cmd
      assert_equal :complete, Hive::Markers.current(path).name
    end
  end

  def test_prepare_leaves_complete_marker_alone_and_still_returns_develop_command
    # Idempotent for the race where a manual operator action (or a
    # prior tick) already flipped the marker between the status read
    # and dispatch. The dispatch is still valid; we just don't
    # re-flip.
    with_state_file("<!-- COMPLETE -->") do |path|
      cmd = PA.prepare("hive plan slug --from 3-plan", path)
      assert_equal "hive develop slug --from 3-plan", cmd
      assert_equal :complete, Hive::Markers.current(path).name
    end
  end

  def test_prepare_raises_not_approvable_for_error_marker
    with_state_file("<!-- ERROR reason=plan_failed -->") do |path|
      err = assert_raises(PA::NotApprovable) do
        PA.prepare("hive plan slug --from 3-plan", path)
      end
      assert_match(/marker=:error/, err.message)
      # Marker NOT touched.
      assert_equal :error, Hive::Markers.current(path).name
    end
  end

  def test_prepare_raises_not_approvable_for_agent_working_marker
    with_state_file("<!-- AGENT_WORKING pid=12345 -->") do |path|
      assert_raises(PA::NotApprovable) do
        PA.prepare("hive plan slug --from 3-plan", path)
      end
    end
  end

  def test_prepare_validates_command_BEFORE_flipping_marker
    # Load-bearing: if the suggested_command is malformed and we
    # flipped the marker first, the row would land at :complete
    # with no follow-up dispatch — worse than the original failure
    # because the operator sees an "approved" plan that never
    # advances. Validate command FIRST so the failure path leaves
    # the marker untouched at :waiting for inspection.
    with_state_file("<!-- WAITING -->") do |path|
      assert_raises(ArgumentError) do
        PA.prepare("hive review slug --from 3-plan", path)
      end
      assert_equal :waiting, Hive::Markers.current(path).name,
                   "command validation must happen before marker flip"
    end
  end
end
