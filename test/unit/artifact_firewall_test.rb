require "test_helper"
require "hive/artifact_firewall"
require "hive/task_journal"

class ArtifactFirewallTest < Minitest::Test
  include HiveTestHelper

  def test_explicit_path_custody_restores_bytes_and_listing_proven_additions
    with_tmp_dir do |dir|
      original = File.join(dir, "receipt.json")
      audit = File.join(dir, "audit.jsonl")
      added = File.join(dir, "added-receipt.json")
      File.write(original, "trusted\n")
      custody = Hive::ArtifactFirewall::PathCustody.new("receipt" => original, "audit" => audit)
      assert_empty custody.restore_changes!
      File.write(original, "edited\n")
      File.write(audit, "unauthorized\n")
      File.write(added, "unauthorized\n")
      changed = custody.restore_changes!(absent_paths: { "added" => added })
      assert_equal %w[added audit receipt], changed.sort
      assert changed.frozen?
      assert_equal "trusted\n", File.read(original)
      refute File.exist?(audit)
      refute File.exist?(added)
    end
  end

  def test_explicit_path_custody_rejects_conflicting_absence_proof
    with_tmp_dir do |dir|
      path = File.join(dir, "receipt.json")
      File.write(path, "trusted\n")
      custody = Hive::ArtifactFirewall::PathCustody.new("receipt" => path)
      assert_raises(Hive::ArtifactFirewall::InvalidManifest) do
        custody.restore_changes!(absent_paths: { "receipt" => path })
      end
      assert_equal "trusted\n", File.read(path)
    end
  end

  def test_explicit_path_custody_surfaces_unsafe_restoration
    with_tmp_dir do |dir|
      path = File.join(dir, "receipt.json")
      File.write(path, "trusted\n")
      custody = Hive::ArtifactFirewall::PathCustody.new("receipt" => path)
      File.write(path, "edited\n")
      with_replaced_singleton_method(Hive::ProtectedFiles, :restore_paths,
        ->(*) { raise Hive::ProtectedFiles::RestoreError, "unsafe parent" }) do
        error = assert_raises(Hive::ArtifactFirewall::CaptureError) { custody.restore_changes! }
        assert_match(/restoration failed/, error.message)
      end
    end
  end

  def test_protected_anchor_reports_added_changed_deleted_and_unchanged
    with_tmp_dir do |dir|
      File.write(File.join(dir, "changed"), "before\n")
      File.write(File.join(dir, "deleted"), "before\n")
      File.write(File.join(dir, "unchanged"), "same\n")
      manifest = build_manifest(
        dir,
        protected: {
          "added" => "added",
          "changed" => "changed",
          "deleted" => "deleted",
          "unchanged" => "unchanged"
        }
      )
      snapshot = Hive::ArtifactFirewall.capture(manifest)

      File.write(File.join(dir, "added"), "new\n")
      File.write(File.join(dir, "changed"), "after\n")
      File.delete(File.join(dir, "deleted"))
      report = Hive::ArtifactFirewall.validate(manifest, snapshot)

      assert_equal :tampered, report.status
      assert_equal(
        {
          "added" => :protected_added,
          "changed" => :protected_changed,
          "deleted" => :protected_deleted
        },
        report.violations.to_h { |violation| [ violation.label, violation.kind ] }
      )
      refute_includes report.tampered_labels, "unchanged"
      assert_nil report.restored?
    end
  end

  def test_protected_anchor_reports_symlink_directory_and_mode_substitution
    with_tmp_dir do |dir|
      paths = %w[symlink directory mode].to_h do |name|
        path = File.join(dir, name)
        File.write(path, "trusted\n")
        [ name, path ]
      end
      manifest = build_manifest(dir, protected: paths)
      snapshot = Hive::ArtifactFirewall.capture(manifest)

      outside = File.join(dir, "outside")
      File.write(outside, "trusted\n")
      File.unlink(paths.fetch("symlink"))
      File.symlink(outside, paths.fetch("symlink"))
      File.unlink(paths.fetch("directory"))
      FileUtils.mkdir_p(paths.fetch("directory"))
      File.chmod(0o600, paths.fetch("mode"))

      report = Hive::ArtifactFirewall.validate(manifest, snapshot)
      kinds = report.violations.to_h { |violation| [ violation.label, violation.kind ] }

      assert_equal :protected_symlink_substitution, kinds.fetch("symlink")
      assert_equal :protected_directory_substitution, kinds.fetch("directory")
      assert_equal :protected_mode_changed, kinds.fetch("mode")
    end
  end

  def test_required_outputs_must_be_nonempty_regular_files
    with_tmp_dir do |dir|
      valid = File.join(dir, "valid.md")
      empty = File.join(dir, "empty.md")
      symlink = File.join(dir, "symlink.md")
      directory = File.join(dir, "directory.md")
      File.write(valid, "accepted\n")
      File.write(empty, "")
      File.symlink(valid, symlink)
      FileUtils.mkdir_p(directory)

      manifest = build_manifest(
        dir,
        outputs: {
          "valid" => valid,
          "missing" => File.join(dir, "missing.md"),
          "empty" => empty,
          "symlink" => symlink,
          "directory" => directory
        },
        roots: [ dir ]
      )
      report = Hive::ArtifactFirewall.validate(
        manifest, Hive::ArtifactFirewall.capture(manifest)
      )
      kinds = report.required_output_violations.to_h do |violation|
        [ violation.label, violation.kind ]
      end

      assert_equal :rejected, report.status
      assert_equal :required_output_missing, kinds.fetch("missing")
      assert_equal :required_output_empty, kinds.fetch("empty")
      assert_equal :required_output_symlink, kinds.fetch("symlink")
      assert_equal :required_output_non_regular, kinds.fetch("directory")
      refute kinds.key?("valid")
    end
  end

  def test_required_output_outside_permitted_root_is_rejected
    with_tmp_dir do |dir|
      allowed = File.join(dir, "allowed")
      FileUtils.mkdir_p(allowed)
      outside = File.join(dir, "outside.md")
      File.write(outside, "content\n")
      manifest = build_manifest(
        dir,
        outputs: { "outside" => outside },
        roots: [ allowed ]
      )

      report = Hive::ArtifactFirewall.validate(
        manifest, Hive::ArtifactFirewall.capture(manifest)
      )

      assert_equal :required_output_outside_root,
                   report.required_output_violations.fetch(0).kind
    end
  end

  def test_required_output_cannot_escape_through_symlinked_parent
    with_tmp_dir do |dir|
      allowed = File.join(dir, "allowed")
      outside = File.join(dir, "outside")
      FileUtils.mkdir_p([ allowed, outside ])
      File.symlink(outside, File.join(allowed, "escape"))
      output = File.join(allowed, "escape", "report.md")
      File.write(File.join(outside, "report.md"), "content\n")
      manifest = build_manifest(
        dir,
        outputs: { "report" => output },
        roots: [ allowed ]
      )

      report = Hive::ArtifactFirewall.validate(
        manifest, Hive::ArtifactFirewall.capture(manifest)
      )

      assert_equal :required_output_outside_root,
                   report.required_output_violations.fetch(0).kind
    end
  end

  def test_validate_and_restore_recreates_changed_deleted_and_added_anchors
    with_tmp_dir do |dir|
      changed = File.join(dir, "changed")
      deleted = File.join(dir, "deleted")
      added = File.join(dir, "added")
      File.write(changed, "trusted changed\n")
      File.chmod(0o600, changed)
      File.write(deleted, "trusted deleted\n")
      manifest = build_manifest(
        dir,
        protected: { "changed" => changed, "deleted" => deleted, "added" => added }
      )
      snapshot = Hive::ArtifactFirewall.capture(manifest)

      File.write(changed, "tampered\n")
      File.chmod(0o644, changed)
      File.unlink(deleted)
      File.write(added, "forged\n")
      report = Hive::ArtifactFirewall.validate_and_restore(manifest, snapshot)

      assert_equal :tampered_restored, report.status
      assert_equal true, report.restored?
      assert_equal "trusted changed\n", File.read(changed)
      assert_equal 0o600, File.stat(changed).mode & 0o777
      assert_equal "trusted deleted\n", File.read(deleted)
      refute File.exist?(added)
    end
  end

  def test_restore_refuses_agent_created_directory_without_recursive_deletion
    with_tmp_dir do |dir|
      path = File.join(dir, "anchor")
      File.write(path, "trusted\n")
      manifest = build_manifest(dir, protected: { "anchor" => path })
      snapshot = Hive::ArtifactFirewall.capture(manifest)
      File.unlink(path)
      FileUtils.mkdir_p(File.join(path, "nested"))

      report = Hive::ArtifactFirewall.validate_and_restore(manifest, snapshot)

      assert_equal :restore_failed, report.status
      assert_equal false, report.restored?
      assert_includes report.restore_diagnostic, "refusing to replace protected path directory"
      assert File.directory?(File.join(path, "nested"))
    end
  end

  def test_restore_does_not_claim_reconstruction_for_original_non_file
    with_tmp_dir do |dir|
      first = File.join(dir, "first")
      second = File.join(dir, "second")
      anchor = File.join(dir, "anchor")
      File.write(first, "first\n")
      File.write(second, "second\n")
      File.symlink(first, anchor)
      manifest = build_manifest(dir, protected: { "anchor" => anchor })
      snapshot = Hive::ArtifactFirewall.capture(manifest)
      File.unlink(anchor)
      File.symlink(second, anchor)

      report = Hive::ArtifactFirewall.validate_and_restore(manifest, snapshot)

      assert_equal :restore_failed, report.status
      assert_equal false, report.restored?
      assert_includes report.restore_diagnostic, "cannot be reconstructed safely"
      assert_equal second, File.readlink(anchor)
    end
  end

  def test_report_diagnostics_are_redacted_and_bounded
    with_tmp_dir do |dir|
      secret = "sensitive-capability-value"
      label = "#{secret}-#{"x" * 2_000}"
      path = File.join(dir, secret)
      manifest = build_manifest(
        dir,
        protected: { label => path },
        redactor: ->(text) { text.gsub(secret, "[FILTERED]") }
      )
      snapshot = Hive::ArtifactFirewall.capture(manifest)
      File.write(path, "forged\n")

      report = Hive::ArtifactFirewall.validate(manifest, snapshot)
      violation = report.violations.fetch(0)

      refute_includes report.to_h.to_s, secret
      assert_operator report.diagnostic.bytesize, :<=, Hive::ArtifactFirewall::DIAGNOSTIC_BYTES
      assert_operator violation.label.bytesize, :<=, Hive::ArtifactFirewall::DIAGNOSTIC_BYTES
      assert_operator violation.path.bytesize, :<=, Hive::ArtifactFirewall::DIAGNOSTIC_BYTES
      assert_operator violation.diagnostic.bytesize, :<=, Hive::ArtifactFirewall::DIAGNOSTIC_BYTES
      assert_includes report.diagnostic, "[FILTERED]"
    end
  end

  def test_restore_uses_raw_custody_labels_not_redacted_report_labels
    with_tmp_dir do |dir|
      secret = "sensitive-capability-value"
      path = File.join(dir, "anchor")
      File.write(path, "trusted\n")
      manifest = build_manifest(
        dir,
        protected: { secret => path },
        redactor: ->(text) { text.gsub(secret, "[FILTERED]") }
      )
      snapshot = Hive::ArtifactFirewall.capture(manifest)
      File.write(path, "forged\n")

      report = Hive::ArtifactFirewall.validate_and_restore(manifest, snapshot)

      assert_equal :tampered_restored, report.status
      assert_equal true, report.restored?
      assert_equal "trusted\n", File.read(path)
      assert_equal [ "[FILTERED]" ], report.tampered_labels
      refute_includes report.to_h.to_s, secret
    end
  end

  def test_redactor_failure_fails_closed_without_echoing_input
    with_tmp_dir do |dir|
      manifest = build_manifest(
        dir,
        protected: { "secret-label" => "anchor" },
        redactor: ->(_text) { raise "redactor failed" }
      )
      snapshot = Hive::ArtifactFirewall.capture(manifest)
      File.write(File.join(dir, "anchor"), "forged\n")

      report = Hive::ArtifactFirewall.validate(manifest, snapshot)

      assert_equal "[REDACTION_FAILED]", report.diagnostic
      assert_equal "[REDACTION_FAILED]", report.violations.fetch(0).label
    end
  end

  def test_snapshot_and_report_are_bound_to_their_manifest
    with_tmp_dir do |dir|
      first = build_manifest(dir, protected: { "anchor" => "anchor" })
      second = build_manifest(dir, protected: { "anchor" => "anchor" })
      snapshot = Hive::ArtifactFirewall.capture(first)

      error = assert_raises(Hive::ArtifactFirewall::InvalidSnapshot) do
        Hive::ArtifactFirewall.validate(second, snapshot)
      end
      assert_includes error.message, "does not belong"

      report = Hive::ArtifactFirewall.validate(first, snapshot)
      other_snapshot = Hive::ArtifactFirewall.capture(first)
      error = assert_raises(Hive::ArtifactFirewall::InvalidSnapshot) do
        Hive::ArtifactFirewall.restore(first, other_snapshot, report)
      end
      assert_includes error.message, "report does not belong"
    end
  end

  def test_snapshot_captured_bytes_and_identities_are_immutable
    with_tmp_dir do |dir|
      File.write(File.join(dir, "anchor"), "trusted\n")
      manifest = build_manifest(dir, protected: { "anchor" => "anchor" })
      snapshot = Hive::ArtifactFirewall.capture(manifest)

      assert_raises(FrozenError) do
        snapshot.captured.fetch("anchor").fetch(:content) << "tampered"
      end
      assert_raises(FrozenError) do
        snapshot.observed.fetch("anchor")[:mode] = 0o777
      end
      assert_raises(FrozenError) do
        snapshot.captured["new"] = {}
      end
      assert_raises(FrozenError) do
        snapshot.parent_identities.fetch("anchor")[:mode] = 0o777
      end
      assert_raises(FrozenError) do
        snapshot.parent_identities.fetch("anchor").fetch(:realpath) << "/redirected"
      end

      target = File.join(dir, "target")
      symlink = File.join(dir, "symlink")
      File.write(target, "target\n")
      File.symlink(target, symlink)
      symlink_manifest = build_manifest(
        dir, protected: { "symlink" => symlink }
      )
      symlink_snapshot = Hive::ArtifactFirewall.capture(symlink_manifest)
      assert_raises(FrozenError) do
        symlink_snapshot.observed.fetch("symlink").fetch(:target) << "-changed"
      end

      nested_snapshot = Hive::ArtifactFirewall::Snapshot.new(
        id: "nested",
        manifest: manifest,
        captured: { "anchor" => { history: [ "trusted" ] } },
        observed: {},
        parent_identities: {}
      )
      assert_raises(FrozenError) do
        nested_snapshot.captured.fetch("anchor").fetch(:history) << "tampered"
      end
    end
  end

  def test_capture_binds_observed_identity_to_the_captured_bytes
    original_capture = Hive::ProtectedFiles.method(:capture_paths)
    with_tmp_dir do |dir|
      anchor = File.join(dir, "anchor")
      File.write(anchor, "trusted\n")
      manifest = build_manifest(dir, protected: { "anchor" => "anchor" })
      Hive::ProtectedFiles.define_singleton_method(:capture_paths) do |paths|
        captured = original_capture.call(paths)
        File.write(anchor, "replaced after capture\n")
        captured
      end

      snapshot = Hive::ArtifactFirewall.capture(manifest)

      assert_equal "trusted\n", snapshot.captured.fetch("anchor").fetch(:content)
      assert_equal snapshot.captured.fetch("anchor").fetch(:identity),
                   snapshot.observed.fetch("anchor")
    end
  ensure
    Hive::ProtectedFiles.define_singleton_method(:capture_paths, original_capture)
  end

  def test_parent_substitution_is_detected_and_blocks_restore
    with_tmp_dir do |dir|
      parent = File.join(dir, "controller")
      original_parent = File.join(dir, "controller-original")
      outside = File.join(dir, "outside")
      FileUtils.mkdir_p([ parent, outside ])
      File.write(File.join(parent, "anchor"), "trusted\n")
      File.write(File.join(outside, "anchor"), "trusted\n")
      manifest = build_manifest(
        dir,
        protected: { "anchor" => File.join(parent, "anchor") }
      )
      snapshot = Hive::ArtifactFirewall.capture(manifest)

      File.rename(parent, original_parent)
      File.symlink(outside, parent)
      report = Hive::ArtifactFirewall.validate(manifest, snapshot)

      assert_equal [ :protected_parent_changed ], report.violations.map(&:kind)

      File.write(File.join(outside, "anchor"), "outside must survive\n")
      restored_report = Hive::ArtifactFirewall.validate_and_restore(manifest, snapshot)

      assert_equal :restore_failed, restored_report.status
      assert_equal false, restored_report.restored?
      assert_includes restored_report.restore_diagnostic, "parent substitution"
      assert_equal "outside must survive\n", File.read(File.join(outside, "anchor"))
      assert_equal "trusted\n", File.read(File.join(original_parent, "anchor"))
    end
  end

  def test_required_output_inspection_uses_a_stable_non_spawn_id
    with_tmp_dir do |dir|
      manifest = build_manifest(
        dir,
        outputs: { "report" => "missing.md" },
        roots: [ dir ]
      )

      first = Hive::ArtifactFirewall.validate_required_outputs(manifest)
      second = Hive::ArtifactFirewall.validate_required_outputs(manifest)

      assert_equal Hive::ArtifactFirewall::REQUIRED_OUTPUT_INSPECTION_ID,
                   first.snapshot_id
      assert_equal first.snapshot_id, second.snapshot_id
    end
  end

  def test_manifest_rejects_conflicting_paths_invalid_encoding_and_invalid_redactor
    with_tmp_dir do |dir|
      error = assert_raises(Hive::ArtifactFirewall::InvalidManifest) do
        build_manifest(
          dir,
          protected: { "anchor" => "same" },
          outputs: { "report" => "same" }
        )
      end
      assert_includes error.message, "cannot also be a protected anchor"

      error = assert_raises(Hive::ArtifactFirewall::InvalidManifest) do
        build_manifest(dir, redactor: Object.new)
      end
      assert_includes error.message, "respond to #call"

      invalid_path = "invalid-\xFF".b
      error = assert_raises(Hive::ArtifactFirewall::InvalidManifest) do
        build_manifest(dir, protected: { "anchor" => invalid_path })
      end
      assert_includes error.message, "valid UTF-8"

      error = assert_raises(Hive::ArtifactFirewall::InvalidManifest) do
        build_manifest(dir, protected: Object.new)
      end
      assert_includes error.message, "label-to-path mapping"

      too_many = (0..Hive::ArtifactFirewall::MAX_ENTRIES).to_h do |index|
        [ "anchor-#{index}", "path-#{index}" ]
      end
      error = assert_raises(Hive::ArtifactFirewall::InvalidManifest) do
        build_manifest(dir, protected: too_many)
      end
      assert_includes error.message, "exceeds"

      error = assert_raises(Hive::ArtifactFirewall::InvalidManifest) do
        build_manifest(
          dir,
          protected: { "first" => "same", "second" => "same" }
        )
      end
      assert_includes error.message, "duplicate paths"

      roots = Array.new(Hive::ArtifactFirewall::MAX_ENTRIES + 1) do |index|
        "root-#{index}"
      end
      error = assert_raises(Hive::ArtifactFirewall::InvalidManifest) do
        build_manifest(dir, roots: roots)
      end
      assert_includes error.message, "manifest exceeds max_entries"

      long_path = "a" * (Hive::ArtifactFirewall::MAX_PATH_BYTES + 1)
      error = assert_raises(Hive::ArtifactFirewall::InvalidManifest) do
        build_manifest(dir, protected: { "anchor" => long_path })
      end
      assert_includes error.message, "path exceeds"
    end
  end

  def test_manifest_wraps_path_normalization_encoding_failures
    with_tmp_dir do |dir|
      original_expand_path = File.method(:expand_path)
      invalid_result = lambda do |path, *rest|
        path == "invalid-result" ? "invalid-\xFF".b : original_expand_path.call(path, *rest)
      end
      with_replaced_singleton_method(File, :expand_path, invalid_result) do
        error = assert_raises(Hive::ArtifactFirewall::InvalidManifest) do
          build_manifest(dir, protected: { "anchor" => "invalid-result" })
        end
        assert_includes error.message, "valid UTF-8"
      end

      encoding_failure = lambda do |path, *rest|
        if path == "encoding-failure"
          raise Encoding::CompatibilityError, "synthetic incompatible encoding"
        end

        original_expand_path.call(path, *rest)
      end
      with_replaced_singleton_method(File, :expand_path, encoding_failure) do
        error = assert_raises(Hive::ArtifactFirewall::InvalidManifest) do
          build_manifest(dir, protected: { "anchor" => "encoding-failure" })
        end
        assert_includes error.message, "path encoding is invalid"
      end
    end
  end

  def test_capture_rejects_unstable_parents_and_wraps_internal_failures
    with_tmp_dir do |dir|
      manifest = build_manifest(dir, protected: { "anchor" => "anchor" })
      identities = [
        { "anchor" => { kind: :directory, inode: 1 }.freeze }.freeze,
        { "anchor" => { kind: :directory, inode: 2 }.freeze }.freeze
      ]
      observer = ->(_manifest) { identities.shift }
      with_replaced_singleton_method(
        Hive::ArtifactFirewall, :observe_parent_identities, observer
      ) do
        error = assert_raises(Hive::ArtifactFirewall::CaptureError) do
          Hive::ArtifactFirewall.capture(manifest)
        end
        assert_includes error.message, "parents changed during capture"
      end

      capture_failure = ->(_paths) { raise IOError, "synthetic capture failure" }
      with_replaced_singleton_method(
        Hive::ProtectedFiles, :capture_paths, capture_failure
      ) do
        error = assert_raises(Hive::ArtifactFirewall::CaptureError) do
          Hive::ArtifactFirewall.capture(manifest)
        end
        assert_instance_of IOError, error.cause
      end

      bounding_failure = ->(*_args) { raise "synthetic bounding failure" }
      with_replaced_singleton_method(
        Hive::ProtectedFiles, :capture_paths, capture_failure
      ) do
        with_replaced_singleton_method(
          Hive::ArtifactFirewall, :bounded, bounding_failure
        ) do
          error = assert_raises(Hive::ArtifactFirewall::CaptureError) do
            Hive::ArtifactFirewall.capture(manifest)
          end
          assert_equal "[REDACTION_FAILED]", error.message
        end
      end
    end
  end

  def test_validation_wraps_internal_failures_and_rejects_invalid_manifests
    with_tmp_dir do |dir|
      manifest = build_manifest(dir, protected: { "anchor" => "anchor" })
      snapshot = Hive::ArtifactFirewall.capture(manifest)
      observe_failure = ->(_paths) { raise "synthetic observation failure" }
      with_replaced_singleton_method(
        Hive::ProtectedFiles, :observe_paths, observe_failure
      ) do
        error = assert_raises(Hive::ArtifactFirewall::InvalidSnapshot) do
          Hive::ArtifactFirewall.validate(manifest, snapshot)
        end
        assert_instance_of RuntimeError, error.cause
      end

      error = assert_raises(Hive::ArtifactFirewall::InvalidManifest) do
        Hive::ArtifactFirewall.validate_required_outputs(Object.new)
      end
      assert_includes error.message, "manifest must be"

      output = File.join(dir, "output.md")
      output_manifest = build_manifest(
        dir,
        outputs: { "output" => output },
        roots: [ dir ]
      )
      original_lstat = File.method(:lstat)
      lstat_failure = lambda do |path|
        raise "synthetic lstat failure" if path == output

        original_lstat.call(path)
      end
      with_replaced_singleton_method(File, :lstat, lstat_failure) do
        error = assert_raises(Hive::ArtifactFirewall::InvalidManifest) do
          Hive::ArtifactFirewall.validate_required_outputs(output_manifest)
        end
        assert_instance_of RuntimeError, error.cause
      end
    end
  end

  def test_restore_accepts_a_stale_tamper_report_when_nothing_remains_changed
    with_tmp_dir do |dir|
      anchor = File.join(dir, "anchor")
      File.write(anchor, "trusted\n")
      manifest = build_manifest(dir, protected: { "anchor" => anchor })
      snapshot = Hive::ArtifactFirewall.capture(manifest)
      violation = Hive::ArtifactFirewall::Violation.new(
        kind: :protected_changed,
        label: "anchor",
        path: anchor,
        diagnostic: "previously changed"
      )
      report = Hive::ArtifactFirewall::Report.new(
        snapshot_id: snapshot.id,
        status: :tampered,
        violations: [ violation ],
        restoration: Hive::ArtifactFirewall::Restoration.new(
          attempted: false, succeeded: nil
        ),
        diagnostic: "previously changed"
      )

      restored = Hive::ArtifactFirewall.restore(manifest, snapshot, report)

      assert_equal :tampered_restored, restored.status
      assert_equal true, restored.restored?
      assert_equal "trusted\n", File.read(anchor)
    end
  end

  def test_unreadable_parent_and_required_output_are_typed
    with_tmp_dir do |dir|
      anchor = File.join(dir, "anchor")
      parent = File.dirname(anchor)
      manifest = build_manifest(dir, protected: { "anchor" => anchor })
      original_realpath = File.method(:realpath)
      inaccessible_parent = lambda do |path, *rest|
        raise Errno::EACCES, path if path == parent

        original_realpath.call(path, *rest)
      end
      with_replaced_singleton_method(File, :realpath, inaccessible_parent) do
        snapshot = Hive::ArtifactFirewall.capture(manifest)
        assert_equal :unreadable,
                     snapshot.parent_identities.fetch("anchor").fetch(:kind)
      end

      output = File.join(dir, "output.md")
      output_manifest = build_manifest(
        dir,
        outputs: { "output" => output },
        roots: [ dir ]
      )
      original_lstat = File.method(:lstat)
      inaccessible_output = lambda do |path|
        raise Errno::EACCES, path if path == output

        original_lstat.call(path)
      end
      with_replaced_singleton_method(File, :lstat, inaccessible_output) do
        report = Hive::ArtifactFirewall.validate_required_outputs(output_manifest)
        assert_equal :required_output_unreadable,
                     report.required_output_violations.fetch(0).kind
      end
    end
  end

  def test_required_output_must_be_openable_and_readable
    with_tmp_dir do |dir|
      output = File.join(dir, "output.md")
      File.write(output, "nonempty but unreadable\n")
      File.chmod(0o000, output)
      manifest = build_manifest(
        dir,
        outputs: { "output" => output },
        roots: [ dir ]
      )

      report = Hive::ArtifactFirewall.validate_required_outputs(manifest)

      assert_equal :rejected, report.status
      assert_equal :required_output_unreadable,
                   report.required_output_violations.fetch(0).kind
    ensure
      File.chmod(0o600, output) if output && File.exist?(output)
    end
  end

  def test_required_output_rejects_descriptor_substitution_races
    with_tmp_dir do |dir|
      non_regular = File.join(dir, "non-regular.md")
      symlink = File.join(dir, "symlink.md")
      File.write(non_regular, "replaced after lstat\n")
      File.write(symlink, "replaced after lstat\n")
      manifest = build_manifest(
        dir,
        outputs: {
          "non_regular" => non_regular,
          "symlink" => symlink
        },
        roots: [ dir ]
      )
      opened_stat = Struct.new(:file?).new(false)
      opened_file = Struct.new(:stat) do
        def close = nil
      end.new(opened_stat)
      original_open = File.method(:open)
      descriptor_substitution = lambda do |path, *args, **kwargs, &block|
        case path
        when non_regular then opened_file
        when symlink then raise Errno::ELOOP, path
        else original_open.call(path, *args, **kwargs, &block)
        end
      end

      report = with_replaced_singleton_method(
        File, :open, descriptor_substitution
      ) do
        Hive::ArtifactFirewall.validate_required_outputs(manifest)
      end
      kinds = report.required_output_violations.to_h do |violation|
        [ violation.label, violation.kind ]
      end

      assert_equal :required_output_non_regular, kinds.fetch("non_regular")
      assert_equal :required_output_symlink, kinds.fetch("symlink")
    end
  end

  def test_violation_rejects_unknown_kind
    error = assert_raises(ArgumentError) do
      Hive::ArtifactFirewall::Violation.new(
        kind: :unknown, label: "x", path: "x", diagnostic: "x"
      )
    end

    assert_includes error.message, "unknown artifact custody violation"
  end

  def test_manifest_wraps_without_freezing_the_callers_redactor
    with_tmp_dir do |dir|
      redactor = Object.new
      redactor.define_singleton_method(:call) { |text| text }

      manifest = build_manifest(dir, redactor: redactor)

      refute redactor.frozen?
      assert manifest.redactor.frozen?
      assert_equal "value", manifest.redactor.call("value")
    end
  end

  def test_agent_custody_encloses_only_its_single_untrusted_call
    with_tmp_dir do |dir|
      protected_path = File.join(dir, "task-journal.jsonl")
      File.write(protected_path, "controller start\n")
      custody = Hive::ArtifactFirewall::AgentCustody.new(
        build_manifest(dir, protected: { "journal" => protected_path })
      )

      result = custody.call do
        File.write(protected_path, "agent forged\n")
        :provider_result
      end
      File.open(protected_path, "ab") { |file| file.write("controller finish\n") }

      assert_equal :provider_result, result
      assert custody.called?
      assert custody.report.tampered?
      assert custody.report.restored?
      assert_equal "controller start\ncontroller finish\n", File.binread(protected_path)
      assert_raises(Hive::ArtifactFirewall::Error) { custody.call { :again } }
    end
  end

  def test_agent_custody_rejects_a_non_callable_before_validation_hook
    with_tmp_dir do |dir|
      error = assert_raises(ArgumentError) do
        Hive::ArtifactFirewall::AgentCustody.new(
          build_manifest(dir),
          before_validation: Object.new
        )
      end

      assert_equal "before_validation must respond to call", error.message
    end
  end

  def test_manifest_accepts_a_larger_explicit_entry_limit
    with_tmp_dir do |dir|
      count = Hive::ArtifactFirewall::MAX_ENTRIES + 5
      protected = count.times.to_h do |index|
        [ "anchor-#{index}", File.join(dir, "anchor-#{index}") ]
      end
      protected.each_value { |path| File.write(path, "trusted\n") }

      manifest = build_manifest(dir, protected:, max_entries: count)
      custody = Hive::ArtifactFirewall::AgentCustody.new(manifest)
      custody.call { File.write(protected.fetch("anchor-132"), "forged\n") }

      assert_equal count, manifest.max_entries
      assert custody.report.tampered?
      assert custody.report.restored?
      assert_equal "trusted\n", File.read(protected.fetch("anchor-132"))
    end
  end

  def test_manifest_rejects_entry_limits_above_the_hard_cap
    with_tmp_dir do |dir|
      error = assert_raises(Hive::ArtifactFirewall::InvalidManifest) do
        build_manifest(
          dir,
          max_entries: Hive::ArtifactFirewall::HARD_MAX_ENTRIES + 1
        )
      end

      assert_includes error.message, Hive::ArtifactFirewall::HARD_MAX_ENTRIES.to_s
    end
  end

  def test_manifest_entry_limit_applies_to_the_aggregate_inventory
    with_tmp_dir do |dir|
      error = assert_raises(Hive::ArtifactFirewall::InvalidManifest) do
        build_manifest(
          dir,
          protected: { "anchor-a" => "a", "anchor-b" => "b" },
          outputs: { "output-a" => "c", "output-b" => "d" },
          roots: %w[root-a root-b],
          max_entries: 5
        )
      end

      assert_includes error.message, "manifest exceeds max_entries"
      assert_includes error.message, "6 > 5"
    end
  end

  def test_manifest_rejects_a_non_integer_entry_limit
    with_tmp_dir do |dir|
      error = assert_raises(Hive::ArtifactFirewall::InvalidManifest) do
        build_manifest(dir, max_entries: "many")
      end

      assert_includes error.message, "max_entries must be an integer"
    end
  end

  def test_controller_journal_appends_during_custody_are_not_tampering
    with_tmp_dir do |dir|
      journal = File.join(dir, "task-journal.jsonl")
      plan = File.join(dir, "plan.md")
      File.write(plan, "trusted plan\n")
      controller_journal_append(dir, "before")
      baseline = File.binread(journal)
      manifest = build_manifest(
        dir, protected: { "task-journal.jsonl" => journal, "plan.md" => plan }
      )
      custody = Hive::ArtifactFirewall::AgentCustody.new(manifest)

      custody.call do
        controller_journal_append(dir, "session-started")
        controller_journal_append(dir, "github-pr-merged")
      end

      assert_equal :clean, custody.report.status
      assert custody.report.valid?
      assert File.binread(journal).start_with?(baseline)
      assert_equal %w[before session-started github-pr-merged], journal_ids(journal)
    end
  end

  def test_restore_after_other_tamper_keeps_controller_journal_appends
    with_tmp_dir do |dir|
      journal = File.join(dir, "task-journal.jsonl")
      plan = File.join(dir, "plan.md")
      File.write(plan, "trusted plan\n")
      controller_journal_append(dir, "before")
      manifest = build_manifest(
        dir, protected: { "task-journal.jsonl" => journal, "plan.md" => plan }
      )
      snapshot = Hive::ArtifactFirewall.capture(manifest)

      controller_journal_append(dir, "during")
      File.write(plan, "forged plan\n")
      report = Hive::ArtifactFirewall.validate_and_restore(manifest, snapshot)

      assert_equal :tampered_restored, report.status
      assert_equal [ "plan.md" ], report.tampered_labels
      assert_equal "trusted plan\n", File.read(plan)
      assert_equal %w[before during], journal_ids(journal)
    end
  end

  def test_agent_journal_truncation_and_rewrite_are_tampering_and_restore_keeps_controller_records
    { truncate: ->(journal, _lines) { File.write(journal, "") },
      rewrite: lambda { |journal, lines|
        File.write(journal, lines.first.sub('"observed"', '"forged"') + lines[1..].join)
      } }.each do |mode, mutate|
      with_tmp_dir do |dir|
        journal = File.join(dir, "task-journal.jsonl")
        controller_journal_append(dir, "first")
        controller_journal_append(dir, "second")
        baseline = File.binread(journal)
        manifest = build_manifest(dir, protected: { "task-journal.jsonl" => journal })
        snapshot = Hive::ArtifactFirewall.capture(manifest)

        mutate.call(journal, File.readlines(journal))
        controller_journal_append(dir, "during-#{mode}")
        report = Hive::ArtifactFirewall.validate_and_restore(manifest, snapshot)

        assert_equal :tampered_restored, report.status, mode
        assert_equal [ :protected_changed ], report.violations.map(&:kind)
        assert_includes report.diagnostic, "append-only anchor"
        assert File.binread(journal).start_with?(baseline), mode
        assert_equal [ "first", "second", "during-#{mode}" ], journal_ids(journal)
      end
    end
  end

  def test_journal_growth_must_be_complete_new_journal_records_with_the_same_mode
    first_line = nil
    {
      "partial line" => ->(journal) { File.open(journal, "ab") { |f| f.write('{"schema"') } },
      "foreign line" => ->(journal) { File.open(journal, "ab") { |f| f.write("not json\n") } },
      "non-journal json" => ->(journal) { File.open(journal, "ab") { |f| f.write("{\"event_id\":\"x\"}\n") } },
      "array json" => ->(journal) { File.open(journal, "ab") { |f| f.write("[1]\n") } },
      "blank event id" => lambda { |journal|
        File.open(journal, "ab") { |f| f.write(first_line.sub(/"event_id":"[^"]+"/, '"event_id":""')) }
      },
      "replayed record" => ->(journal) { File.open(journal, "ab") { |f| f.write(first_line) } },
      "invalid utf-8" => ->(journal) { File.open(journal, "ab") { |f| f.write("\xff\n".b) } },
      "mode change" => ->(journal) { File.chmod(0o600, journal) },
      "symlink" => lambda { |journal|
        File.rename(journal, "#{journal}.real")
        File.symlink("#{journal}.real", journal)
      }
    }.each do |name, mutate|
      with_tmp_dir do |dir|
        journal = File.join(dir, "task-journal.jsonl")
        controller_journal_append(dir, "first")
        File.chmod(0o644, journal)
        first_line = File.read(journal)
        manifest = build_manifest(dir, protected: { "task-journal.jsonl" => journal })
        snapshot = Hive::ArtifactFirewall.capture(manifest)

        mutate.call(journal)
        report = Hive::ArtifactFirewall.validate_and_restore(manifest, snapshot)

        assert report.tampered?, name
        assert_equal :tampered_restored, report.status, name
        assert_equal first_line, File.read(journal), name
        assert_equal 0o644, File.lstat(journal).mode & 0o777, name
      end
    end
  end

  def test_journal_created_during_custody_is_kept_only_when_controller_written
    with_tmp_dir do |dir|
      journal = File.join(dir, "task-journal.jsonl")
      manifest = build_manifest(dir, protected: { "task-journal.jsonl" => journal })
      snapshot = Hive::ArtifactFirewall.capture(manifest)
      controller_journal_append(dir, "created")

      assert_equal :clean, Hive::ArtifactFirewall.validate(manifest, snapshot).status
    end

    with_tmp_dir do |dir|
      journal = File.join(dir, "task-journal.jsonl")
      manifest = build_manifest(dir, protected: { "task-journal.jsonl" => journal })
      snapshot = Hive::ArtifactFirewall.capture(manifest)
      File.write(journal, "forged\n")

      report = Hive::ArtifactFirewall.validate_and_restore(manifest, snapshot)

      assert_equal :tampered_restored, report.status
      assert_equal [ :protected_added ], report.violations.map(&:kind)
      refute File.exist?(journal)
    end

    with_tmp_dir do |dir|
      journal = File.join(dir, "task-journal.jsonl")
      manifest = build_manifest(dir, protected: { "task-journal.jsonl" => journal })
      snapshot = Hive::ArtifactFirewall.capture(manifest)
      File.write(journal, "forged\n")
      controller_journal_append(dir, "created")

      report = Hive::ArtifactFirewall.validate_and_restore(manifest, snapshot)

      assert_equal :tampered_restored, report.status
      assert_equal %w[created], journal_ids(journal)
      assert_equal 0o644, File.stat(journal).mode & 0o777
    end
  end

  def test_journal_custody_without_an_openable_writer_lock_still_fails_closed
    with_tmp_dir do |dir|
      journal = File.join(dir, "task-journal.jsonl")
      controller_journal_append(dir, "first")
      lock = File.join(dir, Hive::TaskJournal::LOCK_BASENAME)
      File.delete(lock)
      Dir.mkdir(lock)
      manifest = build_manifest(dir, protected: { "task-journal.jsonl" => journal })
      snapshot = Hive::ArtifactFirewall.capture(manifest)
      File.open(journal, "ab") { |file| file.write("garbage\n") }

      report = Hive::ArtifactFirewall.validate_and_restore(manifest, snapshot)

      assert_equal :tampered_restored, report.status
      assert_equal %w[first], journal_ids(journal)
    end
  end

  def test_journal_that_was_not_a_regular_file_is_not_reconstructed
    with_tmp_dir do |dir|
      journal = File.join(dir, "task-journal.jsonl")
      File.write(File.join(dir, "elsewhere"), "")
      File.symlink(File.join(dir, "elsewhere"), journal)
      manifest = build_manifest(dir, protected: { "task-journal.jsonl" => journal })
      snapshot = Hive::ArtifactFirewall.capture(manifest)
      File.unlink(journal)
      File.write(journal, "replaced\n")

      report = Hive::ArtifactFirewall.validate_and_restore(manifest, snapshot)

      assert_equal :restore_failed, report.status
      assert_includes report.restore_diagnostic, "cannot be reconstructed safely"
    end
  end

  def test_append_only_log_names_match_the_task_journal_writer
    assert_equal(
      { Hive::TaskJournal::JOURNAL_BASENAME => Hive::TaskJournal::LOCK_BASENAME },
      Hive::ProtectedFiles::APPEND_ONLY_LOGS
    )
    assert_equal Hive::TaskJournal::Envelope::SCHEMA,
                 Hive::ProtectedFiles::APPEND_ONLY_RECORD_SCHEMA
    assert_includes Hive::ArtifactFirewall::ORCHESTRATOR_OWNED,
                    Hive::TaskJournal::JOURNAL_BASENAME
  end

  private

  # Appends exactly as Hive's controller and daemon writers do: through the
  # work ledger, under the journal's own flock.
  def controller_journal_append(dir, event_id)
    record = Hive::TaskJournal::Envelope.authoritative(
      {
        event_id: event_id, event_type: "activity_recorded",
        task: { "slug" => "journal-custody" }, stage: "7-artifacts",
        attempt_id: "attempt-1", task_generation: 1, reason: "observed",
        provenance: { "source" => "github" }
      }
    )
    Hive::WorkLedger.journal(
      path: File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME),
      lock_path: File.join(dir, Hive::TaskJournal::LOCK_BASENAME),
      record_id: ->(entry) { entry.fetch("event_id") }
    ).append([ record ])
  end

  def journal_ids(journal)
    File.readlines(journal).map { |line| JSON.parse(line).fetch("event_id") }
  end

  def build_manifest(dir, protected: {}, outputs: {}, roots: [],
                     redactor: Hive::SecretPatterns.method(:redact),
                     max_entries: Hive::ArtifactFirewall::MAX_ENTRIES)
    Hive::ArtifactFirewall::Manifest.new(
      root: dir,
      protected_anchors: protected,
      permitted_writable_roots: roots,
      required_outputs: outputs,
      redactor: redactor,
      max_entries: max_entries
    )
  end
end
