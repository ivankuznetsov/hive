require "test_helper"
require "hive/refactor_patrol/repository_ownership"

class RefactorPatrolRepositoryOwnershipTest < Minitest::Test
  include HiveTestHelper

  def test_unique_enabled_registration_gets_full_authority
    with_tmp_dir do |dir|
      target = entry("demo", dir)
      guard = guard_for([ target ], identities: { dir => identity("Acme/Demo", "GitHub.com") })

      decision = guard.call(
        entry: target, cfg: config(enabled: true),
        expected_identity: identity("acme/demo", "github.com")
      )

      assert decision.full?
      assert_nil decision.reason
    end
  end

  def test_duplicate_enabled_repository_registration_blocks
    with_tmp_dir do |root|
      entries = [ entry("one", File.join(root, "one")), entry("two", File.join(root, "two")) ]
      identities = entries.to_h do |item|
        [ item.fetch("path"), identity("acme/demo", "github.com") ]
      end

      decision = guard_for(entries, identities: identities).call(
        entry: entries.first, cfg: config(enabled: true)
      )

      assert decision.blocked?
      assert_equal "duplicate_repository_registration", decision.reason
      assert_equal %w[one two], decision.evidence.fetch("registrations").map { |item| item.fetch("name") }
    end
  end

  def test_disabled_registration_does_not_claim_repository_ownership
    with_tmp_dir do |root|
      one = entry("one", File.join(root, "one"))
      two = entry("two", File.join(root, "two"))
      guard = guard_for(
        [ one, two ],
        configs: { two.fetch("path") => config(enabled: false) },
        identities: {
          one.fetch("path") => identity("acme/demo", "github.com"),
          two.fetch("path") => identity("acme/demo", "github.com")
        }
      )

      assert guard.call(entry: one, cfg: config(enabled: true)).full?
    end
  end

  def test_same_repository_slug_on_different_hosts_is_not_duplicate
    with_tmp_dir do |root|
      one = entry("one", File.join(root, "one"))
      two = entry("two", File.join(root, "two"))
      guard = guard_for(
        [ one, two ],
        identities: {
          one.fetch("path") => identity("acme/demo", "github.com"),
          two.fetch("path") => identity("acme/demo", "github.corp.example")
        }
      )

      assert guard.call(entry: one, cfg: config(enabled: true)).full?
    end
  end

  def test_identity_resolution_failure_is_named_and_fails_closed
    with_tmp_dir do |root|
      one = entry("one", File.join(root, "one"))
      two = entry("two", File.join(root, "two"))
      guard = Hive::RefactorPatrol::RepositoryOwnership.new(
        registry: -> { [ one, two ] },
        config_loader: ->(_path) { config(enabled: true) },
        identity_resolver: lambda do |candidate, _cfg|
          raise Hive::GhError, "missing origin" if candidate.fetch("name") == "two"

          identity("acme/demo", "github.com")
        end
      )

      decision = guard.call(entry: one, cfg: config(enabled: true))

      assert decision.blocked?
      assert_equal "repository_identity_unresolved", decision.reason
      assert_includes decision.evidence.dig("unresolved_registrations", 0, "error"), "missing origin"
    end
  end

  def test_snapshot_caches_identity_resolution_but_live_guard_reresolves
    with_tmp_dir do |dir|
      target = entry("demo", dir)
      calls = 0
      guard = Hive::RefactorPatrol::RepositoryOwnership.new(
        registry: -> { [ target ] },
        identity_resolver: lambda do |_candidate, _cfg|
          calls += 1
          identity("acme/demo", "github.com")
        end
      )
      snapshot = guard.snapshot

      2.times { assert snapshot.call(entry: target, cfg: config(enabled: true)).full? }
      assert_equal 1, calls
      assert guard.call(entry: target, cfg: config(enabled: true)).full?
      assert_equal 2, calls
    end
  end

  def test_expected_repository_drift_and_missing_registration_block
    with_tmp_dir do |root|
      registered = entry("demo", File.join(root, "registered"))
      stale = entry("demo", File.join(root, "stale"))
      identities = {
        registered.fetch("path") => identity("acme/new", "github.com"),
        stale.fetch("path") => identity("acme/new", "github.com")
      }
      guard = guard_for([ registered ], identities: identities)

      drift = guard.call(
        entry: registered, cfg: config(enabled: true),
        expected_identity: identity("acme/old", "github.com")
      )
      missing = guard.call(entry: stale, cfg: config(enabled: true))

      assert_equal "repository_identity_drift", drift.reason
      assert_equal "repository_registration_missing", missing.reason
    end
  end

  def test_disabled_or_non_coding_registration_is_blocked
    with_tmp_dir do |dir|
      target = entry("demo", dir)
      guard = guard_for([ target ], identities: { dir => identity("acme/demo", "github.com") })

      disabled = guard.call(entry: target, cfg: config(enabled: false))
      non_coding = guard.call(
        entry: target,
        cfg: config(enabled: true).merge("default_workflow" => "content")
      )

      assert_equal "architecture_patrol_disabled", disabled.reason
      assert_equal "architecture_patrol_disabled", non_coding.reason
    end
  end

  def test_source_identity_requires_an_exact_pull_request_url
    valid = {
      "repository" => "Acme/Demo", "number" => 42,
      "url" => "https://github.example/Acme/Demo/pull/42"
    }
    assert_equal identity("Acme/Demo", "github.example"),
                 Hive::RefactorPatrol::RepositoryOwnership.identity_from_source(valid)

    assert_raises(Hive::GhError) do
      Hive::RefactorPatrol::RepositoryOwnership.identity_from_source(
        valid.merge("url" => "https://github.example/Acme/Demo/pull/43")
      )
    end
  end

  private

  def guard_for(entries, configs: {}, identities:)
    Hive::RefactorPatrol::RepositoryOwnership.new(
      registry: -> { entries },
      config_loader: ->(path) { configs.fetch(path, config(enabled: true)) },
      identity_resolver: ->(candidate, _cfg) { identities.fetch(candidate.fetch("path")) }
    )
  end

  def entry(name, path)
    { "name" => name, "path" => path, "project_id" => "#{name}-project-id" }
  end

  def identity(repository, host)
    { "repository" => repository, "host" => host }
  end

  def config(enabled:)
    {
      "default_workflow" => "coding",
      "daemon" => { "enabled" => true },
      "refactor_patrol" => { "enabled" => enabled }
    }
  end
end
