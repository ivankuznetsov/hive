require "test_helper"
require "digest"
require "json"
require "hive/commands/refactor_patrol"

class HiveCommandsRefactorPatrolManifestTest < Minitest::Test
  include HiveTestHelper

  def test_job_manifest_mode_consumes_published_bytes_without_pr_resolution
    with_tmp_dir do |dir|
      manifest = manifest_for("demo")
      path = publish_manifest(dir, manifest)
      command = Hive::Commands::RefactorPatrol.new(
        "demo", json: true, job_manifest: path,
        manifest_resolver_factory: ->(*) { flunk("scheduled mode must not construct a GitHub resolver") }
      )

      loaded = command.send(
        :resolve_manifest,
        { "name" => "demo", "path" => dir }, dir, { "default_branch" => "main" }
      )

      assert_equal manifest, loaded
    end
  end

  def test_job_manifest_mode_rejects_checksum_tampering
    with_tmp_dir do |dir|
      manifest = manifest_for("demo")
      path = publish_manifest(dir, manifest)
      tampered = manifest.merge("changed_paths" => [ "lib/other.rb" ])
      File.write(path, JSON.generate(tampered))
      command = Hive::Commands::RefactorPatrol.new("demo", json: true, job_manifest: path)

      error = assert_raises(Hive::ConfigError) do
        command.send(
          :resolve_manifest,
          { "name" => "demo", "path" => dir }, dir, { "default_branch" => "main" }
        )
      end
      assert_match(/file scope|checksum/, error.message)
    end
  end

  private

  def manifest_for(registration)
    payload = {
      "schema" => "hive-refactor-patrol-pr-manifest",
      "schema_version" => 2,
      "job_id" => "pr-7-test",
      "source" => {
        "url" => "https://github.com/acme/demo/pull/7",
        "number" => 7,
        "repository" => "acme/demo",
        "registration" => registration,
        "base_branch" => "main",
        "base_sha" => "base",
        "merge_sha" => "merge",
        "merged_at" => "2026-07-10T10:00:00Z"
      },
      "files" => [ { "path" => "lib/demo.rb", "status" => "modified" } ],
      "changed_paths" => [ "lib/demo.rb" ]
    }
    payload.merge("manifest_checksum" => ::Digest::SHA256.hexdigest(canonical_json(payload)))
  end

  def publish_manifest(dir, manifest)
    root = File.join(dir, ".hive-state", "refactor_patrol", "v2", "manifests")
    FileUtils.mkdir_p(root)
    path = File.join(root, "#{manifest.fetch('job_id')}.json")
    File.write(path, JSON.generate(manifest))
    path
  end

  def canonical_json(value)
    normalized = case value
    when Hash
      value.keys.sort.to_h { |key| [ key, JSON.parse(canonical_json(value.fetch(key))) ] }
    when Array
      value.map { |item| JSON.parse(canonical_json(item)) }
    else
      value
    end
    JSON.generate(normalized)
  end
end
