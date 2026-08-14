require "test_helper"
require "hive/artifacts/terminal_recorder"

class ArtifactsTerminalRecorderTest < Minitest::Test
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
      child = <<~RUBY
        Process.setsid
        sleep 30
      RUBY
      command = <<~RUBY
        pid = Process.spawn(#{RbConfig.ruby.inspect}, "-e", #{child.inspect},
                            out: File::NULL, err: File::NULL, close_others: true)
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
end
