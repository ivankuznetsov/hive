require "test_helper"
require_relative "../../../packaging/release_candidate/process_teardown"

class ReleaseCandidateProcessTeardownTest < Minitest::Test
  def test_bounds_output_and_records_success
    Dir.mktmpdir("release-candidate-process") do |dir|
      target = Struct.new(:role, :executable, :state_root).new(
        "candidate", RbConfig.ruby, dir
      )
      runner = HiveReleaseCandidate::ProcessTeardown.new(output_limit: 32)

      receipt = runner.capture(
        target: target,
        argv: [ "-e", "$stdout.write('o' * 80); $stderr.write('e' * 80)" ],
        environment: {}, cwd: dir, label: "bounded"
      )

      assert_equal "passed", receipt.fetch("status")
      assert_operator receipt.fetch("stdout").bytesize, :<=, 32
      assert_operator receipt.fetch("stderr").bytesize, :<=, 32
      assert receipt.fetch("stdout_truncated")
      assert receipt.fetch("stderr_truncated")
    end
  end

  def test_teardown_fails_when_daemon_tui_web_or_service_survives
    teardown = HiveReleaseCandidate::ProcessTeardown.new(
      process_alive: ->(pid) { pid == 22 },
      service_active: ->(name) { name == "hive-web" },
      signaler: ->(_signal, _target) {},
      sleeper: ->(_seconds) {}
    )

    error = assert_raises(HiveReleaseCandidate::Error) do
      teardown.verify!(
        processes: [
          { "kind" => "daemon", "pid" => 11, "pgid" => 11 },
          { "kind" => "tui", "pid" => 22, "pgid" => 22 }
        ],
        services: %w[hive-daemon hive-web]
      )
    end

    assert_includes error.message, "tui"
    assert_includes error.message, "hive-web"
  end

  def test_capture_does_not_inherit_host_environment_and_rejects_unsafe_argv
    Dir.mktmpdir("release-candidate-process") do |dir|
      target = Struct.new(:role, :executable, :state_root).new(
        "candidate", RbConfig.ruby, dir
      )
      runner = HiveReleaseCandidate::ProcessTeardown.new
      ENV["HIVE_U4_HOST_SECRET"] = "must-not-leak"
      receipt = runner.capture(
        target: target,
        argv: [ "-e", "print ENV.fetch('HIVE_U4_HOST_SECRET', 'absent')" ],
        environment: { "PATH" => "/usr/bin:/bin" },
        cwd: dir, label: "closed-env"
      )
      assert_equal "absent", receipt.fetch("stdout")

      assert_raises(HiveReleaseCandidate::UsageError) do
        runner.capture(
          target: target, argv: [ "bad\0argument" ],
          environment: {}, cwd: dir, label: "unsafe"
        )
      end
    ensure
      ENV.delete("HIVE_U4_HOST_SECRET")
    end
  end
end
