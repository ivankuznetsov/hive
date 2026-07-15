require "test_helper"
require "hive/refactor_patrol/capability_probe"

class HiveRefactorPatrolCapabilityProbeTest < Minitest::Test
  include HiveTestHelper

  Status = Struct.new(:success?)

  def test_success_returns_exact_local_executable_without_network_dependency
    with_tmp_dir do |dir|
      executable = File.join(dir, "hive-local")
      File.write(executable, "#!/bin/sh\n")
      FileUtils.chmod(0o755, executable)
      calls = []
      runner = lambda do |argv, chdir:, timeout:|
        calls << [ argv, chdir, timeout ]
        [ "Usage: hive refactor-patrol PROJECT", "", Status.new(true) ]
      end

      result = Hive::RefactorPatrol::CapabilityProbe.new(executable: executable, runner: runner).call(dir)

      assert result.ok?
      assert_equal File.realpath(executable), result.executable
      assert_equal [ File.realpath(executable), "help", "refactor-patrol" ], calls.first.first
      assert_equal File.realpath(dir), calls.first[1]
    end
  end

  def test_missing_nonzero_and_timeout_are_typed_without_dispatch
    with_tmp_dir do |dir|
      missing = Hive::RefactorPatrol::CapabilityProbe.new(executable: File.join(dir, "missing")).call(dir)
      refute missing.ok?
      assert_equal "capability_missing", missing.reason

      executable = File.join(dir, "hive-local")
      File.write(executable, "#!/bin/sh\n")
      FileUtils.chmod(0o755, executable)
      nonzero = Hive::RefactorPatrol::CapabilityProbe.new(
        executable: executable,
        runner: ->(_argv, chdir:, timeout:) { [ "", "boom", Status.new(false) ] }
      ).call(dir)
      assert_equal "capability_unrunnable", nonzero.reason
      assert_equal "boom", nonzero.evidence.fetch("stderr")

      timed_out = Hive::RefactorPatrol::CapabilityProbe.new(
        executable: executable,
        runner: ->(_argv, chdir:, timeout:) { raise Timeout::Error }
      ).call(dir)
      assert_equal "capability_unrunnable", timed_out.reason
      assert_equal "timeout", timed_out.evidence.fetch("error")
    end
  end

  def test_default_runner_probes_real_executable
    with_tmp_dir do |dir|
      executable = File.join(dir, "hive-local")
      File.write(executable, "#!/bin/sh\necho 'hive refactor-patrol PROJECT'\n")
      FileUtils.chmod(0o755, executable)

      assert Hive::RefactorPatrol::CapabilityProbe.new(executable: executable, timeout_sec: 2).call(dir).ok?
    end
  end
end
