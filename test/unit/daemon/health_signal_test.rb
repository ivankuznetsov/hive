require "test_helper"
require "hive/daemon/health_signal"

class HiveDaemonHealthSignalTest < Minitest::Test
  include HiveTestHelper

  Stat = Struct.new(:mtime, keyword_init: true)

  def fingerprint(category, **kwargs)
    Hive::Daemon::HealthSignal.fingerprint(
      category: category,
      config: Hive::Config::DEFAULTS,
      project_root: Dir.pwd,
      **kwargs
    )
  end

  def test_same_inputs_produce_stable_fingerprint
    rows = [
      { label: "b", status: "present" },
      { status: "present", label: "a" }
    ]

    first = fingerprint(:claude_launcher, doctor_rows: rows)
    second = fingerprint(:claude_launcher, doctor_rows: rows.reverse)

    assert_equal first, second
  end

  def test_codex_home_change_changes_codex_fingerprint_only
    rows = [ { label: "doctor", status: "present" } ]
    codex_a = fingerprint(:codex_auth, env: { "CODEX_HOME" => "/tmp/codex-a" })
    codex_b = fingerprint(:codex_auth, env: { "CODEX_HOME" => "/tmp/codex-b" })
    claude_a = fingerprint(:claude_launcher, env: { "CODEX_HOME" => "/tmp/codex-a" }, doctor_rows: rows)
    claude_b = fingerprint(:claude_launcher, env: { "CODEX_HOME" => "/tmp/codex-b" }, doctor_rows: rows)

    refute_equal codex_a, codex_b
    assert_equal claude_a, claude_b
  end

  def test_auth_json_mtime_changes_codex_fingerprint
    with_tmp_dir do |dir|
      auth = File.join(dir, "auth.json")
      File.write(auth, "{}")
      first = fingerprint(:codex_auth, env: { "CODEX_HOME" => dir })
      File.utime(Time.now + 10, Time.now + 10, auth)
      second = fingerprint(:codex_auth, env: { "CODEX_HOME" => dir })

      refute_equal first, second
    end
  end

  def test_wrapper_mtime_changes_claude_fingerprint
    rows = [ { label: "doctor", status: "present" } ]
    calls = 0
    with_replaced_singleton_method(Hive::Daemon::HealthSignal, :stat_for, lambda { |path|
      if path.to_s.end_with?("interactive_claude_wrapper.sh")
        calls += 1
        Stat.new(mtime: Time.at(calls))
      else
        nil
      end
    }) do
      first = fingerprint(:claude_launcher, doctor_rows: rows)
      second = fingerprint(:claude_launcher, doctor_rows: rows)

      refute_equal first, second
    end
  end

  def test_unknown_category_uses_stable_unknown_reason_fingerprint
    unknown = fingerprint(:mystery_category)

    refute_equal unknown, fingerprint(:codex_auth)
    refute_equal unknown, fingerprint(:claude_launcher, doctor_rows: [])
    assert_equal unknown, fingerprint(:mystery_category), "unknown-category fingerprint must be stable"
  end

  def test_changed_or_fallback_gate_allows_first_changed_and_elapsed_fallback
    now = Time.utc(2026, 6, 29, 12, 0, 0)

    assert Hive::Daemon::HealthSignal.changed_or_fallback?(
      current_fingerprint: "a",
      last_fingerprint: nil,
      last_attempt_at: nil,
      now: now
    )
    assert Hive::Daemon::HealthSignal.changed_or_fallback?(
      current_fingerprint: "b",
      last_fingerprint: "a",
      last_attempt_at: now - 10,
      now: now
    )
    refute Hive::Daemon::HealthSignal.changed_or_fallback?(
      current_fingerprint: "a",
      last_fingerprint: "a",
      last_attempt_at: now - 10,
      now: now
    )
    assert Hive::Daemon::HealthSignal.changed_or_fallback?(
      current_fingerprint: "a",
      last_fingerprint: "a",
      last_attempt_at: now - Hive::Daemon::HealthSignal::FALLBACK_REPROBE_SEC,
      now: now
    )
  end
end
