require "hive/protected_files"
require "hive/secret_patterns"
require "securerandom"

module Hive
  # Application-level custody for artifacts around an untrusted agent spawn.
  #
  # The firewall records controller-owned anchors before a spawn, validates
  # their post-run identities, checks required output shape, and can safely
  # restore reconstructable anchors. It does not prevent same-user writes,
  # scan arbitrary writable trees, isolate processes, or provide a filesystem
  # transaction. Hive adapters retain stage path policy and outcome semantics.
  module ArtifactFirewall
    DIAGNOSTIC_BYTES = 512
    MAX_ENTRIES = 128
    MAX_PATH_BYTES = 4_096
    REQUIRED_OUTPUT_INSPECTION_ID = "required-output-inspection"
    ORCHESTRATOR_OWNED = Hive::ProtectedFiles::ORCHESTRATOR_OWNED

    class Error < StandardError; end
    class InvalidManifest < Error; end
    class CaptureError < Error; end
    class InvalidSnapshot < Error; end

    Violation = Data.define(:kind, :label, :path, :diagnostic) do
      PROTECTED_KINDS = %i[
        protected_added
        protected_changed
        protected_deleted
        protected_directory_substitution
        protected_mode_changed
        protected_parent_changed
        protected_symlink_substitution
        protected_type_substitution
        protected_unreadable
      ].freeze

      REQUIRED_OUTPUT_KINDS = %i[
        required_output_empty
        required_output_missing
        required_output_non_regular
        required_output_outside_root
        required_output_symlink
        required_output_unreadable
      ].freeze

      def initialize(kind:, label:, path:, diagnostic:)
        kind = kind.to_sym
        unless (PROTECTED_KINDS + REQUIRED_OUTPUT_KINDS).include?(kind)
          raise ArgumentError, "unknown artifact custody violation #{kind.inspect}"
        end

        super(
          kind: kind,
          label: label.to_s.dup.freeze,
          path: path.to_s.dup.freeze,
          diagnostic: diagnostic.to_s.dup.freeze
        )
      end

      def protected_anchor?
        PROTECTED_KINDS.include?(kind)
      end

      def required_output?
        REQUIRED_OUTPUT_KINDS.include?(kind)
      end
    end

    Restoration = Data.define(:attempted, :succeeded, :diagnostic) do
      def initialize(attempted:, succeeded:, diagnostic: nil)
        attempted = attempted == true
        succeeded = succeeded == true if attempted
        succeeded = nil unless attempted
        super(
          attempted: attempted,
          succeeded: succeeded,
          diagnostic: diagnostic&.to_s&.dup&.freeze
        )
      end
    end

    Report = Data.define(
      :schema_version, :snapshot_id, :status, :violations, :restoration, :diagnostic
    ) do
      STATUSES = %i[clean rejected tampered tampered_restored restore_failed].freeze

      def initialize(schema_version: 1, snapshot_id:, status:, violations:,
                     restoration:, diagnostic:)
        status = status.to_sym
        raise ArgumentError, "unknown artifact custody status #{status.inspect}" unless STATUSES.include?(status)

        super(
          schema_version: Integer(schema_version),
          snapshot_id: snapshot_id.to_s.dup.freeze,
          status: status,
          violations: Array(violations).dup.freeze,
          restoration: restoration,
          diagnostic: diagnostic.to_s.dup.freeze
        )
      end

      def valid?
        status == :clean
      end

      def tampered?
        violations.any?(&:protected_anchor?)
      end

      def required_outputs_valid?
        violations.none?(&:required_output?)
      end

      def tampered_labels
        violations.select(&:protected_anchor?).map(&:label).uniq.freeze
      end

      def required_output_violations
        violations.select(&:required_output?).freeze
      end

      def restored?
        restoration.attempted ? restoration.succeeded : nil
      end

      def restore_diagnostic
        restoration.diagnostic
      end
    end

    Manifest = Data.define(
      :root, :protected_anchors, :permitted_writable_roots, :required_outputs, :redactor
    ) do
      def initialize(root:, protected_anchors:, permitted_writable_roots: [],
                     required_outputs: {}, redactor: Hive::SecretPatterns.method(:redact))
        normalized_root = self.class.send(:normalize_root, root)
        anchors = self.class.send(
          :normalize_labeled_paths, protected_anchors, normalized_root, "protected_anchors"
        )
        outputs = self.class.send(
          :normalize_labeled_paths, required_outputs, normalized_root, "required_outputs"
        )
        roots = self.class.send(
          :normalize_roots, permitted_writable_roots, normalized_root
        )
        self.class.send(:validate_path_ownership!, anchors, outputs)
        unless redactor.respond_to?(:call)
          raise InvalidManifest, "redactor must respond to #call"
        end
        redactor_callable = redactor

        super(
          root: normalized_root,
          protected_anchors: anchors,
          permitted_writable_roots: roots,
          required_outputs: outputs,
          redactor: ->(text) { redactor_callable.call(text) }.freeze
        )
      end

      def self.normalize_root(root)
        value = root.to_s
        raise InvalidManifest, "root must not be empty" if value.empty?

        normalize_path(expand_path(value, nil, "root"), "root")
      end
      private_class_method :normalize_root

      def self.normalize_labeled_paths(entries, root, field)
        pairs =
          if entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(String) }
            entries.to_h { |entry| [ entry, entry ] }
          elsif entries.respond_to?(:to_h)
            entries.to_h
          else
            raise InvalidManifest, "#{field} must be relative names or a label-to-path mapping"
          end
        if pairs.length > MAX_ENTRIES
          raise InvalidManifest, "#{field} exceeds #{MAX_ENTRIES} entries"
        end

        normalized = pairs.each_with_object({}) do |(label, path), result|
          safe_label = label.to_s
          raise InvalidManifest, "#{field} labels must not be empty" if safe_label.empty?

          expanded = expand_path(path, root, "#{field}[#{safe_label.inspect}]")
          result[safe_label.dup.freeze] = normalize_path(expanded, "#{field}[#{safe_label.inspect}]")
        end
        duplicate_paths = normalized.group_by { |_label, path| path }
                                    .select { |_path, rows| rows.length > 1 }
                                    .keys
        unless duplicate_paths.empty?
          raise InvalidManifest, "#{field} contains duplicate paths"
        end

        normalized.freeze
      end
      private_class_method :normalize_labeled_paths

      def self.normalize_roots(entries, root)
        roots = Array(entries)
        if roots.length > MAX_ENTRIES
          raise InvalidManifest, "permitted_writable_roots exceeds #{MAX_ENTRIES} entries"
        end

        roots.map do |path|
          normalize_path(
            expand_path(path, root, "permitted_writable_roots"),
            "permitted_writable_roots"
          )
        end.uniq.freeze
      end
      private_class_method :normalize_roots

      def self.validate_path_ownership!(anchors, outputs)
        overlap = anchors.values & outputs.values
        return if overlap.empty?

        raise InvalidManifest, "a required output cannot also be a protected anchor"
      end
      private_class_method :validate_path_ownership!

      def self.normalize_path(path, field)
        value = path.to_s.dup.force_encoding(Encoding::UTF_8)
        unless value.valid_encoding?
          raise InvalidManifest, "#{field} path must be valid UTF-8"
        end
        if value.bytesize > MAX_PATH_BYTES
          raise InvalidManifest, "#{field} path exceeds #{MAX_PATH_BYTES} bytes"
        end

        value.freeze
      end
      private_class_method :normalize_path

      def self.expand_path(path, root, field)
        value = path.to_s.dup.force_encoding(Encoding::UTF_8)
        unless value.valid_encoding?
          raise InvalidManifest, "#{field} path must be valid UTF-8"
        end

        root ? File.expand_path(value, root) : File.expand_path(value)
      rescue EncodingError => e
        raise InvalidManifest, "#{field} path encoding is invalid: #{e.class}"
      end
      private_class_method :expand_path
    end

    Snapshot = Data.define(
      :schema_version, :id, :manifest, :captured, :observed, :parent_identities
    ) do
      def initialize(schema_version: 1, id:, manifest:, captured:, observed:,
                     parent_identities:)
        super(
          schema_version: Integer(schema_version),
          id: id.to_s.dup.freeze,
          manifest: manifest,
          captured: self.class.send(:immutable_capture, captured),
          observed: self.class.send(:immutable_identities, observed),
          parent_identities: self.class.send(
            :immutable_identities, parent_identities
          )
        )
      end

      def self.immutable_identities(identities)
        identities.to_h do |label, identity|
          [ immutable_value(label), immutable_value(identity) ]
        end.freeze
      end
      private_class_method :immutable_identities

      def self.immutable_capture(captured)
        captured.to_h do |label, entry|
          [ immutable_value(label), immutable_value(entry) ]
        end.freeze
      end
      private_class_method :immutable_capture

      def self.immutable_value(value)
        case value
        when Hash
          value.to_h do |key, entry|
            [ immutable_value(key), immutable_value(entry) ]
          end.freeze
        when Array
          value.map { |entry| immutable_value(entry) }.freeze
        when String
          value.dup.freeze
        else
          value
        end
      end
      private_class_method :immutable_value
    end

    module_function

    def capture(manifest)
      validate_manifest!(manifest)
      parents_before = observe_parent_identities(manifest)
      captured = Hive::ProtectedFiles.capture_paths(manifest.protected_anchors)
      parents_after = observe_parent_identities(manifest)
      unstable_parents = changed_identity_labels(parents_before, parents_after)
      unless unstable_parents.empty?
        raise CaptureError, bounded(
          manifest,
          "protected anchor parents changed during capture: #{unstable_parents.join(', ')}"
        )
      end

      Snapshot.new(
        id: SecureRandom.uuid,
        manifest: manifest,
        captured: captured,
        observed: captured.to_h do |label, entry|
          [ label, entry.fetch(:identity) ]
        end,
        parent_identities: parents_after
      )
    rescue Error
      raise
    rescue StandardError => e
      raise CaptureError, safe_diagnostic(manifest, e), cause: e
    end

    def validate(manifest, snapshot)
      validate_snapshot!(manifest, snapshot)
      current = Hive::ProtectedFiles.observe_paths(manifest.protected_anchors)
      violations = protected_violations(manifest, snapshot.observed, current)
      violations.concat(
        protected_parent_violations(
          manifest, snapshot.parent_identities, observe_parent_identities(manifest)
        )
      )
      violations.concat(required_output_violations(manifest))
      build_report(
        manifest,
        snapshot.id,
        violations,
        restoration: Restoration.new(attempted: false, succeeded: nil)
      )
    rescue Error
      raise
    rescue StandardError => e
      raise InvalidSnapshot, safe_diagnostic(manifest, e), cause: e
    end

    # Read-only required-output admission for polling consumers. Final stage
    # acceptance should still use #validate with its spawn-bound Snapshot
    # whenever protected anchors are also in scope.
    def validate_required_outputs(manifest)
      validate_manifest!(manifest)
      build_report(
        manifest,
        REQUIRED_OUTPUT_INSPECTION_ID,
        required_output_violations(manifest),
        restoration: Restoration.new(attempted: false, succeeded: nil)
      )
    rescue Error
      raise
    rescue StandardError => e
      raise InvalidManifest, safe_diagnostic(manifest, e), cause: e
    end

    def restore(manifest, snapshot, report)
      validate_snapshot!(manifest, snapshot)
      unless report.is_a?(Report) && report.snapshot_id == snapshot.id
        raise InvalidSnapshot, "report does not belong to the supplied custody snapshot"
      end
      return report unless report.tampered?
      return report if report.restoration.attempted

      current_anchors = Hive::ProtectedFiles.observe_paths(manifest.protected_anchors)
      current_parents = observe_parent_identities(manifest)
      changed_anchors = changed_identity_labels(snapshot.observed, current_anchors)
      changed_parents = changed_identity_labels(
        snapshot.parent_identities, current_parents
      )
      labels = (changed_anchors | changed_parents).freeze
      unless changed_parents.empty?
        parent_violations = protected_parent_violations(
          manifest, snapshot.parent_identities, current_parents
        )
        existing = report.violations.map { |entry| [ entry.kind, entry.label ] }
        violations = report.violations + parent_violations.reject do |entry|
          existing.include?([ entry.kind, entry.label ])
        end
        return build_report(
          manifest,
          snapshot.id,
          violations,
          restoration: Restoration.new(
            attempted: true,
            succeeded: false,
            diagnostic: bounded(
              manifest,
              "refusing restoration after protected parent substitution: " \
              "#{changed_parents.join(', ')}"
            )
          )
        )
      end

      if labels.empty?
        return build_report(
          manifest,
          snapshot.id,
          report.violations,
          restoration: Restoration.new(attempted: true, succeeded: true)
        )
      end

      restored, error = Hive::ProtectedFiles.restore_paths_safely(
        manifest.protected_anchors, snapshot.captured, labels
      )
      restoration = Restoration.new(
        attempted: true,
        succeeded: restored,
        diagnostic: error && safe_diagnostic(manifest, error)
      )
      build_report(
        manifest,
        snapshot.id,
        report.violations,
        restoration: restoration
      )
    end

    def validate_and_restore(manifest, snapshot)
      report = validate(manifest, snapshot)
      report.tampered? ? restore(manifest, snapshot, report) : report
    end

    def protected_violations(manifest, before, after)
      manifest.protected_anchors.filter_map do |label, path|
        prior = before.fetch(label)
        current = after.fetch(label)
        next if prior == current

        kind = protected_violation_kind(prior, current)
        violation(
          manifest, kind, label, path,
          "protected anchor #{label.inspect} changed from #{identity_name(prior)} " \
          "to #{identity_name(current)}"
        )
      end
    end
    private_class_method :protected_violations

    def protected_parent_violations(manifest, before, after)
      manifest.protected_anchors.filter_map do |label, path|
        next if before.fetch(label) == after.fetch(label)

        violation(
          manifest, :protected_parent_changed, label, path,
          "protected anchor #{label.inspect} parent changed"
        )
      end
    end
    private_class_method :protected_parent_violations

    def observe_parent_identities(manifest)
      manifest.protected_anchors.to_h do |label, path|
        [ label, parent_identity(path) ]
      end
    end
    private_class_method :observe_parent_identities

    def parent_identity(path)
      parent = File.dirname(path)
      resolved = File.realpath(parent)
      stat = File.stat(resolved)
      {
        kind: stat.directory? ? :directory : stat.ftype.to_sym,
        realpath: resolved,
        device: stat.dev,
        inode: stat.ino,
        mode: stat.mode & 0o777
      }.freeze
    rescue Errno::ENOENT
      { kind: :missing }.freeze
    rescue SystemCallError, IOError => e
      { kind: :unreadable, error_class: e.class.name }.freeze
    end
    private_class_method :parent_identity

    def changed_identity_labels(before, after)
      before.keys.reject { |label| before.fetch(label) == after.fetch(label) }
    end
    private_class_method :changed_identity_labels

    def protected_violation_kind(prior, current)
      prior_kind = prior.fetch(:kind)
      current_kind = current.fetch(:kind)
      return :protected_added if prior_kind == :missing && current_kind != :missing
      return :protected_deleted if prior_kind != :missing && current_kind == :missing
      return :protected_unreadable if current_kind == :unreadable
      return :protected_symlink_substitution if current_kind == :symlink && prior_kind != :symlink
      return :protected_directory_substitution if current_kind == :directory && prior_kind != :directory
      return :protected_type_substitution if prior_kind != current_kind
      if prior_kind == :file &&
         prior[:sha256] == current[:sha256] &&
         prior[:mode] != current[:mode]
        return :protected_mode_changed
      end

      :protected_changed
    end
    private_class_method :protected_violation_kind

    def required_output_violations(manifest)
      manifest.required_outputs.filter_map do |label, path|
        unless permitted_output_path?(manifest, path)
          next violation(
            manifest, :required_output_outside_root, label, path,
            "required output #{label.inspect} is outside every permitted writable root"
          )
        end

        required_output_violation(manifest, label, path)
      end
    end
    private_class_method :required_output_violations

    def required_output_violation(manifest, label, path)
      stat = File.lstat(path)
      if stat.symlink?
        return violation(
          manifest, :required_output_symlink, label, path,
          "required output #{label.inspect} is a symlink"
        )
      end
      unless stat.file?
        return violation(
          manifest, :required_output_non_regular, label, path,
          "required output #{label.inspect} is not a regular file"
        )
      end
      if stat.size.zero?
        return violation(
          manifest, :required_output_empty, label, path,
          "required output #{label.inspect} is empty"
        )
      end

      nil
    rescue Errno::ENOENT
      violation(
        manifest, :required_output_missing, label, path,
        "required output #{label.inspect} is missing"
      )
    rescue SystemCallError, IOError => e
      violation(
        manifest, :required_output_unreadable, label, path,
        "required output #{label.inspect} is unreadable: #{e.class}"
      )
    end
    private_class_method :required_output_violation

    def permitted_output_path?(manifest, path)
      manifest.permitted_writable_roots.any? do |root|
        lexical = path == root || path.start_with?("#{root}#{File::SEPARATOR}")
        next false unless lexical

        resolved_root = File.realpath(root)
        resolved_parent = File.realpath(File.dirname(path))
        resolved_parent == resolved_root ||
          resolved_parent.start_with?("#{resolved_root}#{File::SEPARATOR}")
      rescue SystemCallError
        false
      end
    end
    private_class_method :permitted_output_path?

    def violation(manifest, kind, label, path, diagnostic)
      Violation.new(
        kind: kind,
        label: bounded(manifest, label),
        path: bounded(manifest, path),
        diagnostic: bounded(manifest, diagnostic)
      )
    end
    private_class_method :violation

    def build_report(manifest, snapshot_id, violations, restoration:)
      status =
        if violations.none?(&:protected_anchor?)
          violations.empty? ? :clean : :rejected
        elsif !restoration.attempted
          :tampered
        elsif restoration.succeeded
          :tampered_restored
        else
          :restore_failed
        end
      diagnostic = violations.map(&:diagnostic).join("; ")
      diagnostic = "artifact custody validated" if diagnostic.empty?
      if restoration.attempted
        restoration_text = restoration.succeeded ? "restoration verified" :
          "restoration failed: #{restoration.diagnostic}"
        diagnostic = "#{diagnostic}; #{restoration_text}"
      end

      Report.new(
        snapshot_id: snapshot_id,
        status: status,
        violations: violations,
        restoration: restoration,
        diagnostic: bounded(manifest, diagnostic)
      )
    end
    private_class_method :build_report

    def validate_manifest!(manifest)
      return if manifest.is_a?(Manifest)

      raise InvalidManifest, "manifest must be a Hive::ArtifactFirewall::Manifest"
    end
    private_class_method :validate_manifest!

    def validate_snapshot!(manifest, snapshot)
      validate_manifest!(manifest)
      unless snapshot.is_a?(Snapshot) && snapshot.manifest.equal?(manifest)
        raise InvalidSnapshot, "snapshot does not belong to the supplied manifest"
      end
    end
    private_class_method :validate_snapshot!

    def identity_name(identity)
      identity.fetch(:kind).to_s
    end
    private_class_method :identity_name

    def safe_diagnostic(manifest, value)
      return "[REDACTION_FAILED]" unless manifest.is_a?(Manifest)

      bounded(manifest, "#{value.class}: #{value}")
    rescue StandardError
      "[REDACTION_FAILED]"
    end
    private_class_method :safe_diagnostic

    def bounded(manifest, value)
      redacted = manifest.redactor.call(value.to_s).to_s
      text = redacted.dup.force_encoding(Encoding::UTF_8).scrub("?")
      return text.freeze if text.bytesize <= DIAGNOSTIC_BYTES

      suffix = "…"
      slice = text.byteslice(0, DIAGNOSTIC_BYTES - suffix.bytesize)
      slice = slice.dup.force_encoding(Encoding::UTF_8).scrub("")
      "#{slice}#{suffix}".freeze
    rescue StandardError
      "[REDACTION_FAILED]".freeze
    end
    private_class_method :bounded
  end
end
