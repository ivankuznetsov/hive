require "digest"
require "yaml"
require "hive/deny_patterns"
require "hive/secret_patterns"

module Hive
  module Honeycomb
    module Manifest
      VERSION = 1

      module_function

      def write(package_root:, id:, metadata:, dependencies:, permission_summary:, review_required:)
        manifest = build(
          package_root: package_root,
          id: id,
          metadata: metadata,
          dependencies: dependencies,
          permission_summary: permission_summary,
          review_required: review_required
        )
        File.binwrite(File.join(package_root, "manifest.yml"), YAML.dump(manifest))
        manifest
      end

      def build(package_root:, id:, metadata:, dependencies:, permission_summary:, review_required:)
        files = package_files(package_root)
        {
          "manifest_version" => VERSION,
          "honeycomb" => {
            "id" => id.to_s,
            "version" => metadata.fetch("version"),
            "author" => metadata.fetch("author"),
            "description" => metadata.fetch("description"),
            "minimum_hive_version" => metadata.fetch("minimum_hive_version")
          }.freeze,
          "rule_sets" => {
            "secrets" => Hive::SecretPatterns::RULE_SET_VERSION,
            "deny" => Hive::DenyPatterns::RULE_SET_VERSION
          }.freeze,
          "files" => files,
          "aggregate_sha256" => aggregate_digest(files),
          "external_dependencies" => dependencies.sort_by do |row|
            [ row.fetch("context"), row.fetch("skill"), row.fetch("agent") ]
          end.freeze,
          "permissions" => permission_summary,
          "review_required" => review_required.sort_by do |row|
            [ row.fetch("file"), row.fetch("line"), row.fetch("rule") ]
          end.freeze
        }.freeze
      end

      def package_files(package_root)
        Dir.glob(File.join(package_root, "**", "*"), File::FNM_DOTMATCH)
           .select { |path| File.file?(path) }
           .map do |path|
             relative = path.delete_prefix("#{package_root}/")
             { "path" => relative, "sha256" => Digest::SHA256.file(path).hexdigest }.freeze
           end
           .reject { |row| row.fetch("path") == "manifest.yml" }
           .sort_by { |row| row.fetch("path") }
           .freeze
      end

      def aggregate_digest(files)
        tuples = files.map { |row| "#{row.fetch('path')}\0#{row.fetch('sha256')}\n" }.join
        Digest::SHA256.hexdigest(tuples)
      end
    end
  end
end
