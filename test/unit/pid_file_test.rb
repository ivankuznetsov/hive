require "test_helper"
require "tmpdir"
require "hive/pid_file"

# Covers the stateless module-level helpers Hive::PidFile.alive? / .read
# (the mixin instance methods are exercised via the daemon/babysit commands).
class HivePidFileModuleTest < Minitest::Test
  include HiveTestHelper

  PF = Hive::PidFile

  BoundedReader = Struct.new(:pid_file) do
    include Hive::PidFile
  end

  AliveProcess = Struct.new(:behaviour) do
    def kill(_signal, _pid)
      case behaviour
      when :esrch then raise Errno::ESRCH
      when :eperm then raise Errno::EPERM
      when :range then raise RangeError, "pid out of range"
      else true
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

  def test_read_pid_returns_nil_for_missing_file
    Dir.mktmpdir("hive-pid-file") do |dir|
      assert_nil PF.read_pid(File.join(dir, "absent.pid"))
    end
  end

  def test_read_pid_parses_the_owner_yaml_payload
    Dir.mktmpdir("hive-pid-file") do |dir|
      path = File.join(dir, "daemon.pid")
      File.write(path, { "pid" => 4242, "process_start_time" => nil }.to_yaml)

      assert_equal 4242, PF.read_pid(path)
    end
  end

  def test_read_pid_accepts_legacy_bare_integer_doc
    Dir.mktmpdir("hive-pid-file") do |dir|
      path = File.join(dir, "daemon.pid")
      File.write(path, "4242\n")

      assert_equal 4242, PF.read_pid(path)
    end
  end

  def test_read_pid_rejects_non_positive_pids
    Dir.mktmpdir("hive-pid-file") do |dir|
      zero = File.join(dir, "zero.pid")
      File.write(zero, { "pid" => 0 }.to_yaml)
      negative = File.join(dir, "negative.pid")
      File.write(negative, { "pid" => -1 }.to_yaml)

      assert_nil PF.read_pid(zero)
      assert_nil PF.read_pid(negative)
    end
  end

  def test_read_pid_rejects_non_integer_pid_field
    Dir.mktmpdir("hive-pid-file") do |dir|
      path = File.join(dir, "daemon.pid")
      File.write(path, { "pid" => "not-a-pid" }.to_yaml)

      assert_nil PF.read_pid(path)
    end
  end

  def test_read_pid_returns_nil_for_corrupt_or_unreadable_docs
    Dir.mktmpdir("hive-pid-file") do |dir|
      corrupt = File.join(dir, "corrupt.pid")
      File.write(corrupt, "pid: [")

      assert_nil PF.read_pid(corrupt)

      scalar = File.join(dir, "scalar.pid")
      File.write(scalar, "just-a-string")

      assert_nil PF.read_pid(scalar)
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
