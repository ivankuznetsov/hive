require "eval/eval_helper"

class HiveEvalS3NoiseTest < Minitest::Test
  include Hive::Eval::ScenarioSupport

  def test_simulated_night_obeys_signal_not_noise_contract
    given_project(name: "hive")

    50.times do |tick|
      rows = noisy_rows(tick)
      when_agent_emits(rows: rows)
      when_clock_advances(60)
    end

    assert_all_messages_typed
    assert_no_duplicates(window_sec: 300)
    refute_proactive_status_response
    assert_proactive_rule
  end

  private

  def noisy_rows(tick)
    rows = 6.times.map do |idx|
      status_row(slug: "running-#{idx}", action: "agent_running", marker: "agent_working")
    end
    rows << status_row(slug: "same-question", action: "needs_input", marker: "waiting")
    rows << status_row(slug: "same-question", action: "needs_input", marker: "waiting")
    rows << status_row(slug: "debug-row", action: "debug", marker: "debug")
    if (tick % 10).zero?
      rows << status_row(slug: "finished-#{tick}", stage: "7-artifacts",
                         action: "ready_to_finalize", marker: "complete")
    end
    rows
  end
end
