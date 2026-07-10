require "fileutils"

module Hive
  module Honeycomb
    RESERVED_PATHS = %w[workflow.yml README.md manifest.yml].freeze

    Package = Data.define(
      :staging_root,
      :package_root,
      :id,
      :version,
      :metadata,
      :owners,
      :dependencies,
      :permission_summary,
      :manifest
    ) do
      def files
        Dir.glob(File.join(package_root, "**", "*"), File::FNM_DOTMATCH)
           .select { |path| File.file?(path) }
           .map { |path| path.delete_prefix("#{package_root}/") }
           .sort
           .freeze
      end

      def with_manifest(value)
        with(manifest: value)
      end

      def cleanup!
        FileUtils.rm_rf(package_root)
      end
    end
  end
end
