require "test_helper"
require "hive/artifacts/outcome_evidence/proof"

class OutcomeEvidenceProofTest < Minitest::Test
  include HiveTestHelper

  HEAD = "b" * 40

  def test_admits_the_closed_proof_kinds_with_bounded_review_representations
    with_tmp_dir do |root|
      files = valid_files(root)

      screenshot = admit(root, proof(
        "screenshot", files,
        original: [ "shot-original.png", "image/png" ],
        review: [ "shot-review.png", "image/png" ]
      ))
      video = admit(root, proof(
        "video", files,
        original: [ "video-original.webm", "video/webm" ],
        review: [ "video-review.webm", "video/webm" ],
        storyboard: [ "storyboard.png", "image/png" ]
      ))
      terminal = admit(root, proof(
        "terminal", files,
        original: [ "session.cast", "application/x-asciinema+json" ],
        review: [ "session.txt", "text/plain" ]
      ))
      document = admit(root, proof(
        "document", files,
        original: [ "report.md", "text/markdown" ],
        review: [ "report.txt", "text/plain" ]
      ))

      assert_equal %w[screenshot video terminal document],
                   [ screenshot, video, terminal, document ].map { |item| item.fetch("kind") }
      assert_equal %w[claim-a claim-b], screenshot.fetch("claims")
      [ screenshot, video, terminal, document ].each do |item|
        item.fetch("representations").each do |representation|
          path = File.join(root, representation.fetch("path"))
          assert_equal File.size(path), representation.fetch("bytes")
          assert_equal Digest::SHA256.file(path).hexdigest, representation.fetch("sha256")
        end
      end
    end
  end

  def test_rejects_storyboard_only_video_broken_media_cast_secrets_and_unsafe_documents
    with_tmp_dir do |root|
      files = valid_files(root)
      storyboard_only = proof(
        "video", files,
        original: [ "video-original.webm", "video/webm" ],
        review: [ "storyboard.png", "image/png" ]
      )
      error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        admit(root, storyboard_only)
      end
      assert_match(/temporal review representation/, error.message)

      File.binwrite(File.join(root, "broken.png"), "not an image")
      broken = proof(
        "screenshot", files.merge("broken.png" => true),
        original: [ "broken.png", "image/png" ],
        review: [ "shot-review.png", "image/png" ]
      )
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { admit(root, broken) }

      File.write(File.join(root, "bad.cast"), %({"version":2,"width":80,"height":24}\nnot-json\n))
      bad_cast = proof(
        "terminal", files.merge("bad.cast" => true),
        original: [ "bad.cast", "application/x-asciinema+json" ],
        review: [ "session.txt", "text/plain" ]
      )
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { admit(root, bad_cast) }

      File.write(File.join(root, "secret.txt"), "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789\n")
      secret = proof(
        "terminal", files.merge("secret.txt" => true),
        original: [ "session.cast", "application/x-asciinema+json" ],
        review: [ "secret.txt", "text/plain" ]
      )
      error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { admit(root, secret) }
      assert_match(/secret-shaped/, error.message)

      File.write(File.join(root, "active.svg"), '<svg onload="alert(1)"></svg>')
      active = proof(
        "document", files.merge("active.svg" => true),
        original: [ "active.svg", "image/svg+xml" ],
        review: [ "report.txt", "text/plain" ]
      )
      error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { admit(root, active) }
      assert_match(/active SVG or HTML/, error.message)

      File.write(File.join(root, "disguised.md"), '<html><script>alert("x")</script></html>')
      disguised = proof(
        "document", files.merge("disguised.md" => true),
        original: [ "disguised.md", "text/markdown" ],
        review: [ "report.txt", "text/plain" ]
      )
      error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        admit(root, disguised)
      end
      assert_match(/active SVG or HTML/, error.message)
    end
  end

  def test_rejects_traversal_symlink_oversize_hash_mismatch_and_diagnostic_capture
    with_tmp_dir do |root|
      files = valid_files(root)
      candidate = proof(
        "document", files,
        original: [ "report.md", "text/markdown" ],
        review: [ "report.txt", "text/plain" ]
      )

      candidate.fetch("representations").first["path"] = "../report.md"
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { admit(root, candidate) }

      candidate = proof(
        "document", files,
        original: [ "report.md", "text/markdown" ],
        review: [ "report.txt", "text/plain" ]
      )
      link = File.join(root, "linked.txt")
      File.symlink(File.join(root, "report.txt"), link)
      candidate.fetch("representations").last.merge!(file_record(link, root))
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { admit(root, candidate) }

      candidate = proof(
        "document", files,
        original: [ "report.md", "text/markdown" ],
        review: [ "report.txt", "text/plain" ]
      )
      candidate.fetch("representations").last["bytes"] =
        Hive::Artifacts::OutcomeEvidence::Proof::MAX_REVIEW_BYTES + 1
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { admit(root, candidate) }

      candidate = proof(
        "document", files,
        original: [ "report.md", "text/markdown" ],
        review: [ "report.txt", "text/plain" ]
      )
      candidate.fetch("representations").last["sha256"] = "0" * 64
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { admit(root, candidate) }

      diagnostic = proof(
        "screenshot", files,
        original: [ "shot-original.png", "image/png" ],
        review: [ "shot-review.png", "image/png" ]
      )
      diagnostic["source"] = diagnostic.fetch("source").merge("type" => "hivebox")
      error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        admit(root, diagnostic)
      end
      assert_match(/diagnostic-only/, error.message)
    end
  end

  def test_project_provider_media_is_claim_evidence_only_when_manifest_identity_matches
    with_tmp_dir do |root|
      media = File.join(root, "media")
      FileUtils.mkdir_p(media)
      screenshot = File.expand_path("../../../fixtures/composer/screenshot-1.png", __dir__)
      original = File.join(media, "provider.png")
      review = File.join(media, "provider-review.png")
      FileUtils.cp(screenshot, original)
      FileUtils.cp(screenshot, review)
      artifact = {
        "file" => File.basename(original), "bytes" => File.size(original),
        "sha256" => Digest::SHA256.file(original).hexdigest
      }
      manifest_path = File.join(media, "capture-manifest.json")
      File.write(manifest_path, JSON.generate(capture_manifest(artifact)))
      value = {
        "kind" => "screenshot", "summary" => "Project UI at the implementation head",
        "claims" => %w[claim-a claim-b],
        "source" => {
          "type" => "project_provider", "name" => "fixture-provider",
          "source_sha" => HEAD, "manifest_path" => "media/capture-manifest.json"
        },
        "representations" => [
          { "role" => "original", "media_type" => "image/png" }.merge(file_record(original, root)),
          { "role" => "review", "media_type" => "image/png" }.merge(file_record(review, root))
        ]
      }

      admitted = admit(root, value)
      assert_equal %w[claim-a claim-b], admitted.fetch("claims")

      mismatched = Marshal.load(Marshal.dump(value))
      mismatched.fetch("source")["name"] = "other-provider"
      error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        admit(root, mismatched)
      end
      assert_match(/identity does not match/, error.message)
    end
  end

  private

  def admit(root, value)
    Hive::Artifacts::OutcomeEvidence::Proof.admit!(
      value, task_folder: root, expected_head: HEAD
    )
  end

  def proof(kind, _files, original:, review:, storyboard: nil)
    representations = [ representation("original", *original), representation("review", *review) ]
    representations << representation("storyboard", *storyboard) if storyboard
    {
      "kind" => kind,
      "summary" => "Reviewer-inspectable #{kind}",
      "claims" => %w[claim-b claim-a],
      "source" => {
        "type" => "task", "name" => "artifact-agent",
        "source_sha" => HEAD
      },
      "representations" => representations
    }
  end

  def representation(role, path, media_type)
    { "role" => role, "media_type" => media_type }.merge(file_record(path))
  end

  def file_record(path, root = @proof_root)
    absolute = if root && Pathname.new(path).absolute?
      path
    elsif root
      File.join(root, path)
    else
      path
    end
    {
      "path" => root ? Pathname.new(absolute).relative_path_from(Pathname.new(root)).to_s : path,
      "bytes" => File.size(absolute),
      "sha256" => Digest::SHA256.file(absolute).hexdigest
    }
  end

  def valid_files(root)
    @proof_root = root
    screenshot = File.expand_path("../../../fixtures/composer/screenshot-1.png", __dir__)
    %w[shot-original.png shot-review.png storyboard.png].each do |name|
      FileUtils.cp(screenshot, File.join(root, name))
    end
    make_video(File.join(root, "video-original.webm"))
    FileUtils.cp(File.join(root, "video-original.webm"), File.join(root, "video-review.webm"))
    File.write(
      File.join(root, "session.cast"),
      %({"version":2,"width":80,"height":24,"timestamp":1}\n[0.1,"o","tests passed\\r\\n"]\n)
    )
    File.write(File.join(root, "session.txt"), "tests passed\n")
    File.write(File.join(root, "report.md"), "# Verification\n\nAll checks passed.\n")
    File.write(File.join(root, "report.txt"), "Verification\n\nAll checks passed.\n")
    Dir.children(root).to_h { |name| [ name, true ] }
  end

  def make_video(path)
    system(
      "ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi",
      "-i", "color=c=black:s=16x16:d=0.2", "-an", "-c:v", "libvpx",
      "-y", path
    ) or raise "ffmpeg could not create the test video"
  end

  def capture_manifest(artifact)
    {
      "schema" => "hive-artifact-capture", "schema_version" => 2,
      "status" => "captured", "task" => "demo-task", "source_sha" => HEAD,
      "recorder" => {
        "kind" => "project_provider", "name" => "fixture-provider",
        "command" => [ "bin/capture" ]
      },
      "environment_keys" => [ "PATH" ],
      "started_at" => "2026-08-13T22:00:00Z",
      "finished_at" => "2026-08-13T22:00:01Z",
      "artifacts" => [ artifact ],
      "cleanup" => { "port" => "released", "processes" => "clean", "runtime" => "cleaned" },
      "diagnostic" => nil,
      "evidence_role" => "claim_evidence",
      "evidence" => { "type" => "project_provider", "details" => {} }
    }
  end
end
