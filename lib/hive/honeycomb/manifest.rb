require "digest"
require "yaml"
require "hive/deny_patterns"
require "hive/honeycomb"
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
        File.binwrite(File.join(package_root, Hive::Honeycomb::MANIFEST_FILENAME), YAML.dump(manifest))
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
          "external_dependencies" => Hive::Honeycomb.sort_dependencies(dependencies).freeze,
          "permissions" => permission_summary,
          "review_required" => Hive::Honeycomb.sort_review_required(review_required).freeze
        }.freeze
      end

      def package_files(package_root)
        Hive::Honeycomb.package_relative_files(package_root)
           .reject { |relative| relative == Hive::Honeycomb::MANIFEST_FILENAME }
           .map do |relative|
             {
               "path" => relative,
               "sha256" => ::Digest::SHA256.file(File.join(package_root, relative)).hexdigest
             }.freeze
           end
           .freeze
      end

      def aggregate_digest(files)
        tuples = files.map { |row| "#{row.fetch('path')}\0#{row.fetch('sha256')}\n" }.join
        ::Digest::SHA256.hexdigest(tuples)
      end
    end
  end
end
