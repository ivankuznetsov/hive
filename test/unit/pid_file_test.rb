require "test_helper"
require "tmpdir"
require "hive/pid_file"

# Covers the stateless module-level helpers Hive::PidFile.alive? / .read
# (the mixin instance methods are exercised via the daemon/babysit commands).
class HivePidFileModuleTest < Minitest::Test
  PF = Hive::PidFile

  AliveProcess = Struct.new(:behaviour) do
    def kill(_signal, _pid)
      case behaviour
      when :esrch then raise Errno::ESRCH
      when :eperm then raise Errno::EPERM
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

  def test_read_propagates_parse_errors_for_the_caller_to_handle
    Dir.mktmpdir("hive-pid-file") do |dir|
      path = File.join(dir, "corrupt.pid")
      File.write(path, "pid: [")

      assert_raises(Psych::Exception) { PF.read(path) }
    end
  end
end
