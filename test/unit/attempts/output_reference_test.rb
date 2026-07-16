require "test_helper"
require "hive/attempts/output_reference"

class AttemptsOutputReferenceTest < Minitest::Test
  include HiveTestHelper

  def test_build_and_verify_use_canonical_relative_paths_and_integrity
    with_tmp_dir do |root|
      path = File.join(root, "outputs", "attempt-1", "result.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, "{}")

      reference = Hive::Attempts::OutputReference.build(path, root: root)

      assert_equal "outputs/attempt-1/result.json", reference.fetch("path")
      assert_equal 2, reference.fetch("size")
      assert_match(/\A[0-9a-f]{64}\z/, reference.fetch("sha256"))
      assert Hive::Attempts::OutputReference.verify(reference, root: root)
    end
  end

  def test_rejects_escape_absolute_and_modified_files
    with_tmp_dir do |root|
      outside = File.join(File.dirname(root), "outside-#{Process.pid}")
      File.binwrite(outside, "secret")
      assert_raises(Hive::Attempts::InvalidOutputReference) do
        Hive::Attempts::OutputReference.build(outside, root: root)
      end
      assert_raises(Hive::Attempts::InvalidOutputReference) do
        Hive::Attempts::OutputReference.validate_shape!(
          { "path" => "/tmp/result", "size" => 1, "sha256" => "0" * 64 }
        )
      end

      path = File.join(root, "result")
      File.binwrite(path, "one")
      reference = Hive::Attempts::OutputReference.build(path, root: root)
      File.binwrite(path, "two-two")
      refute Hive::Attempts::OutputReference.verify(reference, root: root)
    ensure
      FileUtils.rm_f(outside) if outside
    end
  end
end
