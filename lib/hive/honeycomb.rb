require "fileutils"

module Hive
  module Honeycomb
    MANIFEST_FILENAME = "manifest.yml".freeze
    RESERVED_PATHS = %w[workflow.yml README.md manifest.yml].freeze

    module_function

    # Canonical relative-path enumeration for a built package root. Both the
    # digest listing (Manifest) and the reported file list (Package#files)
    # derive from this so a future ignore-rule change is applied in exactly
    # one place instead of two divergent globs.
    def package_relative_files(package_root)
      Dir.glob(File.join(package_root, "**", "*"), File::FNM_DOTMATCH)
         .select { |path| File.file?(path) }
         .map { |path| path.delete_prefix("#{package_root}/") }
         .sort
         .freeze
    end

    # Canonical ordering for review-required records ([file, line, rule]).
    def sort_review_required(records)
      records.sort_by { |record| [ record.fetch("file"), record.fetch("line"), record.fetch("rule") ] }
    end

    # Canonical ordering for external-dependency rows ([context, skill, agent]).
    def sort_dependencies(rows)
      rows.sort_by { |row| [ row.fetch("context"), row.fetch("skill"), row.fetch("agent") ] }
    end

    Package = Data.define(
      :staging_root,
      :package_root,
      :owns_staging_root,
      :id,
      :version,
      :metadata,
      :owners,
      :dependencies,
      :permission_summary,
      :manifest
    ) do
      def files
        Hive::Honeycomb.package_relative_files(package_root)
      end

      def with_manifest(value)
        with(manifest: value)
      end

      # Removes what the builder created. When the builder minted its own
      # staging directory (no caller-supplied output_dir), the whole staging
      # root is disposable and removed; otherwise only the package subtree is
      # cleaned so a caller-owned output_dir is preserved.
      def cleanup!
        FileUtils.rm_rf(owns_staging_root ? staging_root : package_root)
      end
    end
  end
end
