require "test_helper"
require "hive/daemon/health_signal"

class HiveDaemonHealthSignalTest < Minitest::Test
  include HiveTestHelper

  Stat = Struct.new(:mtime, keyword_init: true)

  FakeProfile = Struct.new(:bin, :version_error, keyword_init: true) do
    def check_version!
      raise version_error if version_error

      "2.1.118"
    end
  end

  FakeDoctor = Struct.new(:rows, keyword_init: true) do
    def call
      0
    end
  end

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

  def test_doctor_timeout_folds_into_stable_sentinel_digest
    timeout_digest = nil
    with_replaced_singleton_method(Timeout, :timeout, ->(_sec, *_args, &_block) { raise Timeout::Error }) do
      timeout_digest = Hive::Daemon::HealthSignal.doctor_rows_digest(Hive::Config::DEFAULTS, Dir.pwd, nil)
    end

    # A timed-out in-process doctor must fold into the SAME stable sentinel an
    # errored doctor produces, so the fingerprint stays stable instead of
    # hanging the tick that computes it.
    error_digest = Hive::Daemon::HealthSignal.doctor_rows_digest(
      Hive::Config::DEFAULTS, Dir.pwd, [ { error: "error:Timeout::Error" } ]
    )
    assert_equal error_digest, timeout_digest
  end

  def test_profile_lookup_failure_folds_into_stable_fallback_bin_and_version
    rows = [ { label: "doctor", status: "present" } ]
    # When AgentProfiles.lookup raises, profile_bin falls back to "claude" and
    # profile_version folds to the stable "error:<class>" sentinel. A profile
    # whose bin IS "claude" and whose check_version! raises the same class must
    # therefore produce the IDENTICAL fingerprint.
    raising = with_replaced_singleton_method(Hive::AgentProfiles, :lookup, ->(_name, cfg: nil) { raise KeyError, "no profile" }) do
      fingerprint(:claude_launcher, doctor_rows: rows)
    end
    equivalent = with_replaced_singleton_method(Hive::AgentProfiles, :lookup, lambda { |_name, cfg: nil|
      FakeProfile.new(bin: "claude", version_error: KeyError.new("no profile"))
    }) do
      fingerprint(:claude_launcher, doctor_rows: rows)
    end

    assert_equal equivalent, raising,
                 "a raised lookup must fold to fallback bin 'claude' + 'error:KeyError' version sentinel"
  end

  def test_profile_version_error_sentinel_is_stable_across_messages
    rows = [ { label: "doctor", status: "present" } ]
    first = with_replaced_singleton_method(Hive::AgentProfiles, :lookup, lambda { |_name, cfg: nil|
      FakeProfile.new(bin: "claude", version_error: Hive::AgentError.new("PATH exec error alpha"))
    }) do
      fingerprint(:claude_launcher, doctor_rows: rows)
    end
    second = with_replaced_singleton_method(Hive::AgentProfiles, :lookup, lambda { |_name, cfg: nil|
      FakeProfile.new(bin: "claude", version_error: Hive::AgentError.new("PATH exec error beta"))
    }) do
      fingerprint(:claude_launcher, doctor_rows: rows)
    end

    # profile_version folds only the error CLASS, never the (varying) message,
    # so two failures of the same class must yield the same fingerprint.
    assert_equal first, second, "profile_version must fold class only, not the message"
  end

  def test_doctor_rows_digest_runs_in_process_doctor_when_rows_absent
    digest_a = with_replaced_singleton_method(Hive::Commands::Doctor, :new, lambda { |**_kwargs|
      FakeDoctor.new(rows: [ { label: "claude", status: "present" } ])
    }) do
      Hive::Daemon::HealthSignal.doctor_rows_digest(Hive::Config::DEFAULTS, Dir.pwd, nil)
    end
    digest_b = with_replaced_singleton_method(Hive::Commands::Doctor, :new, lambda { |**_kwargs|
      FakeDoctor.new(rows: [ { label: "claude", status: "missing" } ])
    }) do
      Hive::Daemon::HealthSignal.doctor_rows_digest(Hive::Config::DEFAULTS, Dir.pwd, nil)
    end

    # With rows absent, doctor_rows_digest builds and runs the in-process
    # doctor (doctor.call; doctor.rows inside the Timeout block); the returned
    # rows must flow into the digest so different doctor state differs.
    refute_equal digest_a, digest_b, "in-process doctor rows must drive the digest"
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
