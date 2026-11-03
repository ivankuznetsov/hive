require "test_helper"
require "hive/attempts/repository"
require "hive/attempts/stream_log"
require "hive/output_reference"
require "hive/task_workspace/correlated_log"
require "hive/agent"
require "hive/task"
require "hive/commands/task"
require "hive/task_workspace/publication"

class TaskWorkspaceCorrelatedLogTest < Minitest::Test
  include HiveTestHelper

  def test_failed_spawns_preserve_original_identity_in_sealed_task_log_after_long_output
    with_tmp_dir do |root|
      paths = []
      %w[0.153.4 unknown].each_with_index do |version, index|
        attempt_id = "11111111-1111-1111-1111-11111111111#{index}"
        folder = File.join(root, ".hive-state/stages/4-execute", "diagnostic-#{index}")
        FileUtils.mkdir_p(folder)
        prepare_test_task_run(folder)
        task = Hive::Task.new(folder)
        executable = File.join(root, ("CLI 空間/" * 25), %(codex "#{index}"))
        paths << executable
        FileUtils.mkdir_p(File.dirname(executable))
        File.write(executable, <<~SH)
          #!/bin/sh
          if [ "$1" = --version ]; then echo '#{version}'; exit; fi
          echo "The 'gpt-6-sol' model is not supported when using Codex with a ChatGPT account."
          exit 1
        SH
        File.chmod(0o755, executable)
        frames_path = File.join(root, "streams", "#{attempt_id}.frames")
        writer = Hive::Attempts::StreamLog.new(frames_path)
        read_pipe, write_pipe = IO.pipe
        result_path = File.join(root, "result-#{index}.json")
        script = <<~'RUBY'
          require "hive/agent"
          require "hive/task"
          context = Hive::Attempts::Context.send(:new, attempt_id: ARGV[1], task_generation: 1,
            task_slug: File.basename(ARGV[0]))
          Hive::Attempts::Context.define_singleton_method(:current) { context }
          $stderr.sync = true
          3000.times { |line| $stderr.puts("prior output #{line} #{'x' * 100}") }
          result = Hive::Agent.new(task: Hive::Task.new(ARGV[0]), prompt: "private", max_budget_usd: nil,
            timeout_sec: 5).run!
          File.write(ARGV[2], JSON.generate(result.slice(:status, :error_reason,
            :error_message, :diagnostic_reference)))
        RUBY
        child = Process.spawn({ "HIVE_CLAUDE_BIN" => executable }, RbConfig.ruby,
          "-I#{File.expand_path('../../../lib', __dir__)}", "-e", script,
          folder, attempt_id, result_path, err: write_pipe, out: File::NULL)
        write_pipe.close
        while (chunk = read_pipe.read(16_384))
          writer.append("stderr", chunk)
        end
        read_pipe.close
        _, status = Process.wait2(child)
        assert_predicate status, :success?, Hive::Attempts::StreamLog.read(writer.path).last(3).map(&:bytes).join
        writer.close
        result = JSON.parse(File.read(result_path))
        assert_equal "error", result.fetch("status")
        assert_equal "model_unsupported", result.fetch("error_reason")
        assert_equal "attempt:#{attempt_id}", result.fetch("diagnostic_reference")
        refute_includes result.fetch("error_message"), executable
        assert_match(/hive task (?:[0-9]+|diagnostic-#{index}) --log/, result.fetch("error_message"))
        marker = Hive::Markers.current(task.state_file)
        assert_includes marker.attrs.fetch("message"), "attempt:#{attempt_id}"
        assert_operator Hive::Markers.format_attr(marker.attrs.fetch("message")).bytesize, :<=, 200
        refute marker.attrs.key?("retry_after")

        reference = Hive::OutputReference.build(frames_path, root: root)
        payloads = Hive::RuntimeControlPlane::PayloadStore.new(root: root)
        sealed = payloads.seal(frames_path,
          expected_sha256: reference.fetch("sha256"), expected_size: reference.fetch("size"))
          .slice("path", "size", "sha256")
        File.unlink(frames_path)
        reader = Hive::TaskWorkspace::CorrelatedLog.new(root: root,
          reference_resolver: ->(value) { value == reference ? sealed : nil })
        command = Hive::Commands::Task.new(task.slug, log: true, log_reader: reader)
        document = { "diagnostic" => { "log" => { "state" => "current", "reference" => reference } } }
        output, errors = capture_io { command.send(:emit, document) }
        assert_empty errors
        assert_includes output, executable
        assert_includes output, "version=#{version}"
        assert_includes output, "agents.claude.bin"
        assert_includes output, "agents.claude.min_version"
        assert_includes output, "diagnostic=attempt:#{attempt_id}"
        refute_includes output, "prior output 0 "
        refute_includes output, paths.first if index.positive?
        publication = Hive::TaskWorkspace::Publication.allocate
        published = publication.send(:scrub_paths, output)
        refute_includes published, root
        assert_includes published, "[REDACTED:path]"
      ensure
        writer&.close unless writer&.closed?
        read_pipe&.close unless read_pipe&.closed?
        write_pipe&.close unless write_pipe&.closed?
      end
    end
  end

  def test_reads_one_verified_bounded_frame_tail_and_fails_inert
    with_tmp_dir do |root|
      store = Hive::Attempts::Repository.new(root: root, migrate: true)
      writer = store.log_archive.open_writer("attempt-log")
      writer.append("stdout", "receipt-correlated line\n")
      writer.close
      path = store.log_archive.hot_path("attempt-log")
      reference = Hive::OutputReference.build(path, root: store.root)
      reader = Hive::TaskWorkspace::CorrelatedLog.new(root: store.root)

      log = reader.read(reference)

      assert_equal "attempt-log.frames", log.fetch("path")
      assert_equal "receipt-correlated line\n", log.fetch("tail")
      refute_includes log.to_s, root
      assert_nil reader.read(nil)
      assert_nil reader.read(reference.merge("sha256" => "0" * 64))
      assert_nil reader.read(
        reference.merge("size" => Hive::TaskWorkspace::CorrelatedLog::MAX_BYTES + 1)
      )
    ensure
      writer&.close unless writer&.closed?
    end
  end

  def test_resolves_an_original_receipt_reference_to_content_addressed_bytes
    with_tmp_dir do |root|
      payloads = Hive::RuntimeControlPlane::PayloadStore.new(root: root)
      frame = JSON.generate(
        "sequence" => 1, "timestamp" => Time.now.utc.iso8601(6),
        "channel" => "stdout", "data" => Base64.strict_encode64("sealed line\n")
      ) + "\n"
      source = payloads.write_open(
        attempt_id: "attempt-1", name: "attempt-1.frames", bytes: frame
      )
      original = Hive::OutputReference.build(source, root: root)
      sealed = payloads.seal(
        source, expected_sha256: original.fetch("sha256"),
        expected_size: original.fetch("size")
      ).slice("path", "size", "sha256")
      File.unlink(source)
      reader = Hive::TaskWorkspace::CorrelatedLog.new(
        root: root, reference_resolver: ->(reference) { reference == original ? sealed : nil }
      )

      assert_equal "sealed line\n", reader.read(original).fetch("tail")
    end
  end

  def test_refuses_symlinks_even_when_the_reference_shape_is_valid
    with_tmp_dir do |root|
      File.write(File.join(root, "outside.frames"), "secret\n")
      FileUtils.mkdir_p(File.join(root, "logs"))
      File.symlink(File.join(root, "outside.frames"), File.join(root, "logs", "linked.frames"))
      reference = {
        "path" => "logs/linked.frames", "size" => 7,
        "sha256" => Digest::SHA256.hexdigest("secret\n")
      }

      assert_nil Hive::TaskWorkspace::CorrelatedLog.new(root: root).read(reference)
    end
  end

  def test_rejects_an_invalid_root_and_bounds_partial_or_malformed_tails
    assert_raises(ArgumentError) do
      Hive::TaskWorkspace::CorrelatedLog.new(root: "/definitely/missing/attempt-root")
    end

    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, "logs"))
      text = "discarded line\n" + ("x" * (Hive::TaskWorkspace::CorrelatedLog::TAIL_BYTES + 32))
      text_path = File.join(root, "logs", "large.log")
      File.binwrite(text_path, text)
      text_reference = Hive::OutputReference.build(text_path, root: root)
      text_log = Hive::TaskWorkspace::CorrelatedLog.new(root: root).read(text_reference)
      assert_operator text_log.fetch("tail").bytesize,
                      :<=, Hive::TaskWorkspace::CorrelatedLog::TAIL_BYTES
      refute_includes text_log.fetch("tail"), "discarded line"

      frames_path = File.join(root, "logs", "malformed.frames")
      File.binwrite(frames_path, "{not-json}\n")
      frames_reference = Hive::OutputReference.build(frames_path, root: root)
      frames_log = Hive::TaskWorkspace::CorrelatedLog.new(root: root).read(frames_reference)
      assert_equal "", frames_log.fetch("tail")
    end
  end
end
