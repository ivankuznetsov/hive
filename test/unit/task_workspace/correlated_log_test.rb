require "test_helper"
require "hive/attempts/store"
require "hive/output_reference"
require "hive/task_workspace/correlated_log"

class TaskWorkspaceCorrelatedLogTest < Minitest::Test
  include HiveTestHelper

  def test_reads_one_verified_bounded_frame_tail_and_fails_inert
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
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
end
