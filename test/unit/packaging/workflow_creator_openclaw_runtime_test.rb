require "test_helper"
require "digest"
require_relative "../../../packaging/live_agent_skills/workflow_creator_openclaw_runtime"

class WorkflowCreatorOpenClawRuntimeTest < Minitest::Test
  include HiveTestHelper

  Runtime = HiveLiveAgentProof::WorkflowCreatorOpenClawRuntime
  LAUNCHER_SHA256 = Digest::SHA256.hexdigest("launcher")

  def test_captures_and_reverifies_a_regular_owned_runtime_tree
    with_runtime do |root|
      seal = Runtime.capture!(root:, launcher_sha256: LAUNCHER_SHA256)

      assert_equal Runtime::SCHEMA, seal.value.fetch("schema")
      assert_equal 3, seal.value.fetch("file_count")
      assert_equal 4, seal.value.fetch("directory_count")
      assert_equal seal.value,
                   Runtime.verify!(runtime_install: seal.value, launcher_sha256: LAUNCHER_SHA256)
    end
  end

  def test_file_or_symlink_drift_fails_closed
    with_runtime do |root|
      seal = Runtime.capture!(root:, launcher_sha256: LAUNCHER_SHA256)
      File.binwrite(File.join(root, "node_modules", "openclaw", "entry.js"), "changed\n")

      assert_raises(Runtime::Error) do
        Runtime.verify!(runtime_install: seal.value, launcher_sha256: LAUNCHER_SHA256)
      end
    end

    with_runtime do |root|
      seal = Runtime.capture!(root:, launcher_sha256: LAUNCHER_SHA256)
      link = File.join(root, "node_modules", ".bin", "openclaw")
      File.unlink(link)
      File.symlink("../openclaw/other.js", link)

      assert_raises(Runtime::Error) do
        Runtime.verify!(runtime_install: seal.value, launcher_sha256: LAUNCHER_SHA256)
      end
    end
  end

  def test_escaping_symlink_and_writable_tree_are_rejected
    with_tmp_dir do |root|
      File.symlink("/tmp", File.join(root, "escape"))
      assert_raises(Runtime::Error) { Runtime.capture!(root:, launcher_sha256: LAUNCHER_SHA256) }
    end

    with_runtime do |root|
      directory = File.join(root, "node_modules")
      File.chmod(0o777, directory)
      assert_raises(Runtime::Error) { Runtime.capture!(root:, launcher_sha256: LAUNCHER_SHA256) }
    ensure
      File.chmod(0o700, directory) if directory && File.exist?(directory)
    end
  end

  private

  def with_runtime
    with_tmp_dir do |root|
      package = File.join(root, "node_modules", "openclaw")
      bin = File.join(root, "node_modules", ".bin")
      FileUtils.mkdir_p([ package, bin ], mode: 0o700)
      File.binwrite(File.join(package, "entry.js"), "entry\n")
      File.binwrite(File.join(package, "other.js"), "other\n")
      File.symlink("../openclaw/entry.js", File.join(bin, "openclaw"))
      yield root
    end
  end
end
