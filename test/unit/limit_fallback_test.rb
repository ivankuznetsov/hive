require "test_helper"
require "hive/limit_fallback"

# The shared provider-limit fallback rules behind review.limit_fallback and
# implementation.limit_fallback: one decision core, keyed by config path.
class LimitFallbackTest < Minitest::Test
  include HiveTestHelper

  PATH = %w[implementation limit_fallback].freeze
  LONG_LIMIT = "You've hit your usage limit. Upgrade to Pro or try again at Nov 23rd.".freeze

  def cfg(enabled: true, min_wait_sec: 3600)
    {
      "implementation" => {
        "limit_fallback" => { "enabled" => enabled, "min_wait_sec" => min_wait_sec, "agents" => { "codex" => "grok" } }
      },
      "review" => { "limit_fallback" => { "enabled" => true, "agents" => { "codex" => "claude" } } }
    }
  end

  def reset_hint(at)
    "You've hit your usage limit. Try again at #{at.utc.strftime('%b %-d, %Y %-I:%M %p')} UTC."
  end

  def test_each_block_is_read_independently
    assert_equal "grok", Hive::LimitFallback.configured_fallback(cfg, PATH, "codex")
    assert_equal "claude", Hive::LimitFallback.configured_fallback(cfg, %w[review limit_fallback], "codex")
    assert_nil Hive::LimitFallback.settings(cfg(enabled: false), PATH)
  end

  def test_evaluate_distinguishes_a_deferral_from_a_substitution
    now = Time.now.utc
    logged = []
    log = ->(message) { logged << message }

    deferral = Hive::LimitFallback.evaluate(
      cfg, path: PATH, phase: "execute", primary: "codex", limit_text: reset_hint(now + 600),
      error_message: nil, log: log, now: now
    )
    decision = Hive::LimitFallback.evaluate(
      cfg, path: PATH, phase: "execute", primary: "codex", limit_text: LONG_LIMIT,
      error_message: nil, log: log, now: now
    )

    assert_instance_of Hive::LimitFallback::Deferral, deferral
    assert_equal %w[codex grok], [ deferral.primary, deferral.fallback ]
    refute_nil deferral.retry_after
    assert_instance_of Hive::LimitFallback::Decision, decision
    assert_nil decision.retry_after
    assert_equal 1, logged.length
    assert_match(/waiting for reset instead of falling back to grok/, logged.first)
    assert_nil Hive::LimitFallback.decide(
      cfg, path: PATH, phase: "execute", primary: "codex", limit_text: reset_hint(now + 600),
      error_message: nil, log: log, now: now
    )
  end
end
