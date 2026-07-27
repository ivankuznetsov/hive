require "test_helper"
require "digest"
require "fileutils"
require "json"
require_relative "../../../packaging/release_candidate/asset_verifier"

class ReleaseCandidateAssetVerifierTest < Minitest::Test
  include HiveTestHelper

  def test_verifies_exact_private_cache_and_rejects_substitution_symlink_and_extras
    with_tmp_dir do |dir|
      bytes = "authenticated gem bytes"
      artifact = descriptor("hive-cli-0.6.9.gem", bytes)
      File.binwrite(File.join(dir, artifact.fetch("filename")), bytes)
      verifier = HiveReleaseCandidate::AssetVerifier.new(cache_root: dir)

      result = verifier.verify_set!([ artifact ])
      assert_equal artifact.fetch("sha256"), result.first.fetch("sha256")

      File.binwrite(File.join(dir, artifact.fetch("filename")), "substituted")
      error = assert_raises(HiveReleaseCandidate::Error) { verifier.verify_set!([ artifact ]) }
      assert_match(/size|digest/, error.message)

      FileUtils.rm_f(File.join(dir, artifact.fetch("filename")))
      outside = File.join(File.dirname(dir), "outside.gem")
      File.binwrite(outside, bytes)
      File.symlink(outside, File.join(dir, artifact.fetch("filename")))
      error = assert_raises(HiveReleaseCandidate::Error) { verifier.verify_set!([ artifact ]) }
      assert_includes error.message, "regular file"
    end
  end

  def test_missing_assets_return_exact_authenticated_fetch_argv_without_fetching
    with_tmp_dir do |dir|
      artifact = descriptor("hive-cli-0.6.9.gem", "bytes")
      verifier = HiveReleaseCandidate::AssetVerifier.new(cache_root: dir)

      inventory = verifier.inventory([ artifact ])

      assert_equal "missing", inventory.first.fetch("status")
      assert_equal(
        [ "gh", "release", "download", "v0.6.9", "--repo", "ivankuznetsov/hive",
          "--pattern", "hive-cli-0.6.9.gem", "--dir", dir ],
        inventory.first.fetch("fetch_argv")
      )
      refute File.exist?(File.join(dir, artifact.fetch("filename")))
    end
  end

  def test_rejects_unmanifested_files_and_archive_traversal
    with_tmp_dir do |dir|
      artifact = descriptor("hive-cli-0.6.9.gem", "bytes")
      File.binwrite(File.join(dir, artifact.fetch("filename")), "bytes")
      File.binwrite(File.join(dir, "unexpected.gem"), "extra")
      verifier = HiveReleaseCandidate::AssetVerifier.new(cache_root: dir)

      error = assert_raises(HiveReleaseCandidate::Error) do
        verifier.verify_set!([ artifact ], exact_directory: true)
      end
      assert_includes error.message, "unmanifested"

      error = assert_raises(HiveReleaseCandidate::Error) do
        verifier.validate_archive_entries!(%w[lib/hive.rb ../escape])
      end
      assert_includes error.message, "unsafe archive entry"
    end
  end

  def test_authenticates_checksum_signature_and_certificate_before_accepting_package
    with_tmp_dir do |dir|
      bytes = "authenticated gem bytes"
      artifact = descriptor("hive-cli-0.6.9.gem", bytes)
      package = {
        "artifact" => artifact,
        "authentication" => {
          "checksum" => auth_descriptor("SHA256SUMS"),
          "signature" => auth_descriptor("SHA256SUMS.sig"),
          "certificate" => auth_descriptor("SHA256SUMS.pem"),
          "issuer" => "https://token.actions.githubusercontent.com",
          "identity" => "https://github.com/ivankuznetsov/hive/.github/workflows/release.yml@refs/tags/v0.6.9"
        }
      }
      File.binwrite(File.join(dir, artifact.fetch("filename")), bytes)
      File.binwrite(
        File.join(dir, "SHA256SUMS"),
        "#{artifact.fetch('sha256')}  #{artifact.fetch('filename')}\n"
      )
      File.binwrite(File.join(dir, "SHA256SUMS.sig"), "signature")
      File.binwrite(File.join(dir, "SHA256SUMS.pem"), "certificate")
      package.fetch("authentication").each_value do |value|
        next unless value.is_a?(Hash)

        path = File.join(dir, value.fetch("filename"))
        value["repository"] = "ivankuznetsov/hive"
        value["tag"] = "v0.6.9"
        value["size"] = File.size(path)
        value["sha256"] = Digest::SHA256.file(path).hexdigest
      end
      verifier = HiveReleaseCandidate::AssetVerifier.new(cache_root: dir)
      calls = []

      result = verifier.verify_authenticated_package!(
        package, signature_verifier: ->(**kwargs) { calls << kwargs; true }
      )

      assert_equal artifact.fetch("sha256"), result.fetch("sha256")
      assert_equal 1, calls.size
      assert_equal "SHA256SUMS", File.basename(calls.first.fetch(:checksum))
      assert_equal package.dig("authentication", "issuer"), calls.first.fetch(:issuer)

      File.binwrite(File.join(dir, "SHA256SUMS"), "#{'0' * 64}  #{artifact.fetch('filename')}\n")
      package.dig("authentication", "checksum")["sha256"] =
        Digest::SHA256.file(File.join(dir, "SHA256SUMS")).hexdigest
      error = assert_raises(HiveReleaseCandidate::Error) do
        verifier.verify_authenticated_package!(package, signature_verifier: ->(**) { true })
      end
      assert_includes error.message, "checksum"
    end
  end

  def test_cache_root_collision_and_symlink_fail_closed
    with_tmp_dir do |dir|
      occupied = File.join(dir, "occupied")
      File.binwrite(occupied, "file")
      error = assert_raises(HiveReleaseCandidate::Error) do
        HiveReleaseCandidate::AssetVerifier.new(cache_root: occupied)
      end
      assert_includes error.message, "directory"

      linked = File.join(dir, "linked")
      File.symlink(dir, linked)
      error = assert_raises(HiveReleaseCandidate::Error) do
        HiveReleaseCandidate::AssetVerifier.new(cache_root: linked)
      end
      assert_includes error.message, "symlink"

      parent_link = File.join(dir, "parent-link")
      File.symlink(dir, parent_link)
      error = assert_raises(HiveReleaseCandidate::Error) do
        HiveReleaseCandidate::AssetVerifier.new(cache_root: File.join(parent_link, "missing"))
      end
      assert_includes error.message, "symlink"
    end
  end

  private

  def descriptor(filename, bytes)
    {
      "filename" => filename,
      "url" => "https://github.com/ivankuznetsov/hive/releases/download/v0.6.9/#{filename}",
      "repository" => "ivankuznetsov/hive",
      "tag" => "v0.6.9",
      "sha256" => Digest::SHA256.hexdigest(bytes),
      "size" => bytes.bytesize
    }
  end

  def auth_descriptor(filename)
    {
      "filename" => filename,
      "url" => "https://github.com/ivankuznetsov/hive/releases/download/v0.6.9/#{filename}"
    }
  end
end
