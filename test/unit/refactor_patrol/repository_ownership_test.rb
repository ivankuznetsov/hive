require "test_helper"
require "hive/refactor_patrol/repository_ownership"

class RefactorPatrolRepositoryOwnershipTest < Minitest::Test
  include HiveTestHelper

  def test_unique_enabled_registration_gets_full_authority
    with_tmp_dir do |dir|
      guard = guard_for(
        [ entry("demo", dir) ],
        identities: { dir => identity("Acme/Demo", "GitHub.com") }
      )

      decision = guard.call(
        entry: entry("demo", dir), cfg: config(enabled: true),
        expected_identity: identity("acme/demo", "github.com")
      )

      assert decision.full?
      assert_nil decision.reason
    end
  end

  def test_daemon_disabled_but_refactor_enabled_registration_still_conflicts
    with_tmp_dir do |root|
      one = File.join(root, "one")
      two = File.join(root, "two")
      entries = [ entry("one", one), entry("two", two) ]
      guard = guard_for(
        entries,
        configs: { two => config(enabled: true, daemon: false) },
        identities: {
          one => identity("acme/demo", "github.com"),
          two => identity("ACME/DEMO", "GITHUB.COM")
        }
      )

      decision = guard.call(entry: entries.first, cfg: config(enabled: true))

      assert decision.blocked?
      assert_equal "duplicate_repository_registration", decision.reason
      assert_equal %w[one two], decision.evidence.fetch("registrations").map { |item| item.fetch("name") }
    end
  end

  def test_disabled_duplicate_is_ignored_and_not_resolved
    with_tmp_dir do |root|
      one = File.join(root, "one")
      two = File.join(root, "two")
      resolved = []
      entries = [ entry("one", one), entry("two", two) ]
      guard = Hive::RefactorPatrol::RepositoryOwnership.new(
        registry: -> { entries },
        config_loader: ->(_path) { config(enabled: false) },
        identity_resolver: lambda do |candidate, _cfg|
          resolved << candidate.fetch("name")
          identity("acme/demo", "github.com")
        end
      )

      decision = guard.call(entry: entries.first, cfg: config(enabled: true))

      assert decision.full?
      assert_equal [ "one" ], resolved
    end
  end

  def test_same_slug_on_different_hosts_is_not_duplicate
    with_tmp_dir do |root|
      one = File.join(root, "one")
      two = File.join(root, "two")
      entries = [ entry("one", one), entry("two", two) ]
      guard = guard_for(
        entries,
        identities: {
          one => identity("acme/demo", "github.com"),
          two => identity("acme/demo", "github.corp.example")
        }
      )

      assert guard.call(entry: entries.first, cfg: config(enabled: true)).full?
    end
  end

  def test_enabled_identity_failure_blocks_with_named_evidence
    with_tmp_dir do |root|
      one = File.join(root, "one")
      two = File.join(root, "two")
      entries = [ entry("one", one), entry("two", two) ]
      guard = Hive::RefactorPatrol::RepositoryOwnership.new(
        registry: -> { entries },
        config_loader: ->(_path) { config(enabled: true) },
        identity_resolver: lambda do |candidate, _cfg|
          raise Hive::GhError, "missing origin" if candidate.fetch("name") == "two"

          identity("acme/demo", "github.com")
        end
      )

      decision = guard.call(entry: entries.first, cfg: config(enabled: true))

      assert decision.blocked?
      assert_equal "repository_identity_unresolved", decision.reason
      unresolved = decision.evidence.fetch("unresolved_registrations")
      assert_equal [ "two" ], unresolved.map { |item| item.fetch("name") }
      assert_includes unresolved.first.fetch("error"), "missing origin"
    end
  end

  def test_each_call_reresolves_changed_origins
    with_tmp_dir do |root|
      one = File.join(root, "one")
      two = File.join(root, "two")
      entries = [ entry("one", one), entry("two", two) ]
      identities = {
        one => identity("acme/one", "github.com"),
        two => identity("acme/two", "github.com")
      }
      guard = guard_for(entries, identities: identities)

      assert guard.call(entry: entries.first, cfg: config(enabled: true)).full?
      identities[two] = identity("acme/one", "github.com")
      decision = guard.call(entry: entries.first, cfg: config(enabled: true))

      assert decision.blocked?
      assert_equal "duplicate_repository_registration", decision.reason
    end
  end

  def test_tick_snapshot_caches_identity_failure_and_replays_it_fail_closed
    with_tmp_dir do |dir|
      target = entry("demo", dir)
      identity_calls = 0
      guard = Hive::RefactorPatrol::RepositoryOwnership.new(
        registry: -> { [ target ] },
        identity_resolver: lambda do |_candidate, _cfg|
          identity_calls += 1
          raise Hive::GhError, "origin unavailable"
        end,
        continuation_resolver: ->(*) { [] }
      ).snapshot

      2.times do
        decision = guard.call(entry: target, cfg: config(enabled: true))
        assert decision.blocked?
        assert_equal "repository_identity_unresolved", decision.reason
        assert_includes decision.evidence.dig("unresolved_registrations", 0, "error"),
                        "origin unavailable"
      end
      assert_equal 1, identity_calls
    end
  end

  def test_drift_grants_only_explicit_continuation_and_duplicates_still_block
    with_tmp_dir do |root|
      one = File.join(root, "one")
      two = File.join(root, "two")
      entries = [ entry("one", one), entry("two", two) ]
      identities = {
        one => identity("acme/new", "github.com"),
        two => identity("acme/other", "github.com")
      }
      guard = guard_for(entries, identities: identities)
      expected = identity("acme/old", "github.com")

      blocked = guard.call(
        entry: entries.first, cfg: config(enabled: true), expected_identity: expected
      )
      continued = guard.call(
        entry: entries.first, cfg: config(enabled: true),
        expected_identity: expected, continuation: true
      )

      assert blocked.blocked?
      assert_equal "repository_identity_drift", blocked.reason
      assert continued.continuation_only?

      identities[two] = identity("acme/new", "github.com")
      duplicate = guard.call(
        entry: entries.first, cfg: config(enabled: true),
        expected_identity: expected, continuation: true
      )
      assert duplicate.blocked?
      assert_equal "duplicate_repository_registration", duplicate.reason
    end
  end

  def test_disabled_registration_with_remote_intent_blocks_a_new_enabled_owner
    with_tmp_dir do |root|
      old_path = File.join(root, "old")
      new_path = File.join(root, "new")
      entries = [ entry("old", old_path), entry("new", new_path) ]
      configs = {
        old_path => config(enabled: false),
        new_path => config(enabled: true)
      }
      guard = Hive::RefactorPatrol::RepositoryOwnership.new(
        registry: -> { entries }, config_loader: ->(path) { configs.fetch(path) },
        identity_resolver: ->(_candidate, _cfg) { identity("acme/demo", "github.com") },
        continuation_resolver: lambda do |candidate, _cfg|
          candidate.fetch("name") == "old" ? [ identity("acme/demo", "github.com") ] : []
        end
      )

      decision = guard.call(entry: entries.last, cfg: configs.fetch(new_path))

      assert decision.blocked?
      assert_equal "duplicate_repository_registration", decision.reason
      assert_equal %w[new old], decision.evidence.fetch("registrations").map { |item| item.fetch("name") }
    end
  end

  def test_drifted_continuation_counts_against_enabled_owner_of_source_repository
    with_tmp_dir do |root|
      moved_path = File.join(root, "moved")
      source_path = File.join(root, "source")
      entries = [ entry("moved", moved_path), entry("source", source_path) ]
      identities = {
        moved_path => identity("acme/new", "github.com"),
        source_path => identity("acme/old", "github.com")
      }
      guard = Hive::RefactorPatrol::RepositoryOwnership.new(
        registry: -> { entries },
        config_loader: ->(_path) { config(enabled: true) },
        identity_resolver: ->(candidate, _cfg) { identities.fetch(candidate.fetch("path")) },
        continuation_resolver: lambda do |candidate, _cfg|
          candidate.fetch("name") == "moved" ? [ identity("acme/old", "github.com") ] : []
        end
      )

      decision = guard.call(
        entry: entries.first, cfg: config(enabled: true),
        expected_identity: identity("acme/old", "github.com"),
        continuation: true, continuation_owner: true
      )

      assert decision.blocked?
      assert_equal "duplicate_repository_registration", decision.reason

      reciprocal = guard.call(
        entry: entries.last, cfg: config(enabled: true),
        expected_identity: identity("acme/old", "github.com")
      )
      assert reciprocal.blocked?
      assert_equal "duplicate_repository_registration", reciprocal.reason
    end
  end

  def test_missing_exact_registration_never_retains_authority
    with_tmp_dir do |root|
      stale = entry("demo", File.join(root, "stale"))
      replacement = entry("demo", File.join(root, "replacement"))
      guard = guard_for(
        [ replacement ],
        identities: {
          stale.fetch("path") => identity("acme/demo", "github.com"),
          replacement.fetch("path") => identity("acme/demo", "github.com")
        }
      )

      full = guard.call(entry: stale, cfg: config(enabled: true))
      continued = guard.call(
        entry: stale, cfg: config(enabled: true), continuation: true,
        expected_identity: identity("acme/demo", "github.com")
      )

      assert full.blocked?
      assert continued.blocked?
      assert_equal "repository_registration_missing", full.reason
      assert_equal "repository_registration_missing", continued.reason
    end
  end

  def test_hostless_identity_fails_closed
    with_tmp_dir do |dir|
      guard = Hive::RefactorPatrol::RepositoryOwnership.new(
        registry: -> { [ entry("demo", dir) ] },
        config_loader: ->(_path) { config(enabled: true) },
        identity_resolver: ->(_candidate, _cfg) { "acme/demo" }
      )

      decision = guard.call(entry: entry("demo", dir), cfg: config(enabled: true))

      assert decision.blocked?
      assert_equal "repository_identity_unresolved", decision.reason
    end
  end

  def test_continuation_evidence_distinguishes_local_and_remote_progress
    aggregate = continuation_aggregate(
      "owner_job_id" => "other-job",
      "receipts" => {}
    )
    assert Hive::RefactorPatrol::RepositoryOwnership.continuation_evidence?(aggregate)
    refute Hive::RefactorPatrol::RepositoryOwnership.remote_continuation_evidence?(aggregate)

    namespaced = continuation_aggregate(
      "receipts" => {
        "publication_attempts" => {
          "a" * 64 => { "descriptor" => { "attempt_id" => "a" * 64 } }
        }
      }
    )
    refute Hive::RefactorPatrol::RepositoryOwnership.continuation_evidence?(namespaced)
    refute Hive::RefactorPatrol::RepositoryOwnership.remote_continuation_evidence?(namespaced)
    namespaced.dig("actions", 0, "receipts", "publication_attempts", "a" * 64)[
      "push_intent"
    ] = { "operation" => "push_branch" }
    assert Hive::RefactorPatrol::RepositoryOwnership.continuation_evidence?(namespaced)
    assert Hive::RefactorPatrol::RepositoryOwnership.remote_continuation_evidence?(namespaced)

    aggregate.dig("actions", 0, "receipts")["creation_intent"] = { "phase" => "intent" }
    assert Hive::RefactorPatrol::RepositoryOwnership.remote_continuation_evidence?(aggregate)

    aggregate["actions"][0]["terminal"] = true
    refute Hive::RefactorPatrol::RepositoryOwnership.continuation_evidence?(aggregate)
    refute Hive::RefactorPatrol::RepositoryOwnership.remote_continuation_evidence?(aggregate)
  end

  def test_source_identity_requires_an_exact_matching_pull_request_url
    valid = {
      "repository" => "Acme/Demo", "number" => 42,
      "url" => "https://github.example/Acme/Demo/pull/42"
    }
    assert_equal identity("Acme/Demo", "github.example"),
                 Hive::RefactorPatrol::RepositoryOwnership.identity_from_source(valid)

    [
      valid.merge("url" => "ssh://github.example/Acme/Demo/pull/42"),
      valid.merge("url" => "https://user@github.example/Acme/Demo/pull/42"),
      valid.merge("url" => "https://github.example/Acme/Demo/pull/43"),
      valid.merge("url" => "https://github.example/Other/Demo/pull/42")
    ].each do |invalid|
      assert_raises(Hive::GhError) do
        Hive::RefactorPatrol::RepositoryOwnership.identity_from_source(invalid)
      end
    end
    assert_raises(Hive::GhError) do
      Hive::RefactorPatrol::RepositoryOwnership.identity_from_source("repository" => "acme/demo")
    end
  end

  def test_disabled_registration_grants_only_requested_continuation
    with_tmp_dir do |dir|
      guard = guard_for(
        [ entry("demo", dir) ], identities: { dir => identity("acme/demo", "github.com") }
      )

      decision = guard.call(entry: entry("demo", dir), cfg: config(enabled: false), continuation: true)

      assert decision.continuation_only?
      assert_equal "architecture_patrol_disabled", decision.reason

      blocked = guard.call(entry: entry("demo", dir), cfg: config(enabled: false))
      assert blocked.blocked?
      assert_equal "architecture_patrol_disabled", blocked.reason
    end
  end

  def test_unexpected_authority_evaluation_failure_is_reported
    with_tmp_dir do |dir|
      target = entry("demo", dir)
      calls = 0
      unstable_config = Object.new
      unstable_config.define_singleton_method(:dig) do |*|
        calls += 1
        raise IOError, "configuration changed" if calls > 1

        true
      end
      guard = Hive::RefactorPatrol::RepositoryOwnership.new(
        registry: -> { [ target ] },
        identity_resolver: ->(_entry, _cfg) { { "repository" => "acme/demo", "host" => "github.com" } },
        continuation_resolver: ->(*) { [] }
      )

      decision = guard.call(entry: target, cfg: unstable_config)

      assert_equal "repository_identity_unresolved", decision.reason
      assert_includes decision.evidence.dig("unresolved_registrations", 0, "error"), "configuration changed"
    end
  end

  def test_stored_continuations_are_derived_from_remote_action_receipts
    with_tmp_dir do |dir|
      target = entry("demo", dir)
      aggregate = continuation_aggregate(
        "receipts" => { "issue_url" => "https://github.com/acme/demo/issues/9" }
      ).merge(
        "source" => {
          "repository" => "acme/demo", "number" => 42,
          "url" => "https://github.com/acme/demo/pull/42"
        }
      )
      fake_store = Object.new
      fake_store.define_singleton_method(:each_job) { [ aggregate ] }
      captured_project = nil
      replacement = lambda do |_path, project:, **_options|
        captured_project = project
        fake_store
      end

      with_replaced_singleton_method(Hive::RefactorPatrol::JobStore, :new, replacement) do
        guard = Hive::RefactorPatrol::RepositoryOwnership.new(
          registry: -> { [] }, identity_resolver: ->(*) { identity("acme/demo", "github.com") }
        )
        assert_equal [ identity("acme/demo", "github.com") ],
                     guard.send(:stored_continuation_identities, target, config(enabled: false))
        assert_equal target.fetch("project_id"), captured_project.fetch("project_id")
      end
    end
  end

  def test_registry_and_config_errors_are_named_and_fail_closed
    with_tmp_dir do |dir|
      target = entry("demo", dir)
      registry_failure = Hive::RefactorPatrol::RepositoryOwnership.new(
        registry: -> { raise IOError, "registry unavailable" }
      )
      decision = registry_failure.call(entry: target, cfg: config(enabled: true))
      assert decision.blocked?
      assert_includes decision.evidence.dig("unresolved_registrations", 0, "error"), "registry unavailable"

      other = entry("other", File.join(dir, "other"))
      config_failure = Hive::RefactorPatrol::RepositoryOwnership.new(
        registry: -> { [ target, other ] },
        config_loader: ->(_path) { raise IOError, "config unavailable" },
        identity_resolver: ->(_entry, _cfg) { identity("acme/demo", "github.com") }
      )
      decision = config_failure.call(entry: target, cfg: config(enabled: true))
      assert_equal "repository_identity_unresolved", decision.reason
      assert_equal [ "other" ], decision.evidence.fetch("unresolved_registrations").map { |item| item.fetch("name") }
    end
  end

  def test_continuation_resolution_errors_fail_closed
    with_tmp_dir do |dir|
      target = entry("demo", dir)
      guard = Hive::RefactorPatrol::RepositoryOwnership.new(
        registry: -> { [ target ] },
        identity_resolver: ->(_entry, _cfg) { identity("acme/demo", "github.com") },
        continuation_resolver: ->(_entry, _cfg) { raise IOError, "job store unavailable" }
      )

      decision = guard.call(entry: target, cfg: config(enabled: true))

      assert_equal "repository_identity_unresolved", decision.reason
      assert_includes decision.evidence.dig("unresolved_registrations", 0, "error"), "job store unavailable"
    end
  end

  def test_invalid_identity_shapes_fail_closed
    with_tmp_dir do |dir|
      [
        identity("one-segment", "github.com"),
        identity("../acme/demo", "github.com"),
        identity("acme/demo", "[")
      ].each do |invalid|
        guard = Hive::RefactorPatrol::RepositoryOwnership.new(
          registry: -> { [ entry("demo", dir) ] },
          identity_resolver: ->(_entry, _cfg) { invalid }
        )
        decision = guard.call(entry: entry("demo", dir), cfg: config(enabled: true))
        assert_equal "repository_identity_unresolved", decision.reason
      end
    end
  end

  def test_default_dependencies_resolve_registration_config_and_repository_identity
    with_tmp_dir do |dir|
      test = self
      target = entry("demo", dir)
      other_path = File.join(dir, "disabled")
      other = entry("disabled", other_path)
      enabled_config = config(enabled: true)
      disabled_config = config(enabled: false)
      resolved_identity = identity("acme/demo", "github.com")
      registered = -> { [ target, other ] }
      loader = ->(path) { test.assert_equal other_path, path; disabled_config }
      resolver = lambda do |path, cfg:|
        test.assert_equal dir, path
        test.assert cfg.dig("refactor_patrol", "enabled")
        resolved_identity
      end
      with_replaced_singleton_method(Hive::Config, :registered_projects, registered) do
        with_replaced_singleton_method(Hive::Config, :load, loader) do
          with_replaced_singleton_method(Hive::Gh, :repository_identity, resolver) do
            guard = Hive::RefactorPatrol::RepositoryOwnership.new(continuation_resolver: ->(*) { [] })
            assert guard.call(entry: target, cfg: enabled_config).full?
          end
        end
      end
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
    {
      "name" => name,
      "path" => path,
      "project_id" => "#{name}-project-id"
    }
  end

  def identity(repository, host)
    { "repository" => repository, "host" => host }
  end

  def config(enabled:, daemon: true)
    {
      "daemon" => { "enabled" => daemon },
      "refactor_patrol" => { "enabled" => enabled }
    }
  end

  def continuation_aggregate(action)
    {
      "job_id" => "job-1",
      "actions" => [
        {
          "terminal" => false,
          "owner_job_id" => "job-1",
          "receipts" => {}
        }.merge(action)
      ]
    }
  end
end
