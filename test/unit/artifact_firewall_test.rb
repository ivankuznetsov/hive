require "test_helper"
require "hive/artifact_firewall"

class ArtifactFirewallTest < Minitest::Test
  include HiveTestHelper

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
      assert_includes error.message, "permitted_writable_roots exceeds"

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

  private

  def build_manifest(dir, protected: {}, outputs: {}, roots: [], redactor: Hive::SecretPatterns.method(:redact))
    Hive::ArtifactFirewall::Manifest.new(
      root: dir,
      protected_anchors: protected,
      permitted_writable_roots: roots,
      required_outputs: outputs,
      redactor: redactor
    )
  end
end
