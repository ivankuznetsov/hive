require "test_helper"
require "hive/artifacts/outcome_evidence/legacy_capture_reader"

class OutcomeEvidenceLegacyCaptureReaderTest < Minitest::Test
  include HiveTestHelper

  def test_missing_corrupt_and_symlinked_manifests_are_non_authoritative
    with_tmp_dir do |dir|
      reader = Hive::Artifacts::OutcomeEvidence::LegacyCaptureReader.new(dir)
      assert_nil reader.read

      media = File.join(dir, "media")
      FileUtils.mkdir_p(media)
      manifest = File.join(media, "capture-manifest.json")
      File.write(manifest, "{")
      assert_nil reader.read

      FileUtils.rm_f(manifest)
      target = File.join(dir, "outside.json")
      File.write(target, "{}")
      File.symlink(target, manifest)
      assert_nil reader.read
    end
  end
end
