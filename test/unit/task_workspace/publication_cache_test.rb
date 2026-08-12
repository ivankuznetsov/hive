require "test_helper"
require "hive/task_workspace/publication_cache"

class TaskWorkspacePublicationCacheTest < Minitest::Test
  include HiveTestHelper

  def test_refresh_writes_private_identity_scoped_cache_and_plain_read_is_network_free
    with_tmp_dir do |root|
      calls = 0
      now = Time.utc(2026, 8, 12, 12)
      cache = build_cache(root, clock: -> { now })

      refreshed = cache.refresh(identity) do
        calls += 1
        observation
      end
      read = cache.read(identity)

      assert_equal 1, calls
      assert_equal "current", refreshed.fetch("state")
      assert_equal observation.fetch("head_oid"), read.dig("observation", "head_oid")
      assert read.dig("observation", "head_matches")
      paths = Dir.glob(File.join(root, "**", "*.json"))
      assert_equal 1, paths.length
      assert_equal 0o600, File.stat(paths.first).mode & 0o777
      assert_equal 0o700, File.stat(File.dirname(paths.first)).mode & 0o777
      refute_includes File.binread(paths.first), "credential-token"
    end
  end

  def test_fresh_stale_expired_and_failed_refresh_retain_distinct_truth
    with_tmp_dir do |root|
      now = Time.utc(2026, 8, 12, 12)
      cache = build_cache(root, clock: -> { now })
      cache.refresh(identity) { observation }

      now += 121
      assert_equal "stale", cache.read(identity).fetch("state")

      now += 61
      failed = cache.refresh(identity) do
        raise Hive::TaskWorkspace::PublicationCache::RefreshError.new(
          "rate_limited", retry_after: "2026-08-12T13:00:00Z"
        )
      end
      assert_equal "partial", failed.fetch("state")
      assert_equal "stale", failed.fetch("cache_state")
      assert_equal observation.fetch("url"), failed.dig("observation", "url")
      assert_equal "rate_limited", failed.dig("diagnostics", 0, "reason")

      now += 86_401
      expired = cache.read(identity)
      assert_equal "unavailable", expired.fetch("state")
      assert_equal "cache_expired", expired.dig("diagnostics", 0, "reason")
    end
  end

  def test_minimum_interval_and_single_flight_never_call_the_transport
    with_tmp_dir do |root|
      now = Time.utc(2026, 8, 12, 12)
      cache = build_cache(root, clock: -> { now })
      cache.refresh(identity) { observation }
      calls = 0

      limited = cache.refresh(identity) { calls += 1; observation }
      assert_equal "retry-after", limited.fetch("refresh_state")
      assert_equal 0, calls

      now += 61
      lock_path = "#{cache.send(:entry_path, cache.send(:normalize_identity, identity))}.lock"
      held = File.open(lock_path, File::RDWR)
      held.flock(File::LOCK_EX)
      busy = cache.refresh(identity) { calls += 1; observation }
      assert_equal "busy", busy.fetch("refresh_state")
      assert_equal 0, calls
    ensure
      held&.flock(File::LOCK_UN)
      held&.close
    end
  end

  def test_credential_project_pr_and_head_rollovers_cannot_reuse_an_entry
    with_tmp_dir do |root|
      first = build_cache(root)
      first.refresh(identity) { observation }

      another_principal = build_cache(root, credential: "another-token")
      another_project = build_cache(root, project: { "name" => "other" })
      changed_pr = identity.merge("number" => 43)
      changed_head = identity.merge("expected_head" => "b" * 40)

      [ another_principal.read(identity), another_project.read(identity),
        first.read(changed_pr), first.read(changed_head) ].each do |result|
        assert_equal "not_observed", result.dig("diagnostics", 0, "reason")
      end
    end
  end

  def test_normalization_redacts_and_caps_hostile_external_text
    with_tmp_dir do |root|
      limits = Hive::TaskWorkspace::Limits.new(github_checks: 1, github_pr_text_bytes: 80)
      cache = build_cache(root, limits: limits)
      token = "ghp_#{'a' * 36}"
      hostile = observation.merge(
        "title" => "<script>#{token}</script>",
        "body" => "body #{token} " + ("x" * 200),
        "checks" => [
          { "name" => "<img src=x>", "status" => "COMPLETED", "conclusion" => "SUCCESS" },
          { "name" => "second", "status" => "QUEUED" }
        ]
      )

      result = cache.refresh(identity) { hostile }

      serialized = JSON.generate(result)
      refute_includes serialized, token
      assert_equal 1, result.dig("observation", "checks").length
      assert result.dig("observation", "checks_truncated")
      assert_operator result.dig("observation", "title").bytesize +
                      result.dig("observation", "body").bytesize, :<=, 80
    end
  end

  def test_identity_mismatch_and_unsafe_cache_directory_fail_closed
    with_tmp_dir do |root|
      cache = build_cache(root)
      mismatched = cache.refresh(identity) do
        observation.merge("repository" => "github.com/other/repo")
      end
      assert_equal "unavailable", mismatched.fetch("state")
      assert_equal "identity_mismatch", mismatched.dig("diagnostics", 0, "reason")

      hostile_root = File.join(root, "hostile")
      FileUtils.mkdir_p(hostile_root)
      principal = Hive::TaskWorkspace::PublicationCache.principal_id(
        "credential-token", secret: "cache-secret"
      )
      File.symlink(root, File.join(hostile_root, principal))
      unsafe = build_cache(hostile_root).refresh(identity) { flunk "transport must not run" }
      assert_equal "unavailable", unsafe.fetch("state")
      assert_equal "cache_directory_unsafe", unsafe.dig("diagnostics", 0, "reason")
    end
  end

  def test_changed_remote_head_is_cached_as_conflict_evidence
    with_tmp_dir do |root|
      cache = build_cache(root)
      result = cache.refresh(identity) do
        observation.merge("head_oid" => "b" * 40)
      end

      assert_equal "b" * 40, result.dig("observation", "head_oid")
      assert_equal "a" * 40, result.dig("observation", "expected_head")
      refute result.dig("observation", "head_matches")
    end
  end

  private

  def build_cache(root, credential: "credential-token", project: { "name" => "demo" },
                  limits: Hive::TaskWorkspace::Limits.new,
                  clock: -> { Time.utc(2026, 8, 12, 12) })
    principal = Hive::TaskWorkspace::PublicationCache.principal_id(
      credential, secret: "cache-secret"
    )
    fingerprint = Hive::TaskWorkspace::PublicationCache.project_fingerprint(project)
    Hive::TaskWorkspace::PublicationCache.new(
      principal_id: principal, project_fingerprint: fingerprint,
      root: root, limits: limits, clock: clock
    )
  end

  def identity
    {
      "repository" => "github.com/acme/demo", "number" => 42,
      "expected_head" => "a" * 40
    }
  end

  def observation
    {
      "repository" => "github.com/acme/demo", "number" => 42,
      "url" => "https://github.com/acme/demo/pull/42",
      "state" => "OPEN", "is_draft" => false,
      "title" => "Ship it", "body" => "Bounded body",
      "base_branch" => "main", "base_oid" => "c" * 40,
      "head_branch" => "feature", "head_oid" => "a" * 40,
      "merge_state" => "CLEAN", "review_decision" => "APPROVED",
      "merged_at" => nil,
      "checks" => [
        { "name" => "test", "status" => "COMPLETED", "conclusion" => "SUCCESS" }
      ],
      "checks_truncated" => false
    }
  end
end
