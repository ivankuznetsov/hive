require "test_helper"
require "time"
require "hive/agent_limit"

class AgentLimitTest < Minitest::Test
  def test_detects_claude_usage_limit_menu
    text = <<~TEXT
      What do you want to do?
      ❯ 1. Stop and wait for limit to reset
        2. Add funds to continue with usage credits
        3. Switch to Team plan
    TEXT

    assert Hive::AgentLimit.limit_reached?(text)
    assert_match(/\Alimits reached for claude:/,
                 Hive::AgentLimit.error_message(text, agent: "claude"))
  end

  # The Claude Code startup banner advertises "Included in your plan limits
  # until Jun 22, then switch to usage credits to continue." to every
  # subscriber — an informational promo, not a wall. Classifying it as
  # limits_reached made EVERY healthy claude launch fail (found dogfooding
  # hivebox: all brainstorms died with "limits reached for claude" while
  # the account had headroom).
  def test_does_not_classify_the_plan_inclusion_banner_as_a_limit
    banner = <<~TEXT
      ▐▛███▜▌   Claude Code v2.1.170
      Fable 5 with high effort · Claude Max
      ▎ Included in your plan limits until Jun 22, then switch to usage credits to continue.
    TEXT

    refute Hive::AgentLimit.limit_reached?(banner),
           "an informational plan-inclusion notice must not read as a usage wall"
  end

  # The promo footer persists for the WHOLE session, so this exact pane is
  # what the mid-run sentinel poll sees on a healthy, working agent.
  def test_does_not_classify_a_healthy_ready_pane_with_promo_footer
    pane = <<~TEXT
       ▐▛███▜▌   Claude Code v2.1.170
      ▝▜█████▛▘  Fable 5 with high effort · Claude Max
        ▘▘ ▝▝    /tmp/repos/some-project
      ❯
        project main ? ❯                              ● high · /effort
       ▎ Included in your plan limits until Jun 22, then switch to usage credits to continue.
    TEXT

    refute Hive::AgentLimit.limit_reached?(pane),
           "a ready pane with informational footer copy must never read as a wall"
  end

  def test_detects_the_real_menu_even_with_promo_footer_present
    pane = <<~TEXT
      ▎ Included in your plan limits until Jun 22, then switch to usage credits to continue.
      What do you want to do?
      ❯ 1. Stop and wait for limit to reset
        2. Add funds to continue with usage credits
    TEXT

    assert Hive::AgentLimit.limit_reached?(pane),
           "the genuine limit menu must be detected even alongside benign chrome"
  end

  def test_benign_status_hints_do_not_trip_detection
    refute Hive::AgentLimit.limit_reached?("Run /status to see usage limits and account info")
    refute Hive::AgentLimit.limit_reached?("Your usage limits reset on July 1")
  end

  def test_detects_genuine_usage_credit_exhaustion
    assert Hive::AgentLimit.limit_reached?("You are out of usage credits."),
           "real credit exhaustion must still be detected"
    assert Hive::AgentLimit.limit_reached?("Purchase more usage credits to continue")
  end

  def test_detects_common_provider_quota_errors
    assert Hive::AgentLimit.limit_reached?("Error: RESOURCE_EXHAUSTED: quota exceeded")
    assert Hive::AgentLimit.limit_reached?("429 Too Many Requests")
    assert Hive::AgentLimit.limit_reached?("insufficient_quota")
  end

  def test_detects_the_claude_session_limit_wall
    # The exact message a headless `claude -p` run returns when the
    # subscription session window is exhausted (api_error_status=429);
    # missing it strands the task with a plain exit_code error marker
    # instead of a self-healing limits_reached one.
    assert Hive::AgentLimit.limit_reached?("You've hit your session limit \u00b7 resets 8pm (Europe/London)"),
           "the session-limit wall must classify as limits_reached"
  end

  def test_approaching_session_limit_warning_is_benign
    refute Hive::AgentLimit.limit_reached?("Approaching session limit \u00b7 run /compact to continue"),
           "the healthy-pane warning must not kill a running session"
  end

  def test_does_not_classify_unrelated_errors_as_limits
    refute Hive::AgentLimit.limit_reached?("tmux session terminated before writing expected output")
    refute Hive::AgentLimit.limit_reached?("exit_code=1")
    refute Hive::AgentLimit.limit_reached?("429        hive_state = File.join(project_root, \".hive-state\")")
    refute Hive::AgentLimit.limit_reached?("error output includes source line 429        hive_state = path")
    refute Hive::AgentLimit.limit_reached?("missing rate limit on /api/upload")
  end

  def test_retry_after_is_default_cooldown_in_the_future
    now = Time.utc(2026, 6, 8, 12, 0, 0)
    stamp = Hive::AgentLimit.retry_after(now: now)

    assert_equal (now + Hive::AgentLimit::RETRY_COOLDOWN_SEC).iso8601, stamp
    assert Time.parse(stamp) > now, "retry_after must be in the future"
  end

  def test_retry_after_normalizes_a_non_utc_now_to_utc
    now = Time.new(2026, 6, 8, 12, 0, 0, "+05:00")
    stamp = Hive::AgentLimit.retry_after(now: now)

    assert_equal (now.utc + Hive::AgentLimit::RETRY_COOLDOWN_SEC).iso8601, stamp
    assert_match(/Z\z/, stamp, "stamp must be serialized in UTC")
  end

  def test_retry_cooldown_sec_honors_a_positive_env_override
    with_env("HIVE_LIMITS_RETRY_COOLDOWN_SEC" => "120") do
      assert_equal 120, Hive::AgentLimit.retry_cooldown_sec
      now = Time.utc(2026, 6, 8, 12, 0, 0)
      assert_equal (now + 120).iso8601, Hive::AgentLimit.retry_after(now: now)
    end
  end

  def test_retry_cooldown_sec_falls_back_on_unparseable_or_non_positive_override
    [ "not-a-number", "0", "-5", "" ].each do |bad|
      with_env("HIVE_LIMITS_RETRY_COOLDOWN_SEC" => bad) do
        assert_equal Hive::AgentLimit::RETRY_COOLDOWN_SEC, Hive::AgentLimit.retry_cooldown_sec,
                     "override #{bad.inspect} must fall back to the default cooldown"
      end
    end
  end

  def test_retry_cooldown_sec_uses_default_when_env_is_unset
    with_env("HIVE_LIMITS_RETRY_COOLDOWN_SEC" => nil) do
      assert_equal Hive::AgentLimit::RETRY_COOLDOWN_SEC, Hive::AgentLimit.retry_cooldown_sec
    end
  end

  def test_held_predicate_matches_error_and_review_error_limit_markers
    attrs = { "reason" => "limits_reached" }

    assert Hive::AgentLimit.held?(:error, attrs)
    assert Hive::AgentLimit.held?("review_error", attrs)
    refute Hive::AgentLimit.held?(:execute_waiting, attrs)
    refute Hive::AgentLimit.held?(:error, "reason" => "implementer_failed")
  end

  def test_held_provider_prefers_attr_and_falls_back_to_message
    assert_equal "codex", Hive::AgentLimit.held_provider("provider" => "codex",
                                                         "message" => "limits reached for claude: wall")
    assert_equal "claude", Hive::AgentLimit.held_provider("message" => "limits reached for claude: wall")
    assert_nil Hive::AgentLimit.held_provider("message" => "limits reached")
    assert_nil Hive::AgentLimit.held_provider("provider" => "bad provider")
  end

  def test_held_retry_display_formats_utc_and_ignores_garbled_timestamps
    attrs = { "retry_after" => "2026-06-24T23:20:00+02:00" }

    assert_equal "2026-06-24 21:20 UTC", Hive::AgentLimit.held_retry_display(attrs)
    assert_nil Hive::AgentLimit.held_retry_display("retry_after" => "not-a-timestamp")
  end

  def test_held_label_renders_literal_quota_hold_text
    attrs = {
      "provider" => "codex",
      "retry_after" => "2026-06-24T23:20:00Z"
    }

    assert_equal "held: agent quota (codex) — retry after 2026-06-24 23:20 UTC; " \
                 "top up or switch execute agent",
                 Hive::AgentLimit.held_label(attrs)
  end

  def test_held_label_omits_unknown_provider_and_missing_retry
    assert_equal "held: agent quota; top up or switch execute agent",
                 Hive::AgentLimit.held_label({})
  end

  def test_held_field_serializes_quota_shape
    attrs = {
      "provider" => "codex",
      "retry_after" => "2026-06-24T23:20:00+02:00"
    }

    assert_equal({
      "reason" => "quota",
      "provider" => "codex",
      "retry_after" => "2026-06-24T21:20:00Z"
    }, Hive::AgentLimit.held_field(attrs))
  end

  # The null variant the helper really emits for message-only / attr-less
  # legacy markers and garbled timestamps: schema declares provider /
  # retry_after nullable precisely for this shape (hive-status.v4.json#held).
  def test_held_field_emits_null_provider_and_retry_for_attr_less_marker
    assert_equal({
      "reason" => "quota",
      "provider" => nil,
      "retry_after" => nil
    }, Hive::AgentLimit.held_field("reason" => "limits_reached"))

    # A garbled retry_after must null out rather than raise / leak.
    assert_equal({
      "reason" => "quota",
      "provider" => nil,
      "retry_after" => nil
    }, Hive::AgentLimit.held_field("reason" => "limits_reached",
                                   "retry_after" => "not-a-timestamp"))
  end

  def test_live_limit_menu_detects_tail_wall_and_returns_matched_line
    pane = pane_fixture("limit_menu_live.txt")

    assert Hive::AgentLimit.live_limit_menu?(pane)
    assert_equal "❯ 1. Stop and wait for limit to reset",
                 Hive::AgentLimit.live_limit_line(pane)
  end

  def test_live_limit_menu_rejects_quoted_menu_after_agent_moved_on
    pane = pane_fixture("limit_quoted_7456.txt")

    refute Hive::AgentLimit.live_limit_menu?(pane),
           "a fresh ready/activity prompt below the quote means the run moved on"
    assert_nil Hive::AgentLimit.live_limit_line(pane)
  end

  def test_live_limit_menu_rejects_old_menu_outside_true_tail
    pane = <<~TEXT
      What do you want to do?
      ❯ 1. Stop and wait for limit to reset
        2. Add funds to continue with usage credits
      line one after old quoted menu
      line two after old quoted menu
      line three after old quoted menu
      line four after old quoted menu
      line five after old quoted menu
      line six after old quoted menu
      line seven after old quoted menu
      line eight after old quoted menu
      line nine after old quoted menu
    TEXT

    refute Hive::AgentLimit.live_limit_menu?(pane)
    assert_nil Hive::AgentLimit.live_limit_line(pane)
  end

  def test_live_limit_menu_requires_limit_and_menu_signals
    menu_without_limit = <<~TEXT
      What do you want to do?
      ❯ 1. Continue working
        2. Change model
    TEXT

    limit_without_menu = <<~TEXT
      Claude says you have hit your session limit.
      It will reset later.
    TEXT

    refute Hive::AgentLimit.live_limit_menu?(menu_without_limit)
    refute Hive::AgentLimit.live_limit_menu?(limit_without_menu)
  end

  def test_live_limit_menu_rejects_benign_chrome_only_pane
    pane = <<~TEXT
      ▐▛███▜▌   Claude Code v2.1.170
      ▎ Included in your plan limits until Jun 22, then switch to usage credits to continue.
      What do you want to do?
      ❯ 1. Continue
    TEXT

    refute Hive::AgentLimit.live_limit_menu?(pane)
  end

  def test_from_limit_matches_only_agent_limit_wire_format
    assert Hive::AgentLimit.from_limit?("limits reached")
    assert Hive::AgentLimit.from_limit?("limits reached for claude: Claude Code v2.1.170")
    assert Hive::AgentLimit.from_limit?("  limits reached for codex_agent-1: wall")

    refute Hive::AgentLimit.from_limit?("healthy run said limits reached for claude: in a quote")
    refute Hive::AgentLimit.from_limit?("not limits reached")
    refute Hive::AgentLimit.held?(:review_error, "reason" => "triage_failed",
                                                 "message" => "healthy run said limits reached")
  end

  # Regression for task 47: a finalize agent describing a scrollable-TUI help
  # feature ("scroll limit reached", "window limit") tripped a false
  # limits_reached wall via the old bare `/limit (?:reached|exceeded|reset)/i`.
  # Healthy agent OUTPUT must never classify as a usage wall.
  def test_does_not_classify_ui_feature_limit_text_as_a_wall
    [
      "The viewport scrolls until the scroll limit is reached at the bottom.",
      "Help now shows one window at a time; the page limit reset on resize.",
      "| Viewport | window limit reached | ows |",
      "re-clamped on resize so a shrink keeps a valid position"
    ].each do |line|
      refute Hive::AgentLimit.limit_reached?(line),
             "UI/feature text must not classify as a usage wall: #{line.inspect}"
    end
  end

  def test_detects_usage_credit_and_time_window_walls
    [
      "usage limit reached",
      "credit limit exceeded",
      "token limit reached for this request",
      "5-hour limit reached",
      "weekly limit reached",
      "account limit reached"
    ].each do |line|
      assert Hive::AgentLimit.limit_reached?(line),
             "a real provider wall must still classify: #{line.inspect}"
    end
  end

  private

  def with_env(values)
    original = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def pane_fixture(name)
    File.read(File.expand_path("../fixtures/panes/#{name}", __dir__))
  end
end
