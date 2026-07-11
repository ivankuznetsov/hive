require "test_helper"
require "digest"
require "json"
require "hive/commands/refactor_patrol"

class HiveCommandsRefactorPatrolManifestTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 11, 10, 0, 0)

  def test_heartbeat_ignores_a_claim_that_settled_after_snapshot_and_renews_later_claims
    stale = { job_id: "job-1", canonical_action_id: "fix-a", owner: "runner", generation: 1, kind: :action }
    live = { job_id: "job-1", canonical_action_id: "issue-b", owner: "runner", generation: 1, kind: :action }
    renewed = []
    store = Object.new
    store.define_singleton_method(:renew_action_claim!) do |token, **|
      raise Hive::RefactorPatrol::JobStore::StaleClaim, "settled" if token == stale

      renewed << token
    end
    command = Hive::Commands::RefactorPatrol.new(
      "demo", json: true, job_manifest: "/unused",
      heartbeat_clock: -> { T0 }
    )
    command.instance_variable_set(:@job_store, store)
    command.instance_variable_set(:@manifest, { "job_id" => "job-1" })
    command.define_singleton_method(:active_claim_tokens) { [ stale, live ] }

    command.send(:heartbeat_active_claims)

    assert_equal [ live ], renewed
  end

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
