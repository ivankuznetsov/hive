require "digest"
require "hive/workflow_package/canonical_json"

module Hive
  module ModulePackage
    Descriptor = Data.define(
      :name, :version, :type, :description, :workflows, :hooks, :settings,
      :permissions, :templates, :docs, :source, :catalog_commit,
      :manifest_digest, :hive_min_version, :files, :legacy_honeycomb
    ) do
      def initialize(**values)
        super(**values.transform_values { |value| Normalizer.deep_freeze(value) })
        freeze
      end

      def to_h
        members.to_h { |member| [ member.to_s, public_send(member) ] }
      end

      def digest
        ::Digest::SHA256.hexdigest(Hive::WorkflowPackage::CanonicalJSON.generate(to_h))
      end
    end

    module Normalizer
      module_function

      def from_manifest(manifest, catalog_commit:)
        data = manifest.data
        Descriptor.new(
          name: manifest.name, version: manifest.version, type: manifest.type,
          description: manifest.summary, workflows: data.fetch("workflows"), hooks: data.fetch("hooks"),
          settings: data.fetch("settings"), permissions: data.fetch("permissions"),
          templates: data.fetch("templates"), docs: data.fetch("docs"), source: data.fetch("source"),
          catalog_commit: catalog_commit, manifest_digest: manifest.digest,
          hive_min_version: data.fetch("hive_min_version"), files: manifest.file_entries,
          legacy_honeycomb: false
        )
      end

      def from_honeycomb(manifest, resolution:)
        data = manifest.data
        permissions = normalize_honeycomb_permissions(manifest.permissions)
        Descriptor.new(
          name: data.fetch("name"), version: data.fetch("version"), type: "workflow",
          description: data.fetch("description", data.fetch("summary", "Managed workflow")),
          workflows: [ { "id" => data.fetch("name"), "descriptor" => manifest.descriptor } ],
          hooks: [], settings: [], permissions: permissions, templates: [], docs: [],
          source: data.fetch("source", { "url" => "legacy:honeycomb", "revision" => resolution.catalog_commit }),
          catalog_commit: resolution.catalog_commit, manifest_digest: manifest.digest,
          hive_min_version: data.fetch("hive_min_version", "0.0.0"), files: normalize_files(manifest),
          legacy_honeycomb: true
        )
      end

      def normalize_honeycomb_permissions(permissions)
        if permissions.key?("risk")
          capabilities = permissions.fetch("capabilities")
          {
            "repository_write" => capabilities.include?("filesystem-write"),
            "github_mutations" => [],
            "external_commands" => capabilities.include?("shell") ? [ "*" ] : [],
            "network_hosts" => permissions.fetch("network_hosts"),
            "filesystem_read" => permissions.fetch("filesystem_read"),
            "filesystem_write" => permissions.fetch("filesystem_write"),
            "secrets" => permissions.fetch("secrets")
          }
        else
          {
            "repository_write" => !permissions.fetch("directories", []).empty?,
            "github_mutations" => [], "external_commands" => permissions.fetch("commands", []),
            "network_hosts" => permissions.fetch("domains", []),
            "filesystem_read" => permissions.fetch("directories", []),
            "filesystem_write" => permissions.fetch("directories", []),
            "secrets" => permissions.fetch("credentials", [])
          }
        end
      end

      def normalize_files(manifest)
        manifest.file_entries.map { |entry| entry.slice("path", "sha256") }
      end

      def deep_freeze(value)
        case value
        when Hash then value.each { |key, child| key.freeze; deep_freeze(child) }.freeze
        when Array then value.each { |child| deep_freeze(child) }.freeze
        else value.freeze
        end
      end
    end
  end
end
