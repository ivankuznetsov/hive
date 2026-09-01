require "test_helper"
require "hive/attempts/repository"
require "hive/output_reference"
require "hive/task_workspace/correlated_log"

class TaskWorkspaceCorrelatedLogTest < Minitest::Test
  include HiveTestHelper

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
