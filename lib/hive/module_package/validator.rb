require "digest"
require "rubygems/version"
require "hive/module_package/manifest"
require "hive/module_package/normalizer"
require "hive/workflow_package/manifest"

module Hive
  module ModulePackage
    class Validator
      Result = Data.define(:manifest, :descriptor, :manifest_digest, :diagnostics) do
        def valid? = errors.empty?
        def errors = diagnostics.select(&:error?)
        def warnings = diagnostics.select(&:warning?)
      end

      def self.validate(root, expected_name: nil, expected_manifest_digest: nil, catalog_commit: nil)
        new(root, expected_name: expected_name, expected_manifest_digest: expected_manifest_digest,
                  catalog_commit: catalog_commit).validate
      end

      def self.validate!(...)
        result = validate(...)
        raise Hive::WorkflowPackage::PackageError, result.errors.first unless result.valid?
        result
      end

      def initialize(root, expected_name:, expected_manifest_digest:, catalog_commit:)
        @root = File.expand_path(root)
        @expected_name = expected_name&.to_s
        @expected_manifest_digest = expected_manifest_digest&.to_s
        @catalog_commit = catalog_commit&.to_s
      end

      def validate
        diagnostics = []
        manifest = load_manifest
        if @expected_name && manifest.name != @expected_name
          diagnostics << diagnostic("manifest.name_mismatch", manifest.file_name, "manifest name does not match the reviewed catalog entry")
        end
        if @expected_manifest_digest && !secure_equal?(manifest.digest, @expected_manifest_digest)
          diagnostics << diagnostic("manifest.digest_mismatch", manifest.file_name, "manifest digest does not match the reviewed catalog entry")
        end
        if Gem::Version.new(Hive::VERSION.split("+", 2).first) < Gem::Version.new(manifest.data.fetch("hive_min_version").split("+", 2).first)
          diagnostics << diagnostic("manifest.hive_version_unsupported", manifest.file_name, "module requires a newer Hive version")
        end

        actual = Hive::WorkflowPackage::Manifest.inventory(
          @root, exclude: [ Manifest::FILE_NAME, Manifest::ALTERNATE_FILE_NAME ]
        )
        compare_inventory(manifest.file_entries, actual, diagnostics)
        validate_file_modes(manifest, diagnostics)
        descriptor = Normalizer.from_manifest(manifest, catalog_commit: @catalog_commit)
        Result.new(manifest: manifest, descriptor: descriptor, manifest_digest: manifest.digest,
                   diagnostics: diagnostics.freeze)
      rescue Hive::WorkflowPackage::PackageError => e
        Result.new(manifest: nil, descriptor: nil, manifest_digest: nil, diagnostics: [ e.diagnostic ].freeze)
      end

      private

      def load_manifest
        primary = File.join(@root, Manifest::FILE_NAME)
        alternate = File.join(@root, Manifest::ALTERNATE_FILE_NAME)
        if File.exist?(primary) && File.exist?(alternate)
          raise Hive::WorkflowPackage::PackageError.new(
            diagnostic("manifest.ambiguous", Manifest::FILE_NAME, "module package contains two manifests")
          )
        end
        Manifest.load(File.exist?(primary) ? primary : alternate)
      end

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
          next if expected_by_path.fetch(path).fetch("sha256") == actual_by_path.fetch(path).fetch("sha256")
          diagnostics << diagnostic("manifest.hash_mismatch", path, "payload hash does not match the manifest")
        end
      end

      def validate_file_modes(manifest, diagnostics)
        manifest.file_entries.each do |entry|
          path = entry.fetch("path")
          absolute = File.join(@root, path)
          next unless File.file?(absolute)
          mode = File.stat(absolute).mode
          if (mode & 0o111).positive?
            diagnostics << diagnostic("package.executable_file", path, "module payload files must not be executable")
          end
        end
      end

      def secure_equal?(left, right)
        left.bytesize == right.bytesize && left.bytes.zip(right.bytes).reduce(0) { |memo, (a, b)| memo | (a ^ b) }.zero?
      end

      def diagnostic(rule, path, message)
        Hive::WorkflowPackage::Diagnostic.new(rule_id: rule, severity: :error, path: path, message: message)
      end
    end
  end
end
