require "test_helper"
require "hive/artifacts/terminal_recorder"

class ArtifactsTerminalRecorderTest < Minitest::Test
  include HiveTestHelper

  def test_records_one_argv_command_as_asciinema_and_plain_text
    Dir.mktmpdir("hive-terminal-recorder") do |root|
      cast = File.join(root, "proof.cast")
      review = File.join(root, "proof.txt")

      result = Hive::Artifacts::TerminalRecorder.new(
        argv: [ RbConfig.ruby, "-e", '$stdout.write("hello\\n")' ],
        cwd: root, cast_path: cast, review_path: review,
        environment: { "PATH" => ENV.fetch("PATH", "") }
      ).record!

      assert_equal 0, result.fetch("exit_status")
      records = File.readlines(cast, chomp: true).map { |line| JSON.parse(line) }
      assert_equal 2, records.first.fetch("version")
      assert records.drop(1).any? { |event| event[1] == "o" && event[2].include?("hello") }
      assert_includes File.read(review), "hello"
      assert_includes File.read(review), "exit 0"
      assert_equal Digest::SHA256.file(cast).hexdigest,
                   result.dig("representations", 0, "sha256")
      assert_equal Digest::SHA256.file(review).hexdigest,
                   result.dig("representations", 1, "sha256")
    end
  end

  def test_records_nonzero_exit_without_a_shell_and_rejects_unsafe_targets
    Dir.mktmpdir("hive-terminal-recorder") do |root|
      cast = File.join(root, "proof.cast")
      review = File.join(root, "proof.txt")
      result = Hive::Artifacts::TerminalRecorder.new(
        argv: [ RbConfig.ruby, "-e", "warn 'bad'; exit 7" ],
        cwd: root, cast_path: cast, review_path: review,
        environment: { "PATH" => ENV.fetch("PATH", "") }
      ).record!

      assert_equal 7, result.fetch("exit_status")
      assert_includes File.read(review), "exit 7"

      error = assert_raises(Hive::Artifacts::TerminalRecorder::CaptureError) do
        Hive::Artifacts::TerminalRecorder.new(
          argv: [], cwd: root, cast_path: cast, review_path: review
        ).record!
      end
      assert_match(/command is required/, error.message)

      error = assert_raises(Hive::Artifacts::TerminalRecorder::CaptureError) do
        Hive::Artifacts::TerminalRecorder.new(
          argv: [ RbConfig.ruby, "-e", "exit" ], cwd: root,
          cast_path: cast, review_path: cast
        ).record!
      end
      assert_match(/distinct paths/, error.message)
    end
  end

  def test_timeout_and_output_limit_leave_no_partial_representations
    Dir.mktmpdir("hive-terminal-recorder-failures") do |root|
      cast = File.join(root, "proof.cast")
      review = File.join(root, "proof.txt")
      recorder = Hive::Artifacts::TerminalRecorder.new(
        argv: [ RbConfig.ruby, "-e", "sleep 10" ], cwd: root,
        cast_path: cast, review_path: review, timeout_seconds: 0.05
      )
      error = assert_raises(Hive::Artifacts::TerminalRecorder::CaptureError) { recorder.record! }
      assert_match(/exceeded/, error.message)
      refute_path_exists cast
      refute_path_exists review

      recorder = Hive::Artifacts::TerminalRecorder.new(
        argv: [ RbConfig.ruby, "-e", "STDOUT.write('x' * #{Hive::Artifacts::TerminalRecorder::MAX_OUTPUT_BYTES + 1})" ],
        cwd: root, cast_path: cast, review_path: review, timeout_seconds: 10
      )
      error = assert_raises(Hive::Artifacts::TerminalRecorder::CaptureError) { recorder.record! }
      assert_match(/exceeds|worker failed/, error.message)
      refute_path_exists cast
      refute_path_exists review
    end
  end

  def test_detached_descendants_are_reaped_and_invalidate_the_capture
    Dir.mktmpdir("hive-terminal-recorder-descendant") do |root|
      cast = File.join(root, "proof.cast")
      review = File.join(root, "proof.txt")
      pid_file = File.join(root, "descendant.pid")
      ready_file = File.join(root, "descendant.ready")
      child = <<~RUBY
        Signal.trap("HUP", "IGNORE")
        Signal.trap("TERM", "IGNORE")
        Process.setsid
        File.write(#{ready_file.inspect}, "ready")
        sleep 30
      RUBY
      command = <<~RUBY
        pid = Process.spawn(#{RbConfig.ruby.inspect}, "-e", #{child.inspect},
                            out: File::NULL, err: File::NULL, close_others: true)
        sleep 0.01 until File.exist?(#{ready_file.inspect})
        File.write(#{pid_file.inspect}, pid.to_s)
      RUBY
      recorder = Hive::Artifacts::TerminalRecorder.new(
        argv: [ RbConfig.ruby, "-e", command ], cwd: root,
        cast_path: cast, review_path: review, timeout_seconds: 5
      )

      error = assert_raises(Hive::Artifacts::TerminalRecorder::CaptureError) { recorder.record! }
      assert_match(/descendant processes/, error.message)
      pid = Integer(File.read(pid_file))
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
      refute_path_exists cast
      refute_path_exists review
    end
  end

  def test_adopted_zombie_descendants_are_reaped_without_invalidating_the_capture
    Dir.mktmpdir("hive-terminal-recorder-zombies") do |root|
      cast = File.join(root, "proof.cast")
      review = File.join(root, "proof.txt")
      command = <<~RUBY
        20.times { fork { sleep 0.001; exit! 0 } }
        exit! 0
      RUBY

      result = Hive::Artifacts::TerminalRecorder.new(
        argv: [ RbConfig.ruby, "-e", command ], cwd: root,
        cast_path: cast, review_path: review, timeout_seconds: 5
      ).record!

      assert_equal 0, result.fetch("exit_status")
      assert_path_exists cast
      assert_path_exists review
    end
  end

  def test_validation_never_overwrites_or_removes_preexisting_representations
    Dir.mktmpdir("hive-terminal-recorder-existing") do |root|
      cast = File.join(root, "proof.cast")
      review = File.join(root, "proof.txt")
      File.write(cast, "owned cast\n")
      File.write(review, "owned review\n")
      recorder = Hive::Artifacts::TerminalRecorder.new(
        argv: [ RbConfig.ruby, "-e", "exit" ], cwd: root,
        cast_path: cast, review_path: review
      )

      error = assert_raises(Hive::Artifacts::TerminalRecorder::CaptureError) { recorder.record! }
      assert_match(/already exists/, error.message)
      assert_equal "owned cast\n", File.read(cast)
      assert_equal "owned review\n", File.read(review)
    end
  end

  def test_worker_uses_the_activated_runtime_path_without_inheriting_ruby_injection
    Dir.mktmpdir("hive-terminal-recorder-runtime") do |root|
      captured = nil
      result = {
        "status" => { "success" => true },
        "internal_error" => false, "timed_out" => false,
        "cleanup_failed" => false, "stdout_overflow" => false,
        "stderr_overflow" => false, "leftover_processes" => false,
        "stdout" => JSON.generate("exit_status" => 0, "representations" => []),
        "stderr" => ""
      }
      fake = lambda do |**attributes|
        captured = attributes
        result
      end

      with_env("HIVE_COVERAGE" => nil, "RUBYOPT" => "-r/untrusted") do
        with_replaced_singleton_method(
          Hive::Web::ProjectCaptureProvider, :capture_command_with_custody, fake
        ) do
          Hive::Artifacts::TerminalRecorder.new(
            argv: [ RbConfig.ruby, "-e", "exit" ], cwd: root,
            cast_path: File.join(root, "proof.cast"),
            review_path: File.join(root, "proof.txt")
          ).record!
        end
      end

      runtime_path = Gem.loaded_specs.fetch("agent-cli-runtime").full_require_paths.first
      assert_includes captured.fetch(:argv), runtime_path
      assert_equal [ "PATH" ], captured.fetch(:environment).keys
    end
  end

  def test_record_normalizes_empty_worker_provider_json_and_configuration_failures
    Dir.mktmpdir("hive-terminal-recorder-normalize") do |root|
      build = lambda do
        Hive::Artifacts::TerminalRecorder.new(
          argv: [ "true" ], cwd: root,
          cast_path: File.join(root, "proof.cast"),
          review_path: File.join(root, "proof.txt")
        )
      end

      recorder = build.call
      recorder.define_singleton_method(:capture_with_custody) { nil }
      assert_raises(Hive::Artifacts::TerminalRecorder::CaptureError) { recorder.record! }

      provider_error = Hive::Web::ProjectCaptureProvider::ProviderError.new("custody")
      recorder = build.call
      recorder.define_singleton_method(:capture_with_custody) { raise provider_error }
      error = assert_raises(Hive::Artifacts::TerminalRecorder::CaptureError) { recorder.record! }
      assert_match(/custody failed/, error.message)

      invalid_result = {
        "status" => { "success" => true }, "internal_error" => false,
        "timed_out" => false, "cleanup_failed" => false,
        "stdout_overflow" => false, "stderr_overflow" => false,
        "leftover_processes" => false, "stdout" => "not-json", "stderr" => ""
      }
      replacement = ->(**) { invalid_result }
      recorder = build.call
      with_replaced_singleton_method(
        Hive::Web::ProjectCaptureProvider, :capture_command_with_custody, replacement
      ) do
        error = assert_raises(Hive::Artifacts::TerminalRecorder::CaptureError) do
          recorder.record!
        end
        assert_match(/invalid output/, error.message)
      end

      recorder = build.call
      recorder.define_singleton_method(:capture_with_custody) { raise ArgumentError, "bad" }
      error = assert_raises(Hive::Artifacts::TerminalRecorder::CaptureError) { recorder.record! }
      assert_match(/configuration is invalid/, error.message)

      recorder = build.call
      recorder.define_singleton_method(:capture) { |*| raise ArgumentError, "bad" }
      assert_raises(Hive::Artifacts::TerminalRecorder::CaptureError) do
        recorder.send(:record_direct!)
      end
    end
  end

  def test_validation_and_direct_capture_cover_native_failure_boundaries
    Dir.mktmpdir("hive-terminal-recorder-boundaries") do |root|
      common = {
        argv: [ "true" ], cwd: root,
        cast_path: File.join(root, "proof.cast"),
        review_path: File.join(root, "proof.txt")
      }
      assert_raises(Hive::Artifacts::TerminalRecorder::CaptureError) do
        Hive::Artifacts::TerminalRecorder.new(**common, timeout_seconds: 0).record!
      end
      assert_raises(Hive::Artifacts::TerminalRecorder::CaptureError) do
        Hive::Artifacts::TerminalRecorder.new(**common, width: 10).record!
      end

      recorder = Hive::Artifacts::TerminalRecorder.new(
        **common.merge(argv: [ "/missing/terminal-command" ])
      )
      assert_raises(Hive::Artifacts::TerminalRecorder::CaptureError) do
        recorder.send(:record_direct!)
      end

      reader = Object.new
      reader.define_singleton_method(:winsize=) { |_| raise RuntimeError, "pty failed" }
      reader.define_singleton_method(:closed?) { false }
      reader.define_singleton_method(:close) { true }
      writer = Object.new
      writer.define_singleton_method(:closed?) { false }
      writer.define_singleton_method(:close) { true }
      recorder = Hive::Artifacts::TerminalRecorder.new(**common)
      with_replaced_singleton_method(PTY, :spawn, ->(*) { [ reader, writer, 123 ] }) do
        with_replaced_singleton_method(Process, :waitpid, ->(*) { raise Errno::ECHILD }) do
          recorder.define_singleton_method(:terminate_group) { |_| nil }
          assert_raises(RuntimeError) { recorder.send(:capture, 0, [], +"") }
        end
      end

      with_replaced_singleton_method(Process, :kill, ->(*) { raise Errno::ESRCH }) do
        fresh = Hive::Artifacts::TerminalRecorder.new(**common)
        assert_nil fresh.send(:terminate_group, 123)
      end
    end
  end
end
