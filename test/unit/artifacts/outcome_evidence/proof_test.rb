require "test_helper"
require "hive/artifacts/outcome_evidence/proof"

class OutcomeEvidenceProofTest < Minitest::Test
  include HiveTestHelper

  HEAD = "b" * 40
  Proof = Hive::Artifacts::OutcomeEvidence::Proof

  def run
    with_fake_proof_media_tools { super }
  end

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

  def test_metadata_admission_preserves_structure_without_reopening_media
    with_tmp_dir do |root|
      files = valid_files(root)
      admitted = admit(root, proof(
        "document", files,
        original: [ "report.md", "text/markdown" ],
        review: [ "report.txt", "text/plain" ]
      ))
      admitted.fetch("representations").each do |representation|
        File.unlink(File.join(root, representation.fetch("path")))
      end

      assert_equal admitted, Proof.admit_metadata!(
        admitted, task_folder: root, expected_head: HEAD
      )

      escaped = Marshal.load(Marshal.dump(admitted))
      escaped.fetch("representations").first["path"] = "../outside.txt"
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.admit_metadata!(escaped, task_folder: root, expected_head: HEAD)
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

      File.write(File.join(root, "secret.txt"), "token: ghp_#{"aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"}\n")
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

  def test_controller_derives_the_semantic_review_storyboard_from_retained_video
    with_tmp_dir do |root|
      valid_files(root)
      FileUtils.mkdir_p(File.join(root, "retained"))
      value = {
        "kind" => "video",
        "summary" => "The complete checkout transition reaches confirmation.",
        "claims" => [ "claim-a" ],
        "representations" => [
          {
            "role" => "original", "media_type" => "video/webm",
            "path" => "video-original.webm"
          },
          {
            "role" => "review", "media_type" => "video/webm",
            "path" => "video-review.webm"
          }
        ]
      }

      admitted = Proof.materialize_producer!(
        value, task_folder: root, expected_head: HEAD,
        destination_root: "retained/video"
      )

      storyboard = admitted.fetch("representations").find do |representation|
        representation.fetch("role") == "storyboard"
      end
      assert storyboard
      assert_equal "image/png", storyboard.fetch("media_type")
      assert_equal "supplemental", storyboard.fetch("rendering")
      assert_match(%r{\Aretained/video/controller-storyboard\.png\z}, storyboard.fetch("path"))
      path = File.join(root, storyboard.fetch("path"))
      assert_equal Digest::SHA256.file(path).hexdigest, storyboard.fetch("sha256")
    end
  end

  def test_producer_cannot_supply_storyboards_or_malformed_entries
    with_tmp_dir do |root|
      valid_files(root)
      value = {
        "kind" => "video", "summary" => "Flow completes", "claims" => [ "claim-a" ],
        "representations" => [
          { "role" => "storyboard", "media_type" => "image/png", "path" => "storyboard.png" }
        ]
      }
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.materialize_producer!(
          value, task_folder: root, expected_head: HEAD, destination_root: "retained/video"
        )
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.materialize_producer!(
          {}, task_folder: root, expected_head: HEAD, destination_root: "retained/broken"
        )
      end

      File.write(File.join(root, "empty.txt"), "")
      empty = {
        "kind" => "document", "summary" => "Empty proof is rejected", "claims" => [ "claim-a" ],
        "representations" => [
          { "role" => "original", "media_type" => "text/plain", "path" => "empty.txt" },
          { "role" => "review", "media_type" => "text/plain", "path" => "report.txt" }
        ]
      }
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.materialize_producer!(
          empty, task_folder: root, expected_head: HEAD, destination_root: "retained/empty"
        )
      end
    end
  end

  def test_controller_storyboard_requires_a_regular_nonempty_output
    with_tmp_dir do |root|
      valid_files(root)
      entry = {
        "representations" => [
          { "role" => "review", "media_type" => "video/webm", "path" => "video-review.webm" }
        ]
      }
      original = Proof.method(:media_command)
      empty_output = lambda do |argv, **kwargs|
        if argv.include?("-show_entries")
          original.call(argv, **kwargs)
        else
          FileUtils.mkdir_p(File.dirname(argv.last))
          File.write(argv.last, "")
        end
      end
      storyboard = File.join(root, "retained", "empty", "controller-storyboard.png")
      real_lstat = File.method(:lstat)
      empty_stat = Struct.new(:file?, :symlink?, :size).new(true, false, 0)
      with_replaced_singleton_method(Proof, :media_command, empty_output) do
        with_replaced_singleton_method(
          File, :lstat, ->(path) { path == storyboard ? empty_stat : real_lstat.call(path) }
        ) do
          error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
            Proof.send(
              :add_controller_storyboard!, entry, task_folder: root,
              expected_head: HEAD, destination_root: "retained/empty"
            )
          end
          assert_equal "controller video storyboard is unavailable", error.message
        end
      end

      missing_output = lambda do |argv, **kwargs|
        original.call(argv, **kwargs) if argv.include?("-show_entries")
      end
      with_replaced_singleton_method(Proof, :media_command, missing_output) do
        error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          Proof.send(
            :add_controller_storyboard!, entry, task_folder: root,
            expected_head: HEAD, destination_root: "retained/missing"
          )
        end
        assert_equal "controller video storyboard is unavailable", error.message
      end
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

      malformed_digest = proof(
        "document", files,
        original: [ "report.md", "text/markdown" ],
        review: [ "report.txt", "text/plain" ]
      )
      malformed_digest.fetch("representations").last["sha256"] = "short"
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        admit(root, malformed_digest)
      end

      mismatched_size = proof(
        "document", files,
        original: [ "report.md", "text/markdown" ],
        review: [ "report.txt", "text/plain" ]
      )
      mismatched_size.fetch("representations").last["bytes"] += 1
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        admit(root, mismatched_size)
      end

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

      shared = Marshal.load(Marshal.dump(value))
      shared.fetch("representations")[1] = shared.fetch("representations")[0].merge("role" => "review")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.materialize_producer!(
          shared, task_folder: root, expected_head: HEAD,
          destination_root: "retained/provider-shared"
        )
      end

      mismatched = Marshal.load(Marshal.dump(value))
      mismatched.fetch("source")["name"] = "other-provider"
      error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        admit(root, mismatched)
      end
      assert_match(/identity does not match/, error.message)
    end
  end

  def test_materializes_task_evidence_into_controller_custody_before_review
    with_tmp_dir do |root|
      files = valid_files(root)
      value = proof(
        "document", files,
        original: [ "report.md", "text/markdown" ],
        review: [ "report.txt", "text/plain" ]
      )
      FileUtils.mkdir_p(File.join(root, "retained", "attempt-1"))

      retained = Hive::Artifacts::OutcomeEvidence::Proof.materialize!(
        value, task_folder: root, expected_head: HEAD,
        destination_root: "retained/attempt-1/entry-01"
      )

      retained.fetch("representations").each do |representation|
        assert_match(%r{\Aretained/attempt-1/entry-01/}, representation.fetch("path"))
        assert_equal 0o600,
                     File.stat(File.join(root, representation.fetch("path"))).mode & 0o777
      end
      original_copy = retained.fetch("representations").first
      before = File.binread(File.join(root, original_copy.fetch("path")))
      File.write(File.join(root, "report.md"), "producer changed this after returning\n")
      assert_equal before, File.binread(File.join(root, original_copy.fetch("path")))

      File.write(File.join(root, "report.md"), "# Verification\n\nAll checks passed.\n")
      producer_retained = Proof.materialize_producer!(
        value, task_folder: root, expected_head: HEAD,
        destination_root: "retained/attempt-1/entry-02"
      )
      assert_equal "document", producer_retained.fetch("kind")
    end
  end

  def test_materializes_one_managed_visual_capture_for_both_representation_roles
    with_tmp_dir do |root|
      valid_files(root)
      FileUtils.mkdir_p(File.join(root, "retained", "attempt-visual"))
      value = proof(
        "screenshot", {},
        original: [ "shot-original.png", "image/png" ],
        review: [ "shot-original.png", "image/png" ]
      )

      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { admit(root, value) }

      retained = Proof.materialize_producer!(
        value, task_folder: root, expected_head: HEAD,
        destination_root: "retained/attempt-visual/entry-01"
      )

      representations = retained.fetch("representations")
      assert_equal %w[original review], representations.map { |item| item.fetch("role") }
      assert_equal 2, representations.map { |item| item.fetch("path") }.uniq.length
      assert_equal 1, representations.map { |item| item.fetch("sha256") }.uniq.length
    end
  end

  def test_shared_producer_path_is_rejected_for_non_visual_evidence
    with_tmp_dir do |root|
      valid_files(root)
      FileUtils.mkdir_p(File.join(root, "retained", "attempt-document"))
      value = {
        "kind" => "document",
        "summary" => "The same document cannot bypass representation separation.",
        "claims" => [ "claim-a" ],
        "representations" => [
          { "role" => "original", "media_type" => "text/plain", "path" => "report.txt" },
          { "role" => "review", "media_type" => "text/plain", "path" => "report.txt" }
        ]
      }

      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.materialize_producer!(
          value, task_folder: root, expected_head: HEAD,
          destination_root: "retained/attempt-document/entry-01"
        )
      end
    end
  end

  def test_controller_adds_task_source_hashes_and_sizes_to_minimal_producer_output
    with_tmp_dir do |root|
      valid_files(root)
      FileUtils.mkdir_p(File.join(root, "retained", "attempt-2"))
      minimal = {
        "kind" => "document",
        "summary" => "The review document explains the bounded checkout contract.",
        "claims" => [ "claim-a" ],
        "representations" => [
          { "role" => "original", "media_type" => "text/markdown", "path" => "report.md" },
          { "role" => "review", "media_type" => "text/plain", "path" => "report.txt" }
        ]
      }

      retained = Proof.materialize_producer!(
        minimal, task_folder: root, expected_head: HEAD,
        destination_root: "retained/attempt-2/entry-01"
      )

      assert_equal "task", retained.dig("source", "type")
      assert_equal "hive-producer", retained.dig("source", "name")
      assert_equal HEAD, retained.dig("source", "source_sha")
      retained.fetch("representations").each do |representation|
        assert_match(/\A[0-9a-f]{64}\z/, representation.fetch("sha256"))
        assert representation.fetch("bytes").positive?
      end
    end
  end

  def test_rejects_pdf_documents_and_secret_shaped_visual_ocr
    with_tmp_dir do |root|
      files = valid_files(root)
      pdf = File.join(root, "report.pdf")
      File.binwrite(pdf, "%PDF-1.7\n")
      value = proof(
        "document", files.merge("report.pdf" => true),
        original: [ "report.pdf", "application/pdf" ],
        review: [ "report.txt", "text/plain" ]
      )
      error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        admit(root, value)
      end
      assert_match(/unsafe media type/, error.message)

      secret = "ghp_#{"aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"}"
      which = Hive::InvokedBinary.method(:which)
      replacement = ->(name) { name == "tesseract" ? "/bin/true" : which.call(name) }
      with_replaced_singleton_method(Hive::InvokedBinary, :which, replacement) do
        with_replaced_singleton_method(
          Hive::Artifacts::OutcomeEvidence::Proof, :ocr_command,
          ->(_argv, source_root:, failure:) { "Captured #{secret}" }
        ) do
          error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
            Hive::Artifacts::OutcomeEvidence::Proof.send(
              :inspect_visual_secrets!, File.join(root, "shot-original.png"),
              media_type: "image/png", duration: nil
            )
          end
          assert_match(/secret-shaped/, error.message)
          refute_includes error.message, "abcdefghijklmnopqrstuvwxyz"
        end
      end
    end
  end

  def test_rejects_malformed_claim_source_representation_and_rendering_contracts
    with_tmp_dir do |root|
      files = valid_files(root)
      document = proof(
        "document", files,
        original: [ "report.md", "text/markdown" ],
        review: [ "report.txt", "text/plain" ]
      )

      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { admit(root, {}) }
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        admit(root, document.merge("claims" => []))
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        admit(root, document.merge("claims" => %w[claim-a claim-a]))
      end
      mismatched = Marshal.load(Marshal.dump(document))
      mismatched.fetch("source")["source_sha"] = "c" * 40
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { admit(root, mismatched) }
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        admit(root, document.merge("representations" => document.fetch("representations").take(1)))
      end

      duplicate_role = Marshal.load(Marshal.dump(document))
      duplicate_role.fetch("representations").last["role"] = "original"
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        admit(root, duplicate_role)
      end

      rendering = Marshal.load(Marshal.dump(document))
      rendering.fetch("representations").first["rendering"] = "raster"
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { admit(root, rendering) }

      review = representation("review", "shot-review.png", "image/png")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.send(
          :canonical_representation, review, kind: "video", task_folder: root
        )
      end

      unavailable = Marshal.load(Marshal.dump(document))
      unavailable.fetch("representations").last.merge!(
        "path" => "missing.txt", "bytes" => 1, "sha256" => "a" * 64
      )
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        admit(root, unavailable)
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        admit(root, document.merge("summary" => ""))
      end
    end
  end

  def test_custody_roots_and_secure_reads_reject_escape_symlink_and_races
    with_tmp_dir do |root|
      outside = Dir.mktmpdir("hive-proof-outside")
      File.write(File.join(outside, "proof.txt"), "outside\n")
      File.symlink(outside, File.join(root, "escape"))

      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.send(:retained_regular_file!, root, "escape/proof.txt")
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.send(:retained_regular_file!, root, "missing.txt")
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.send(:secure_digest, File.join(root, "escape"))
      end
      bounded = File.join(root, "bounded.txt")
      File.write(bounded, "too large")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.send(:secure_digest, bounded, max_bytes: 1)
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.send(
          :prepare_materialization_root!, root, File.join(root, "escape", "custody")
        )
      end

      existing = File.join(root, "existing")
      FileUtils.mkdir_p(existing)
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.send(:prepare_materialization_root!, root, existing)
      end

      replaced = File.join(root, "replaced")
      original_lstat = File.method(:lstat)
      calls = 0
      fake_stat = Object.new
      fake_stat.define_singleton_method(:directory?) { false }
      fake_stat.define_singleton_method(:symlink?) { false }
      replacement = lambda do |path|
        if path == replaced
          calls += 1
          raise Errno::ENOENT if calls == 1
          fake_stat
        else
          original_lstat.call(path)
        end
      end
      with_replaced_singleton_method(File, :lstat, replacement) do
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          Proof.send(:prepare_materialization_root!, root, replaced)
        end
      end

      raced = File.join(root, "raced")
      FileUtils.mkdir_p(raced)
      replacement = ->(path) { path == raced ? raise(Errno::ENOENT) : original_lstat.call(path) }
      with_replaced_singleton_method(File, :lstat, replacement) do
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          Proof.send(:prepare_materialization_root!, root, raced)
        end
      end
    ensure
      FileUtils.remove_entry_secure(outside) if outside && File.directory?(outside)
    end
  end

  def test_custody_transfer_detects_growth_metadata_digest_and_destination_races
    with_tmp_dir do |root|
      source = File.join(root, "source.txt")
      File.write(source, "abc")
      representation = {
        "path" => "source.txt", "bytes" => 3,
        "sha256" => Digest::SHA256.hexdigest("abc")
      }

      too_small = representation.merge("bytes" => 1)
      destination = File.join(root, "too-small.txt")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.send(:copy_representation!, root, too_small, destination)
      end
      refute File.exist?(destination)

      wrong_total = representation.merge("bytes" => 4)
      destination = File.join(root, "wrong-total.txt")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.send(:copy_representation!, root, wrong_total, destination)
      end
      refute File.exist?(destination)

      destination = File.join(root, "existing.txt")
      File.write(destination, "keep")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.send(:copy_representation!, root, representation, destination)
      end
      assert_equal "keep", File.read(destination)

      destination = File.join(root, "metadata-race.txt")
      reads = [ "abc", nil ]
      stats = [
        File.stat(source),
        Struct.new(:dev, :ino, :size).new(File.stat(source).dev, File.stat(source).ino, 4)
      ]
      input = Object.new
      input.define_singleton_method(:read) { |_size| reads.shift }
      input.define_singleton_method(:stat) { stats.shift }
      original_open = File.method(:open)
      replacement = lambda do |path, *args, **kwargs, &block|
        if path == source
          block.call(input)
        else
          original_open.call(path, *args, **kwargs, &block)
        end
      end
      with_replaced_singleton_method(File, :open, replacement) do
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          Proof.send(:copy_representation!, root, representation, destination)
        end
      end
      refute File.exist?(destination)
    end
  end

  def test_materialization_removes_partial_custody_after_admission_failure
    with_tmp_dir do |root|
      files = valid_files(root)
      value = proof(
        "document", files,
        original: [ "report.md", "text/markdown" ],
        review: [ "report.txt", "text/plain" ]
      )
      FileUtils.mkdir_p(File.join(root, "retained", "attempt-1"))
      replacement = ->(*) { raise Hive::Artifacts::OutcomeEvidence::StoreError, "copy failed" }

      with_replaced_singleton_method(Proof, :copy_representation!, replacement) do
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          Proof.materialize!(
            value, task_folder: root, expected_head: HEAD,
            destination_root: "retained/attempt-1/entry-01"
          )
        end
      end
      refute File.exist?(File.join(root, "retained", "attempt-1", "entry-01"))
    end
  end

  def test_terminal_and_document_decoders_reject_invalid_structure_and_bytes
    with_tmp_dir do |root|
      invalid_header = File.join(root, "invalid-header.cast")
      File.write(invalid_header, %({"version":1,"width":80,"height":24}\n))
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.send(:inspect_terminal_cast!, invalid_header)
      end

      invalid_event = File.join(root, "invalid-event.cast")
      File.write(
        invalid_event,
        %({"version":2,"width":80,"height":24}\n[0.1,"i","input"]\n)
      )
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.send(:inspect_terminal_cast!, invalid_event)
      end

      control = File.join(root, "control.txt")
      File.binwrite(control, "unsafe\0text")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.send(:inspect_safe_text!, control)
      end

      malformed = File.join(root, "malformed.json")
      File.write(malformed, "{")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.send(:inspect_safe_text!, malformed, json: true)
      end

      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.send(
          :inspect_representation!, malformed,
          kind: "document", role: "review", media_type: "application/octet-stream"
        )
      end
    end
  end

  def test_media_and_ocr_commands_cover_supported_codecs_limits_fallback_and_failures
    with_tmp_dir do |root|
      media = File.join(root, "media.bin")
      File.write(media, "media")
      seen_roots = []
      probe = lambda do |codec:, format:, duration: "0"|
        lambda do |argv, source_root:|
          seen_roots << source_root
          if argv.include?("-show_entries")
            JSON.generate(
              "streams" => [ { "codec_name" => codec, "codec_type" => "video" } ],
              "format" => { "format_name" => format, "duration" => duration }
            )
          else
            ""
          end
        end
      end

      {
        "image/jpeg" => [ "mjpeg", "image2" ],
        "image/webp" => [ "webp", "webp_pipe" ],
        "video/mp4" => [ "h264", "mov,mp4,m4a,3gp,3g2,mj2", "0.2" ]
      }.each do |media_type, (codec, format, duration)|
        with_replaced_singleton_method(
          Proof, :media_command,
          probe.call(codec: codec, format: format, duration: duration || "0")
        ) do
          Proof.send(:inspect_media!, media, media_type: media_type)
        end
      end
      assert seen_roots.all? { |source_root| source_root == root }

      with_replaced_singleton_method(
        Proof, :media_command,
        probe.call(codec: "vp8", format: "matroska,webm", duration: "31")
      ) do
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          Proof.send(:inspect_media!, media, media_type: "video/webm")
        end
      end
      with_replaced_singleton_method(Proof, :media_command, ->(*) { "{" }) do
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          Proof.send(:inspect_media!, media, media_type: "image/png")
        end
      end

      calls = []
      ocr = lambda do |argv, source_root:, failure:|
        calls << [ argv, source_root, failure ]
        ""
      end
      with_replaced_singleton_method(Proof, :ocr_command, ocr) do
        Proof.send(
          :inspect_visual_secrets!, media, media_type: "video/webm", duration: 0.2
        )
      end
      assert_equal 3, calls.length
      assert calls[1].first.last.end_with?("frame-001.png")

      failure = {
        "status" => { "success" => false }, "internal_error" => nil,
        "timed_out" => false, "cleanup_failed" => false,
        "stdout_overflow" => false, "stderr_overflow" => false,
        "leftover_processes" => false, "stdout" => ""
      }
      with_replaced_singleton_method(
        Hive::Web::ProjectCaptureProvider, :capture_command_with_custody,
        ->(**) { failure }
      ) do
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          Proof.send(:ocr_command, [ "/bin/false" ], source_root: root, failure: "ocr failed")
        end
      end

      raising = lambda do |**|
        raise Hive::Web::ProjectCaptureProvider::ProviderError, "runner failed"
      end
      with_replaced_singleton_method(
        Hive::Web::ProjectCaptureProvider, :capture_command_with_custody, raising
      ) do
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          Proof.send(:ocr_command, [ "/bin/false" ], source_root: root, failure: "ocr failed")
        end
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          Proof.send(:media_command, [ "/bin/false" ], source_root: root)
        end
      end
    end
  end

  def test_project_provider_originals_and_manifest_size_are_fail_closed
    with_tmp_dir do |root|
      media = File.join(root, "media")
      FileUtils.mkdir_p(media)
      screenshot = File.expand_path("../../../fixtures/composer/screenshot-1.png", __dir__)
      original = File.join(media, "provider.png")
      review = File.join(media, "provider-review.png")
      other = File.join(media, "other.png")
      [ original, review, other ].each { |path| FileUtils.cp(screenshot, path) }
      artifact = {
        "file" => File.basename(other), "bytes" => File.size(other),
        "sha256" => Digest::SHA256.file(other).hexdigest
      }
      File.write(
        File.join(media, "capture-manifest.json"),
        JSON.generate(capture_manifest(artifact))
      )
      value = {
        "kind" => "screenshot", "summary" => "Project UI at the implementation head",
        "claims" => %w[claim-a],
        "source" => {
          "type" => "project_provider", "name" => "fixture-provider",
          "source_sha" => HEAD, "manifest_path" => "media/capture-manifest.json"
        },
        "representations" => [
          { "role" => "original", "media_type" => "image/png" }.merge(file_record(original, root)),
          { "role" => "review", "media_type" => "image/png" }.merge(file_record(review, root))
        ]
      }
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { admit(root, value) }

      oversized = File.join(media, "oversized.json")
      File.binwrite(oversized, "x" * (Hive::ARTIFACT_CAPTURE_MANIFEST_MAX_BYTES + 1))
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Proof.send(:capture_manifest!, root, "media/oversized.json")
      end
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
    File.binwrite(path, [ 0x1A, 0x45, 0xDF, 0xA3 ].pack("C*") + "hive-webm-fixture")
  end

  def with_fake_proof_media_tools
    Dir.mktmpdir("hive-test-proof-media-tools") do |root|
      fake_bin = File.join(root, "bin")
      FileUtils.mkdir_p(fake_bin)
      tool = <<~RUBY
        #!#{RbConfig.ruby}
        require "json"

        png = [ 137, 80, 78, 71, 13, 10, 26, 10 ].pack("C*")
        webm = [ 0x1A, 0x45, 0xDF, 0xA3 ].pack("C*")
        name = File.basename($PROGRAM_NAME)
        exit 0 if name == "tesseract"

        input = ARGV.fetch(ARGV.index("-i") + 1) if name == "ffmpeg"
        input ||= ARGV.last
        signature = File.binread(input, 8)
        type = if signature.start_with?(png)
          :png
        elsif signature.start_with?(webm)
          :webm
        end
        exit 1 unless type

        if name == "ffprobe"
          puts JSON.generate(
            "streams" => [
              {
                "codec_name" => type == :png ? "png" : "vp8",
                "codec_type" => "video"
              }
            ],
            "format" => {
              "format_name" => type == :png ? "png_pipe" : "matroska,webm",
              "duration" => type == :png ? "0" : "0.2"
            }
          )
        elsif (output = ARGV.last).end_with?(".png")
          File.binwrite(output.sub("%03d", "001"), png)
        end
      RUBY
      %w[ffprobe ffmpeg tesseract].each do |name|
        path = File.join(fake_bin, name)
        File.write(path, tool)
        FileUtils.chmod(0o755, path)
      end
      with_env(
        "PATH" => [ fake_bin, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)
      ) { yield }
    end
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
