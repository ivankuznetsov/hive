require "digest"
require "fileutils"
require "pathname"
require "tmpdir"
require "hive/honeycomb/catalog"
require "hive/honeycomb/manifest"
require "hive/honeycomb/security_report"
require "hive/workflows/descriptor_parser"

module Hive
  module Honeycomb
    VerifiedPackage = Data.define(
      :pin, :manifest, :files, :hashes, :modes, :descriptor, :security_report, :staging_dir
    )

    class Package
      REGULAR_BLOB_MODES = %w[100644 100755].freeze

      def initialize(registry:)
        @registry = registry
      end

      def verify(pin, staging_parent:)
        staging_dir = nil
        tree = read_tree(pin)
        manifest_record = tree["manifest.yml"]
        raise IntegrityError, "honeycomb/#{pin.name} package is missing manifest.yml" unless manifest_record

        manifest_raw = read_blob(manifest_record.fetch(:oid))
        manifest = Manifest.load(manifest_raw)
        expected = (manifest.files.keys + [ "manifest.yml" ]).sort
        actual = tree.keys.sort
        unless actual == expected
          missing = expected - actual
          extra = actual - expected
          raise IntegrityError,
                "package inventory differs from tree (missing: #{missing.inspect}; undeclared: #{extra.inspect})"
        end

        files = manifest.files.keys.to_h do |path|
          bytes = read_blob(tree.fetch(path).fetch(:oid))
          actual_hash = ::Digest::SHA256.hexdigest(bytes)
          expected_hash = manifest.files.fetch(path)
          unless actual_hash == expected_hash
            raise IntegrityError, "package file #{path.inspect} hash mismatch"
          end
          [ path, bytes.freeze ]
        end
        if pin.digest && manifest.package_digest != pin.digest
          raise IntegrityError,
                "package digest mismatch for honeycomb/#{pin.name}: expected #{pin.digest}, got #{manifest.package_digest}"
        end

        FileUtils.mkdir_p(staging_parent)
        staging_dir = Dir.mktmpdir(".honeycomb-#{pin.name}-", staging_parent)
        materialize(staging_dir, files, tree)
        descriptor = Hive::Workflows::DescriptorParser.parse_file(
          File.join(staging_dir, "workflow.yml"), expected_id: pin.name
        )
        validate_instruction_inventory!(descriptor, staging_dir, manifest.files)
        report = SecurityReport.build(workflow: descriptor, package_root: staging_dir)
        report.validate_manifest_summary!(manifest.permissions)

        VerifiedPackage.new(
          pin: pin,
          manifest: manifest,
          files: files.freeze,
          hashes: manifest.files,
          modes: manifest.files.keys.to_h { |path| [ path, tree.fetch(path).fetch(:mode) ] }.freeze,
          descriptor: descriptor,
          security_report: report,
          staging_dir: staging_dir
        )
      rescue StandardError
        FileUtils.rm_rf(staging_dir) if staging_dir
        raise
      end

      private

      def read_tree(pin)
        root = "workflows/#{pin.name}"
        raw = @registry.git_object!("ls-tree", "-rz", "--full-tree", pin.sha, "--", root)
        records = {}
        raw.split("\0", -1).reject(&:empty?).each do |record|
          header, full_path = record.split("\t", 2)
          mode, type, oid = header.to_s.split(" ", 3)
          unless full_path&.start_with?("#{root}/")
            raise IntegrityError, "package tree returned path outside #{root.inspect}: #{full_path.inspect}"
          end
          relative = Manifest.normalize_path(full_path.delete_prefix("#{root}/"))
          if records.key?(relative)
            raise IntegrityError, "package tree contains duplicate normalized path #{relative.inspect}"
          end
          unless type == "blob" && REGULAR_BLOB_MODES.include?(mode) && oid&.match?(/\A[0-9a-f]{40,64}\z/i)
            raise IntegrityError,
                  "package path #{relative.inspect} is not a regular blob (mode=#{mode.inspect}, type=#{type.inspect})"
          end
          records[relative] = { mode: mode, oid: oid.downcase }.freeze
        end
        raise IntegrityError, "honeycomb/#{pin.name} package tree is empty" if records.empty?
        records.freeze
      end

      def read_blob(oid)
        @registry.git_object!("cat-file", "blob", oid).b
      rescue Hive::Error
        raise
      rescue StandardError => e
        raise IntegrityError, "could not read package blob #{oid}: #{e.message}"
      end

      def materialize(staging_dir, files, tree)
        files.each do |path, bytes|
          target = File.join(staging_dir, path)
          FileUtils.mkdir_p(File.dirname(target))
          File.binwrite(target, bytes)
          File.chmod(tree.fetch(path).fetch(:mode) == "100755" ? 0o755 : 0o644, target)
        end
      end

      def validate_instruction_inventory!(workflow, staging_dir, inventory)
        SecurityReport.instruction_paths(workflow).each do |path|
          expanded = File.expand_path(path)
          root_prefix = "#{File.expand_path(staging_dir)}#{File::SEPARATOR}"
          unless expanded.start_with?(root_prefix)
            raise IntegrityError, "descriptor instruction escapes package root: #{path}"
          end
          relative = Pathname.new(expanded).relative_path_from(Pathname.new(staging_dir)).to_s
          unless inventory.key?(relative)
            raise IntegrityError, "descriptor instruction #{relative.inspect} is not inventoried"
          end
          bytes = File.binread(expanded).dup.force_encoding(Encoding::UTF_8)
          raise IntegrityError, "instruction #{relative.inspect} is not valid UTF-8" unless bytes.valid_encoding?
        end
      end
    end
  end
end
