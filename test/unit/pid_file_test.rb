require "test_helper"
require "tmpdir"
require "hive/pid_file"

# Covers the stateless module-level helpers Hive::PidFile.alive? / .read /
# .parse_payload / .ownership / .stop (the mixin instance methods are
# exercised via the daemon/babysit commands).
class HivePidFileModuleTest < Minitest::Test
  include HiveTestHelper

  PF = Hive::PidFile

  BoundedReader = Struct.new(:pid_file) do
    include Hive::PidFile
  end

  AliveProcess = Struct.new(:behaviour, :signals) do
    def kill(signal, pid)
      case behaviour
      when :esrch then raise Errno::ESRCH
      when :eperm then raise Errno::EPERM
      when :range then raise RangeError, "pid out of range"
      when :dies_on_signal
        raise Errno::ESRCH unless signal == 0
        signals << [ signal, pid ]
        true
      else
        signals << [ signal, pid ] if signals
        true
      end
    end
  end

  def test_alive_true_for_responsive_process
    assert PF.alive?(4242, process: AliveProcess.new(:ok))
  end

  def test_alive_false_when_process_is_gone
    refute PF.alive?(4242, process: AliveProcess.new(:esrch))
  end

  def test_alive_true_when_owned_by_another_user
    assert PF.alive?(4242, process: AliveProcess.new(:eperm)),
           "EPERM means the process exists but is foreign — still alive"
  end

  def test_alive_false_when_pid_is_out_of_native_range
    refute PF.alive?(10**100, process: AliveProcess.new(:range))
  end

  def test_identity_alive_preserves_legacy_pid_only_records
    assert PF.identity_alive?(
      4242,
      process: AliveProcess.new(:ok),
      start_time_reader: ->(_pid) { raise "legacy identity reader must not run" }
    )
  end

  def test_identity_alive_can_require_a_recorded_start_time
    refute PF.identity_alive?(
      4242,
      require_start_time: true,
      process: AliveProcess.new(:ok),
      start_time_reader: ->(_pid) { raise "missing identity must fail closed" }
    )
  end

  def test_identity_alive_requires_recorded_start_time_to_match
    assert PF.identity_alive?(
      4242, recorded_start_time: "live", process: AliveProcess.new(:ok),
      start_time_reader: ->(_pid) { "live" }
    )
    refute PF.identity_alive?(
      4242, recorded_start_time: "recorded", process: AliveProcess.new(:ok),
      start_time_reader: ->(_pid) { "different" }
    )
    refute PF.identity_alive?(
      4242, recorded_start_time: "recorded", process: AliveProcess.new(:ok),
      start_time_reader: ->(_pid) { nil }
    )
  end

  def test_read_returns_empty_hash_for_missing_file
    Dir.mktmpdir("hive-pid-file") do |dir|
      assert_equal({}, PF.read(File.join(dir, "absent.pid")))
    end
  end

  def test_read_parses_a_mapping
    Dir.mktmpdir("hive-pid-file") do |dir|
      path = File.join(dir, "bot.pid")
      File.write(path, { "pid" => 4242 }.to_yaml)

      assert_equal({ "pid" => 4242 }, PF.read(path))
    end
  end

  def test_read_returns_empty_hash_for_non_mapping_document
    Dir.mktmpdir("hive-pid-file") do |dir|
      path = File.join(dir, "scalar.pid")
      File.write(path, "just-a-string")

      assert_equal({}, PF.read(path))
    end
  end

  def test_parse_payload_parses_the_owner_yaml_mapping
    Dir.mktmpdir("hive-pid-file") do |dir|
      path = File.join(dir, "daemon.pid")
      raw = { "pid" => 4242, "process_start_time" => "boot-1", "started_at" => Time.now.utc.iso8601 }.to_yaml

      payload = PF.parse_payload(raw)

      assert_equal 4242, payload["pid"]
      assert_equal "boot-1", payload["process_start_time"]
      refute payload["_legacy"]
    end
  end

  def test_parse_payload_wraps_a_legacy_bare_integer_doc
    payload = PF.parse_payload("4242\n")

    assert_equal 4242, payload["pid"]
    assert_nil payload["process_start_time"]
    assert payload["_legacy"]
  end

  def test_parse_payload_rejects_corrupt_and_scalar_docs_but_keeps_owner_shaped_payloads
    assert_nil PF.parse_payload("pid: [")
    assert_nil PF.parse_payload("just-a-string")
    # Owner-shaped mappings pass through even with a bad pid field; the
    # positive-Integer gate lives in `stop` / the daemon's own stop path.
    assert_equal({ "pid" => "not-a-pid" }, PF.parse_payload({ "pid" => "not-a-pid" }.to_yaml))
    assert_equal({ "pid" => 0 }, PF.parse_payload({ "pid" => 0 }.to_yaml))
  end

  def test_stop_reports_malformed_for_non_positive_or_non_integer_pids
    Dir.mktmpdir("hive-pid-file") do |dir|
      zero = File.join(dir, "zero.pid")
      File.write(zero, { "pid" => 0 }.to_yaml)
      assert_equal({ status: :malformed, pid: nil }, PF.stop(zero))

      nonint = File.join(dir, "nonint.pid")
      File.write(nonint, { "pid" => "not-a-pid" }.to_yaml)
      assert_equal({ status: :malformed, pid: nil }, PF.stop(nonint))
    end
  end

  def test_ownership_tri_state_over_recorded_and_live_start_times
    verified = { "pid" => 4242, "process_start_time" => "boot-1" }
    reused = { "pid" => 4242, "process_start_time" => "boot-1" }
    unverified = { "pid" => 4242, "process_start_time" => nil }

    with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { "boot-1" }) do
      assert_equal :verified, PF.ownership(verified, 4242)
    end
    with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { "boot-2" }) do
      assert_equal :reused, PF.ownership(reused, 4242)
    end
    with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { "boot-2" }) do
      assert_equal :unverified, PF.ownership(unverified, 4242)
      assert_equal :unverified, PF.ownership(nil, 4242)
    end
    assert_equal :legacy, PF.ownership({ "pid" => 4242, "_legacy" => true }, 4242)
  end

  def test_stop_returns_absent_for_missing_file
    Dir.mktmpdir("hive-pid-file") do |dir|
      assert_equal({ status: :absent, pid: nil }, PF.stop(File.join(dir, "absent.pid")))
    end
  end

  def test_stop_signals_a_verified_owner_payload
    Dir.mktmpdir("hive-pid-file") do |dir|
      path = File.join(dir, "daemon.pid")
      File.write(path, { "pid" => 4242, "process_start_time" => "boot-1" }.to_yaml)
      signals = []

      outcome = with_replaced_singleton_method(
        Hive::Lock, :process_start_time, ->(_pid) { "boot-1" }
      ) do
        PF.stop(path, process: AliveProcess.new(:ok, signals))
      end

      assert_equal({ status: :signalled, pid: 4242 }, outcome)
      assert_includes signals, [ "TERM", 4242 ]
    end
  end

  def test_stop_signals_a_legacy_bare_integer_doc_best_effort
    Dir.mktmpdir("hive-pid-file") do |dir|
      path = File.join(dir, "daemon.pid")
      File.write(path, "4242\n")
      signals = []

      outcome = PF.stop(path, process: AliveProcess.new(:ok, signals))

      assert_equal({ status: :signalled, pid: 4242 }, outcome)
      assert_includes signals, [ "TERM", 4242 ]
    end
  end

  def test_stop_refuses_to_signal_a_reused_pid
    Dir.mktmpdir("hive-pid-file") do |dir|
      path = File.join(dir, "daemon.pid")
      # The recorded start time names a boot that is no longer current:
      # PID 4242 now belongs to an unrelated process.
      File.write(path, { "pid" => 4242, "process_start_time" => "boot-1" }.to_yaml)
      signals = []

      outcome = with_replaced_singleton_method(
        Hive::Lock, :process_start_time, ->(_pid) { "boot-2" }
      ) do
        PF.stop(path, process: AliveProcess.new(:ok, signals))
      end

      assert_equal({ status: :reused, pid: 4242 }, outcome)
      refute_includes signals, [ "TERM", 4242 ], "a reused PID must never be signalled"
    end
  end

  def test_stop_refuses_to_signal_an_unverified_pid
    Dir.mktmpdir("hive-pid-file") do |dir|
      path = File.join(dir, "daemon.pid")
      # No recorded start time (and none recoverable): identity cannot be
      # proven, so bystander safety forbids signalling.
      File.write(path, { "pid" => 4242, "process_start_time" => nil }.to_yaml)
      signals = []

      outcome = with_replaced_singleton_method(
        Hive::Lock, :process_start_time, ->(_pid) { nil }
      ) do
        PF.stop(path, process: AliveProcess.new(:ok, signals))
      end

      assert_equal({ status: :unverified, pid: 4242 }, outcome)
      refute_includes signals, [ "TERM", 4242 ]
    end
  end

  def test_stop_reports_stale_malformed_and_unreadable_files
    Dir.mktmpdir("hive-pid-file") do |dir|
      stale = File.join(dir, "stale.pid")
      File.write(stale, { "pid" => 4242, "_legacy" => true }.to_yaml)
      assert_equal({ status: :stale, pid: 4242 }, PF.stop(stale, process: AliveProcess.new(:esrch)))

      malformed = File.join(dir, "malformed.pid")
      File.write(malformed, "this is not a PID payload\n")
      assert_equal({ status: :malformed, pid: nil }, PF.stop(malformed))

      corrupt = File.join(dir, "corrupt.pid")
      File.write(corrupt, "pid: [")
      assert_equal({ status: :malformed, pid: nil }, PF.stop(corrupt))
    end
  end

  def test_stop_treats_a_mid_stop_death_as_stale
    Dir.mktmpdir("hive-pid-file") do |dir|
      path = File.join(dir, "daemon.pid")
      File.write(path, { "pid" => 4242, "_legacy" => true }.to_yaml)
      signals = []

      outcome = PF.stop(path, process: AliveProcess.new(:dies_on_signal, signals))

      assert_equal({ status: :stale, pid: 4242 }, outcome)
    end
  end

  def test_read_propagates_parse_errors_for_the_caller_to_handle
    Dir.mktmpdir("hive-pid-file") do |dir|
      path = File.join(dir, "corrupt.pid")
      File.write(path, "pid: [")

      assert_raises(Psych::Exception) { PF.read(path) }
    end
  end

  def test_bounded_reader_uses_inode_checked_fallback_without_o_nofollow
    Dir.mktmpdir("hive-pid-file") do |dir|
      path = File.join(dir, "daemon.pid")
      File.write(path, { "pid" => 4242 }.to_yaml)
      reader = BoundedReader.new(path)
      original = File.method(:const_defined?)
      replacement = lambda do |name, *args|
        name == :NOFOLLOW ? false : original.call(name, *args)
      end

      payload = with_replaced_singleton_method(File, :const_defined?, replacement) do
        reader.read_pid_file_payload(max_bytes: 1024)
      end

      assert_equal({ "pid" => 4242 }, payload)
    end
  end

  def test_bounded_reader_fallback_rejects_path_replaced_after_open
    Dir.mktmpdir("hive-pid-file") do |dir|
      path = File.join(dir, "daemon.pid")
      replacement_path = File.join(dir, "replacement.pid")
      File.write(path, { "pid" => 4242 }.to_yaml)
      File.write(replacement_path, { "pid" => 9999 }.to_yaml)
      reader = BoundedReader.new(path)
      original_const_defined = File.method(:const_defined?)
      original_open = File.method(:open)

      payload = with_replaced_singleton_method(
        File, :const_defined?,
        ->(name, *args) { name == :NOFOLLOW ? false : original_const_defined.call(name, *args) }
      ) do
        with_replaced_singleton_method(File, :open, lambda { |*args, &block|
          original_open.call(*args) do |opened|
            File.unlink(path)
            File.symlink(replacement_path, path)
            block.call(opened)
          end
        }) do
          reader.read_pid_file_payload(max_bytes: 1024)
        end
      end

      assert_nil payload
    end
  end

  def test_bounded_reader_fails_closed_when_open_races_with_the_probe
    Dir.mktmpdir("hive-pid-file") do |dir|
      path = File.join(dir, "daemon.pid")
      File.write(path, { "pid" => 4242 }.to_yaml)
      reader = BoundedReader.new(path)

      payload = with_replaced_singleton_method(
        File, :open, ->(*) { raise Errno::EIO, "pid file became unreadable" }
      ) do
        reader.read_pid_file_payload(max_bytes: 1024)
      end

      assert_nil payload
    end
  end
end
