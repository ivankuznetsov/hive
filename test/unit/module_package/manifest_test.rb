require "digest"
require "test_helper"
require "hive/module_package/manifest"
require "hive/workflow_package/canonical_yaml"

class ModulePackageManifestTest < Minitest::Test
  include HiveTestHelper

  def test_loads_a_canonical_rich_module_manifest
    with_module_package do |root, document|
      manifest = Hive::ModulePackage::Manifest.load(File.join(root, "module.yml"))

      assert_equal "patrol", manifest.name
      assert_equal "1.0.0", manifest.version
      assert_equal %w[project.registered task.completed], manifest.event_names
      assert_equal %w[scheduled-scan setup task-completed], manifest.hooks.map { |hook| hook.fetch("id") }
      assert_equal document.fetch("release_sha256"), manifest.digest
      assert_equal Hive::WorkflowPackage::CanonicalYAML.dump(document), manifest.bytes
    end
  end

  def test_rejects_unknown_keys_mutable_sources_and_executable_ruby
    with_module_package do |root, document|
      document["future"] = true
      assert_rule("manifest.invalid_shape") { rewrite_manifest(root, document) }
    end

    with_module_package do |root, document|
      document["source"]["revision"] = "main"
      assert_rule("manifest.invalid_source") { rewrite_manifest(root, document) }
    end

    with_module_package do |root, document|
      File.write(File.join(root, "adapter.rb"), "raise 'not declarative'\n")
      document["files"]["adapter.rb"] = Digest::SHA256.file(File.join(root, "adapter.rb")).hexdigest
      document["files"] = document["files"].sort.to_h
      assert_rule("package.executable_ruby") { rewrite_manifest(root, document) }
    end
  end

  def test_rejects_unknown_events_wildcard_bindings_and_duplicate_hook_ids
    with_module_package do |root, document|
      document["hooks"][0]["events"] = [ "*" ]
      assert_rule("manifest.invalid_event") { rewrite_manifest(root, document) }
    end

    with_module_package do |root, document|
      document["hooks"] << Marshal.load(Marshal.dump(document["hooks"].first))
      assert_rule("manifest.duplicate_hook") { rewrite_manifest(root, document) }
    end
  end

  def test_validates_workflow_descriptors_and_rejects_invalid_nested_shapes
    with_module_package do |root, document|
      document["workflows"] = [ { "id" => "review", "descriptor" => "README.md" } ]
      manifest = rewrite_manifest(root, document)
      assert_equal [ { "id" => "review", "descriptor" => "README.md" } ], manifest.workflows
    end

    assert_mutation("manifest.invalid_workflow") { |document| document["workflows"] = [ { "id" => "review" } ] }
    assert_mutation("manifest.invalid_hook") { |document| document["hooks"].first.delete("concurrency") }
    assert_mutation("manifest.invalid_schedule") do |document|
      document["hooks"].first["schedules"] = [ "0 * * * *", "0 * * * *" ]
    end
    assert_mutation("manifest.invalid_target") { |document| document["hooks"].first["target"] = [] }
    assert_mutation("manifest.invalid_target") do |document|
      document["hooks"].first["target"] = { "kind" => "entrypoint", "id" => "INVALID" }
    end
  end

  def test_hook_targets_bind_to_declared_workflows_and_reviewed_command_executables
    with_module_package do |root, document|
      document["workflows"] = [ { "id" => "review", "descriptor" => "README.md" } ]
      document["hooks"].first["target"] = { "kind" => "workflow", "id" => "review" }

      manifest = rewrite_manifest(root, document)

      assert_equal "review", manifest.hooks.first.dig("target", "id")
    end

    assert_mutation("manifest.invalid_target") do |document|
      document["hooks"].first["target"] = { "kind" => "workflow", "id" => "missing" }
    end

    with_module_package do |root, document|
      document["permissions"]["external_commands"] = [ "git" ]
      document["hooks"].first["target"] = { "kind" => "command", "id" => "git status --short" }

      manifest = rewrite_manifest(root, document)

      assert_equal "git status --short", manifest.hooks.first.dig("target", "id")
    end

    assert_mutation("manifest.invalid_target") do |document|
      document["permissions"]["external_commands"] = [ "git" ]
      document["hooks"].first["target"] = { "kind" => "command", "id" => "git 'unterminated" }
    end
    assert_mutation("manifest.permission_mismatch") do |document|
      document["permissions"]["external_commands"] = [ "git" ]
      document["hooks"].first["target"] = { "kind" => "command", "id" => "gh pr create" }
    end
  end

  def test_rejects_each_typed_setting_and_permission_disclosure_violation
    assert_mutation("manifest.invalid_setting") { |document| document["settings"].first.delete("required") }
    assert_mutation("manifest.invalid_setting") { |document| document["settings"].first["secret"] = "yes" }
    assert_mutation("manifest.invalid_setting") do |document|
      document["settings"].first["values"] = %w[low low]
    end
    assert_mutation("manifest.invalid_setting") { |document| document["settings"].first["default"] = "missing" }
    assert_mutation("manifest.invalid_setting") do |document|
      document["settings"].last["values"] = [ "unsupported" ]
    end
    assert_mutation("manifest.invalid_permissions") { |document| document["permissions"].delete("secrets") }
    assert_mutation("manifest.invalid_permissions") { |document| document["permissions"]["repository_write"] = "yes" }
    assert_mutation("manifest.invalid_permissions") do |document|
      document["permissions"]["network_hosts"] = [ "github.com", "github.com" ]
    end
    assert_mutation("manifest.invalid_permissions") do |document|
      document["permissions"]["network_hosts"] = [ "*", "github.com" ]
    end
  end

  def test_rejects_invalid_inventory_references_and_urls
    assert_mutation("manifest.invalid_files") do |document|
      document["files"] = { "z.txt" => "a" * 64, "README.md" => document["files"].fetch("README.md") }
    end
    assert_mutation("manifest.self_hash") { |document| document["files"]["module.yml"] = "a" * 64 }
    assert_mutation("manifest.invalid_value") { |document| document["templates"] = [ "README.md", "README.md" ] }
    assert_mutation("manifest.invalid_author") { |document| document["author"] = { "name" => "Hive" } }
    assert_mutation("manifest.invalid_source") { |document| document["source"] = { "url" => "https://example.test" } }
    assert_mutation("manifest.invalid_url") { |document| document["author"]["url"] = "mailto:hive@example.test" }
    assert_mutation("manifest.invalid_url") { |document| document["author"]["url"] = "http://[" }
  end

  def test_reports_digest_yaml_and_read_failures_with_typed_diagnostics
    with_module_package do |root, document|
      document["description"] = "Changed without rebinding the digest"
      File.binwrite(File.join(root, "module.yml"), Hive::WorkflowPackage::CanonicalYAML.dump(document))
      assert_rule("manifest.release_digest_mismatch") do
        Hive::ModulePackage::Manifest.load(File.join(root, "module.yml"))
      end
    end

    with_tmp_dir do |root|
      path = File.join(root, "module.yml")
      File.binwrite(path, "--- !ruby/object:Object {}\n")
      assert_rule("manifest.invalid_yaml") { Hive::ModulePackage::Manifest.load(path) }
      FileUtils.rm_f(path)
      assert_rule("manifest.unreadable") { Hive::ModulePackage::Manifest.load(path) }
    end
  end

  private

  def assert_rule(expected)
    error = assert_raises(Hive::WorkflowPackage::PackageError) { yield }
    assert_equal expected, error.diagnostic.rule_id
  end

  def assert_mutation(expected)
    with_module_package do |root, document|
      yield document
      assert_rule(expected) { rewrite_manifest(root, document) }
    end
  end

  def with_module_package
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, "docs"))
      File.write(File.join(root, "README.md"), "# Patrol module\n")
      File.write(File.join(root, "docs", "operator.md"), "Operator notes.\n")
      document = base_document(root)
      File.binwrite(File.join(root, "module.yml"), Hive::WorkflowPackage::CanonicalYAML.dump(document))
      yield root, document
    end
  end

  def base_document(root)
    files = %w[README.md docs/operator.md].to_h do |path|
      [ path, Digest::SHA256.file(File.join(root, path)).hexdigest ]
    end
    document = {
      "schema" => "hive-module/v1",
      "name" => "patrol",
      "version" => "1.0.0",
      "description" => "First-party ordinary patrol",
      "type" => "patrol",
      "author" => { "name" => "Hive", "url" => "https://hivecli.sh" },
      "license" => "MIT",
      "hive_min_version" => "0.6.7",
      "source" => { "url" => "https://github.com/ivankuznetsov/honeycomb", "revision" => "a" * 40 },
      "workflows" => [],
      "hooks" => [
        {
          "id" => "scheduled-scan", "target" => { "kind" => "entrypoint", "id" => "patrol.scan" },
          "default_enabled" => false, "schedules" => [ "0 */6 * * *" ], "events" => [],
          "concurrency" => "drop"
        },
        {
          "id" => "setup", "target" => { "kind" => "entrypoint", "id" => "patrol.setup" },
          "default_enabled" => false, "schedules" => [], "events" => [ "project.registered" ],
          "concurrency" => "drop"
        },
        {
          "id" => "task-completed", "target" => { "kind" => "entrypoint", "id" => "patrol.task-completed" },
          "default_enabled" => false, "schedules" => [], "events" => [ "task.completed" ],
          "concurrency" => "drop"
        }
      ],
      "settings" => [
        { "name" => "mode", "type" => "enum", "required" => true, "default" => "medium", "values" => %w[low medium high] },
        { "name" => "reviewer", "type" => "string", "required" => false, "secret" => false }
      ],
      "permissions" => {
        "repository_write" => true, "github_mutations" => [ "pull_requests" ],
        "external_commands" => [ "bin/test" ], "network_hosts" => [ "github.com" ],
        "filesystem_read" => [ "repository" ], "filesystem_write" => [ ".hive-state/patrol" ],
        "secrets" => [ "GH_TOKEN" ]
      },
      "templates" => [],
      "docs" => %w[README.md docs/operator.md],
      "files" => files
    }
    document["release_sha256"] = Digest::SHA256.hexdigest(
      Hive::WorkflowPackage::CanonicalYAML.dump(document)
    )
    document
  end

  def rewrite_manifest(root, document)
    document["release_sha256"] = Digest::SHA256.hexdigest(
      Hive::WorkflowPackage::CanonicalYAML.dump(document.reject { |key, _| key == "release_sha256" })
    )
    bytes = Hive::WorkflowPackage::CanonicalYAML.dump(document)
    File.binwrite(File.join(root, "module.yml"), bytes)
    Hive::ModulePackage::Manifest.load(File.join(root, "module.yml"))
  end
end
