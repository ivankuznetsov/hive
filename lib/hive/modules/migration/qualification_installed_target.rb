require "digest"
require "fileutils"
require "json"
require "hive/errors"
require "hive/managed_directory"
require "hive/modules/migration/migration_repository"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Reconstructs the descriptor-bound installed candidate tree using only
      # repository snapshots. Modes are normalized by the authority importer:
      # the declared Hive executable is 0700 and every other file is 0600.
      class QualificationInstalledTarget
        ROOT = "inputs/installed-target/".freeze
        MANIFEST = "target.json".freeze
        MANIFEST_SCHEMA =
          "hive-release-candidate-installed-target".freeze
        MANIFEST_KEYS = %w[
          executable gem_sha256 role schema schema_version skills version
        ].freeze
        SKILL_KEYS = %w[archive_sha256 import_root].freeze
        VERSION = /\A[0-9]+(?:\.[0-9A-Za-z]+)*\z/

        Result = Data.define(
          :root, :executable, :package_root, :tree_sha256,
          :manifest
        )

        def materialize(
          files:, destination:, expected_tree_sha256:,
          expected_gem_sha256:, expected_skills_sha256:,
          expected_executable:
        )
          normalized = normalize_files(
            files,
            executable: expected_executable
          )
          manifest = validate_manifest(
            normalized.fetch(MANIFEST).fetch(:bytes),
            expected_gem_sha256: expected_gem_sha256,
            expected_skills_sha256: expected_skills_sha256,
            expected_executable: expected_executable
          )
          digest = tree_digest(normalized)
          malformed! unless
            digest == expected_tree_sha256.to_s
          root = prepare_destination(destination)
          directory = Hive::ManagedDirectory.new(
            root: root,
            anchor: File.dirname(root),
            label: "patrol qualification installed target"
          )
          directory.prepare!
          normalized.keys.sort.each do |relative|
            snapshot = normalized.fetch(relative)
            ensure_parent!(directory, relative)
            directory.atomic_write(
              relative,
              snapshot.fetch(:bytes),
              mode: snapshot.fetch(:mode),
              expected_absent: true
            )
          end
          executable = File.join(
            root,
            manifest.fetch("executable")
          )
          package_root = File.join(
            root,
            "gems",
            "hive-cli-#{manifest.fetch('version')}"
          )
          validate_package_root!(package_root, root)
          Result.new(
            root: root.freeze,
            executable: executable.freeze,
            package_root: package_root.freeze,
            tree_sha256: digest.freeze,
            manifest: manifest
          ).freeze
        rescue Hive::ConfigError
          cleanup_destination(destination)
          raise
        rescue JSON::ParserError, EncodingError, SystemCallError,
               ArgumentError, KeyError, NoMethodError, TypeError
          cleanup_destination(destination)
          malformed!
        end

        private

        def normalize_files(files, executable:)
          malformed! unless
            files.is_a?(Hash) &&
              !files.empty? &&
              files.length <=
                MigrationRepository::MAX_QUALIFICATION_FILES
          executable = safe_relative(executable)
          total = 0
          values = files.to_h do |ref, raw|
            text = ref.to_s
            malformed! unless text.start_with?(ROOT)
            relative = safe_relative(
              text.delete_prefix(ROOT)
            )
            malformed! unless
              raw.is_a?(Hash) &&
                raw.keys.sort == %i[bytes mode]
            bytes = raw.fetch(:bytes)
            mode = Integer(raw.fetch(:mode))
            malformed! unless
              bytes.is_a?(String) &&
                bytes.bytesize <=
                  MigrationRepository::
                    MAX_QUALIFICATION_INPUT_BYTES
            total += bytes.bytesize
            malformed! if
              total >
                MigrationRepository::
                  MAX_QUALIFICATION_TOTAL_BYTES
            expected_mode =
              relative == executable ? 0o700 : 0o600
            malformed! unless mode == expected_mode
            [
              relative.freeze,
              {
                bytes: bytes.b.freeze,
                mode: mode
              }.freeze
            ]
          end
          malformed! unless
            values.key?(executable) &&
              values.key?(MANIFEST)
          values.freeze
        end

        def validate_manifest(
          bytes, expected_gem_sha256:,
          expected_skills_sha256:, expected_executable:
        )
          value = JSON.parse(bytes)
          malformed! unless
            bytes ==
              Hive::WorkflowPackage::CanonicalJSON.generate(
                value
              ) &&
              value.is_a?(Hash) &&
              value.keys.sort == MANIFEST_KEYS &&
              value["schema"] == MANIFEST_SCHEMA &&
              value["schema_version"] == 1 &&
              value["role"] == "candidate" &&
              value["version"].is_a?(String) &&
              value["version"].bytesize <= 128 &&
              VERSION.match?(value["version"]) &&
              value["gem_sha256"] ==
                expected_gem_sha256.to_s &&
              value["executable"] ==
                safe_relative(expected_executable)
          skills = value["skills"]
          malformed! unless
            skills.is_a?(Hash) &&
              skills.keys.sort == SKILL_KEYS &&
              skills["archive_sha256"] ==
                expected_skills_sha256.to_s
          safe_relative(skills["import_root"])
          immutable(value)
        end

        def tree_digest(files)
          digest = Digest::SHA256.new
          digest << "hive-installed-tree-v1\0"
          files.keys.sort.each do |relative|
            snapshot = files.fetch(relative)
            bytes = snapshot.fetch(:bytes)
            digest << relative << "\0"
            digest << snapshot.fetch(:mode).to_s(8) << "\0"
            digest << bytes.bytesize.to_s << "\0"
            digest << Digest::SHA256.hexdigest(bytes) << "\0"
          end
          digest.hexdigest
        end

        def prepare_destination(value)
          path = value.to_s
          malformed! unless
            !path.empty? &&
              !path.include?("\0") &&
              path == File.expand_path(path) &&
              !File.exist?(path) &&
              !File.symlink?(path)
          parent = File.dirname(path)
          stat = File.lstat(parent)
          malformed! unless
            stat.directory? &&
              !stat.symlink? &&
              stat.uid == Process.euid &&
              (stat.mode & 0o077).zero? &&
              File.realpath(parent) == parent
          Dir.mkdir(path, 0o700)
          path
        end

        def ensure_parent!(directory, relative)
          parent = File.dirname(relative)
          directory.ensure_directory(parent) unless parent == "."
        end

        def validate_package_root!(path, root)
          stat = File.lstat(path)
          malformed! unless
            path.start_with?("#{root}/") &&
              stat.directory? &&
              !stat.symlink? &&
              stat.uid == Process.euid &&
              (stat.mode & 0o077).zero? &&
              File.realpath(path) == path
        rescue SystemCallError
          malformed!
        end

        def safe_relative(value)
          text = value.to_s
          malformed! unless
            !text.empty? &&
              text.bytesize <= 4_096 &&
              !text.start_with?("/") &&
              !text.include?("\\") &&
              !text.include?("\0")
          parts = text.split("/", -1)
          malformed! unless
            parts.length <=
              MigrationRepository::MAX_QUALIFICATION_DEPTH &&
              parts.none? do |part|
                part.empty? || part == "." || part == ".."
              end
          text.freeze
        end

        def immutable(value)
          case value
          when Hash
            value.to_h do |key, child|
              [ key.to_s.freeze, immutable(child) ]
            end.freeze
          when Array
            value.map { |child| immutable(child) }.freeze
          when String
            value.dup.freeze
          when Integer, TrueClass, FalseClass, NilClass
            value
          else
            malformed!
          end
        end

        def cleanup_destination(value)
          path = value.to_s
          return if path.empty? ||
                    path == File::SEPARATOR ||
                    !File.exist?(path) &&
                      !File.symlink?(path)

          FileUtils.remove_entry_secure(path, true)
        rescue SystemCallError, ArgumentError
          nil
        end

        def malformed!
          raise Hive::ConfigError,
                "patrol qualification installed target is unsafe"
        end
      end
    end
  end
end
