require "test_helper"
require "hive/attempts/output_reference"
require "hive/attempts/store"

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

  def test_rejects_missing_files_invalid_integrity_and_unverifiable_references
    with_tmp_dir do |root|
      assert_raises(Hive::Attempts::InvalidOutputReference) do
        Hive::Attempts::OutputReference.build(File.join(root, "missing"), root: root)
      end

      base = { "path" => "result", "size" => 1, "sha256" => "0" * 64 }
      assert_raises(Hive::Attempts::InvalidOutputReference) do
        Hive::Attempts::OutputReference.validate_shape!(base.merge("size" => -1))
      end
      assert_raises(Hive::Attempts::InvalidOutputReference) do
        Hive::Attempts::OutputReference.validate_shape!(base.merge("sha256" => "BAD"))
      end
      refute Hive::Attempts::OutputReference.verify(base.merge("path" => "../escape"), root: root)
    end
  end

  def test_projection_reader_reads_only_verified_bounded_output_bytes
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      path = store.output_path("attempt-1", "diagnostic.json", create_directory: true)
      File.binwrite(path, "typed diagnostic")
      reference = Hive::Attempts::OutputReference.build(path, root: root)
      reader = store.projection_reader

      assert_equal "typed diagnostic", reader.read_output(reference, max_bytes: 64)
      assert_raises(Hive::Attempts::StoreError) do
        reader.read_output(reference, max_bytes: 0)
      end
      assert_raises(Hive::Attempts::StoreError) do
        reader.read_output(reference, max_bytes: 4)
      end

      File.binwrite(path, "tampered bytes")
      assert_raises(Hive::Attempts::StoreError) do
        reader.read_output(reference, max_bytes: 64)
      end
      assert_raises(Hive::Attempts::StoreError) do
        reader.read_output(reference.merge("path" => "../private.log"), max_bytes: 64)
      end


      target = store.output_path("attempt-1", "target.json")
      File.binwrite(target, "typed diagnostic")
      File.unlink(path)
      File.symlink(target, path)
      assert_raises(Hive::Attempts::StoreError) do
        reader.read_output(reference, max_bytes: 64)
      end

      real_parent = store.output_directory("attempt-real", create: true)
      redirected_path = File.join(real_parent, "diagnostic.json")
      File.binwrite(redirected_path, "typed diagnostic")
      File.symlink(real_parent, File.join(store.outputs_root, "attempt-link"))
      redirected_reference = {
        "path" => "outputs/attempt-link/diagnostic.json",
        "size" => 16,
        "sha256" => Digest::SHA256.hexdigest("typed diagnostic")
      }
      assert_raises(Hive::Attempts::StoreError) do
        reader.read_output(redirected_reference, max_bytes: 64)
      end

      linked_target = store.output_path("attempt-real", "linked-target.json")
      File.binwrite(linked_target, "linked diagnostic")
      linked_path = store.output_path("attempt-real", "linked-diagnostic.json")
      File.link(linked_target, linked_path)
      linked_reference = Hive::Attempts::OutputReference.build(linked_path, root: root)
      assert_raises(Hive::Attempts::StoreError) do
        reader.read_output(linked_reference, max_bytes: 64)
      end
    end
  end
end
