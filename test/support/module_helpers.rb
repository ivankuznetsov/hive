require "digest"
require "hive/module_package/catalog_client"
require "hive/module_package/validator"
require "hive/workflow_package/canonical_yaml"

module HiveModuleTestHelper
  def write_module_package(root, name: "demo", version: "1.0.0", commit: "a" * 40,
                           hooks: nil, settings: nil, permissions: nil)
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "README.md"), "# #{name}\n")
    hooks ||= [
      {
        "id" => "schedule", "target" => { "kind" => "entrypoint", "id" => "#{name}.run" },
        "default_enabled" => false, "schedules" => [ "0 * * * *" ], "events" => [],
        "concurrency" => "drop"
      }
    ]
    settings ||= [
      { "name" => "mode", "type" => "enum", "required" => true, "default" => "safe", "values" => %w[safe fast] },
      { "name" => "api_token", "type" => "secret", "required" => false, "secret" => true }
    ]
    permissions ||= {
      "repository_write" => false, "github_mutations" => [], "external_commands" => [],
      "network_hosts" => [], "filesystem_read" => [ "repository" ],
      "filesystem_write" => [], "secrets" => []
    }
    data = {
      "schema" => "hive-module/v1", "name" => name, "version" => version,
      "description" => "#{name} module", "type" => "patrol",
      "author" => { "name" => "Hive", "url" => "https://hivecli.sh" }, "license" => "MIT",
      "hive_min_version" => "0.6.7", "source" => { "url" => "https://example.test/#{name}", "revision" => commit },
      "workflows" => [], "hooks" => hooks, "settings" => settings, "permissions" => permissions,
      "templates" => [], "docs" => [ "README.md" ],
      "files" => { "README.md" => ::Digest::SHA256.file(File.join(root, "README.md")).hexdigest }
    }
    data["release_sha256"] = ::Digest::SHA256.hexdigest(Hive::WorkflowPackage::CanonicalYAML.dump(data))
    File.binwrite(File.join(root, "module.yml"), Hive::WorkflowPackage::CanonicalYAML.dump(data))
    result = Hive::ModulePackage::Validator.validate!(root, catalog_commit: commit)
    resolution = Hive::ModulePackage::CatalogClient::Resolution.new(
      name: name, version: version, type: "patrol", source_commit: commit, catalog_commit: commit,
      source_revision: commit, manifest_digest: data.fetch("release_sha256"), summary: "#{name} module",
      package_path: "modules/#{name}/#{version}", descriptor: result.descriptor
    )
    [ resolution, result.descriptor ]
  end

  def exact_grants(descriptor)
    Marshal.load(Marshal.dump(descriptor.permissions))
  end
end
