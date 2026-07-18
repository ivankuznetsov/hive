require "digest"
require "hive/workflow_package/manifest"
require "hive/workflow_package/security_scanner"
require "hive/workflows/descriptor_parser"

module Hive
  module WorkflowPackage
    class Validator
      Result = Data.define(:manifest, :workflow, :manifest_digest, :diagnostics) do
        def valid? = errors.empty?
        def errors = diagnostics.select(&:error?)
        def warnings = diagnostics.select(&:warning?)

        def to_h
          {
            "valid" => valid?,
            "manifest_digest" => manifest_digest,
            "diagnostics" => diagnostics.map(&:to_h)
          }
        end
      end

      def self.validate(root, expected_name: nil, expected_manifest_digest: nil, managed: true)
        new(root, expected_name: expected_name, expected_manifest_digest: expected_manifest_digest,
                  managed: managed).validate
      end

      def self.validate!(...)
        result = validate(...)
        raise PackageError, result.errors.first unless result.valid?

        result
      end

      def initialize(root, expected_name:, expected_manifest_digest:, managed:)
        @root = File.expand_path(root)
        @expected_name = expected_name&.to_s
        @expected_manifest_digest = expected_manifest_digest&.to_s
        @managed = managed
      end

      def validate
        diagnostics = []
        manifest = Manifest.load(File.join(@root, Manifest::FILE_NAME))
        digest = manifest.digest
        if @expected_manifest_digest && !secure_equal?(digest, @expected_manifest_digest)
          diagnostics << diagnostic("manifest.digest_mismatch", Manifest::FILE_NAME,
                                    "manifest digest does not match trusted catalog or installed lock")
        end
        if @expected_name && manifest.data.fetch("name") != @expected_name
          diagnostics << diagnostic("manifest.name_mismatch", Manifest::FILE_NAME,
                                    "manifest name does not match the requested package")
        end

        actual = Manifest.inventory(@root)
        expected = manifest.data.fetch("files")
        compare_inventory(expected, actual, diagnostics)
        descriptor_path = File.join(@root, manifest.data.fetch("descriptor"))
        workflow = parse_workflow(descriptor_path, manifest.data.fetch("name"), diagnostics)
        validate_managed_workflow(workflow, diagnostics) if workflow && @managed
        diagnostics.concat(SecurityScanner.scan_files(
          @root,
          paths: expected.map { |entry| entry.fetch("path") },
          permissions: manifest.data.fetch("permissions")
        ))
        Result.new(manifest: manifest, workflow: workflow, manifest_digest: digest, diagnostics: diagnostics.freeze)
      rescue PackageError => e
        Result.new(manifest: nil, workflow: nil, manifest_digest: nil, diagnostics: [ e.diagnostic ].freeze)
      rescue Hive::ConfigError => e
        Result.new(manifest: nil, workflow: nil, manifest_digest: nil,
                   diagnostics: [ diagnostic("descriptor.invalid", "workflow.yml", safe_descriptor_message(e)) ].freeze)
      end

      private

      def compare_inventory(expected, actual, diagnostics)
        expected_by_path = expected.to_h { |entry| [ entry.fetch("path"), entry ] }
        actual_by_path = actual.to_h { |entry| [ entry.fetch("path"), entry ] }
        (expected_by_path.keys - actual_by_path.keys).sort.each do |path|
          diagnostics << diagnostic("manifest.missing_file", path, "manifest-listed payload file is missing")
        end
        (actual_by_path.keys - expected_by_path.keys).sort.each do |path|
          diagnostics << diagnostic("manifest.unlisted_file", path, "payload file is not listed in the manifest")
        end
        (expected_by_path.keys & actual_by_path.keys).sort.each do |path|
          expected_entry = expected_by_path.fetch(path)
          actual_entry = actual_by_path.fetch(path)
          if expected_entry.fetch("sha256") != actual_entry.fetch("sha256")
            diagnostics << diagnostic("manifest.hash_mismatch", path, "payload hash does not match the manifest")
          end
          if expected_entry.fetch("size") != actual_entry.fetch("size")
            diagnostics << diagnostic("manifest.size_mismatch", path, "payload size does not match the manifest")
          end
        end
      end

      def parse_workflow(path, name, diagnostics)
        Hive::Workflows::DescriptorParser.parse_package_file(path, package_name: name)
      rescue Hive::ConfigError
        diagnostics << diagnostic("descriptor.invalid", File.basename(path), "package workflow descriptor is invalid")
        nil
      end

      def validate_managed_workflow(workflow, diagnostics)
        workflow.stages.each do |stage|
          next unless [ :agent, :council ].include?(stage.kind)

          if stage.permissions.nil? || stage.permissions.to_s == Hive::PermissionScope::YOLO ||
             (stage.permissions.is_a?(Hash) && stage.permissions.fetch("preset", stage.permissions[:preset]).to_s == Hive::PermissionScope::YOLO)
            diagnostics << diagnostic("policy.missing_or_yolo", "workflow.yml",
                                      "every managed active stage must declare a non-yolo permission policy")
          end
          diagnostics << diagnostic("policy.external_skill", "workflow.yml",
                                    "managed workflow stages may not reference mutable external skills") if stage.skill
          next unless stage.kind == :council

          stage.reviewers.each do |reviewer|
            diagnostics << diagnostic("policy.raw_council_command", "workflow.yml",
                                      "managed council reviewers may not execute raw commands") if reviewer.command
            diagnostics << diagnostic("policy.external_skill", "workflow.yml",
                                      "managed council reviewers may not reference mutable external skills") if reviewer.skill
          end
          revise = stage.council&.revise
          diagnostics << diagnostic("policy.raw_council_command", "workflow.yml",
                                    "managed council revise agents may not execute raw commands") if revise&.command
          diagnostics << diagnostic("policy.external_skill", "workflow.yml",
                                    "managed council revise agents may not reference mutable external skills") if revise&.skill
        end
      end

      def diagnostic(rule, path, message)
        Diagnostic.new(rule_id: rule, severity: :error, path: path, message: message)
      end

      def safe_descriptor_message(_error)
        "package workflow descriptor is invalid"
      end

      def secure_equal?(left, right)
        return false unless left.bytesize == right.bytesize

        left.bytes.zip(right.bytes).reduce(0) { |memo, (a, b)| memo | (a ^ b) }.zero?
      end
    end
  end
end
