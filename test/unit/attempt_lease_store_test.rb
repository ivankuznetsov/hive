require_relative "../test_helper"
require "hive/attempt_lease_store"

class AttemptLeaseStoreTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)

  def test_provider_cap_is_claimed_atomically_across_processes
    skip "fork unavailable" unless Process.respond_to?(:fork)

    with_store do |_store, path|
      pids = 5.times.map do |index|
        fork do
          claim = store_at(path).claim_provider(
            provider: "claude-main", model: "opus", attempt_id: "attempt-#{index}",
            max_concurrent: 2, ttl_sec: 3600, now: NOW
          )
          exit!(claim.claimed ? 0 : 1)
        end
      end
      statuses = pids.map { |pid| Process.wait2(pid).last.exitstatus }

      assert_equal 2, statuses.count(0)
      assert_equal 3, statuses.count(1)
      assert_equal 2, store_at(path).active_count(group: "claude-main", now: NOW)
    end
  end

  def test_unset_cap_collects_observed_concurrency_without_blocking
    with_store do |store, _path|
      claims = 3.times.map do |index|
        store.claim_provider(
          provider: "codex-main", model: nil, attempt_id: index, max_concurrent: nil,
          ttl_sec: 3600
        )
      end

      assert claims.all?(&:claimed)
      assert_equal 3, store.active_count(group: "codex-main")
    end
  end

  def test_active_counts_survive_store_restart
    with_store do |store, path|
      store.claim_provider(
        provider: "grok-main", model: "grok-4", attempt_id: "a1", ttl_sec: 3600
      )

      assert_equal 1, store_at(path).active_count(group: "grok-main", now: NOW)
    end
  end

  def test_heartbeat_renews_live_attempt_and_expired_attempt_is_reaped
    with_store(owner_alive: ->(_pid, _start) { true }) do |store, _path|
      claim = store.claim_provider(
        provider: "claude-main", model: nil, attempt_id: "live", ttl_sec: 10
      )

      assert store.heartbeat(claim.lease, ttl_sec: 10, now: NOW + 9)
      assert_equal 1, store.active_count(group: "claude-main", now: NOW + 15)
      assert_equal 0, store.active_count(group: "claude-main", now: NOW + 20)
    end
  end

  def test_dead_or_reused_owner_is_reclaimed_before_capacity_check
    owner_alive = ->(_pid, start) { start != "dead-start" }
    with_store(owner_alive: owner_alive) do |store, _path|
      dead = store.claim(
        namespace: Hive::AttemptLeaseStore::PROVIDER_NAMESPACE,
        key: "pi-main/default/dead", group: "pi-main", lease_id: "dead",
        ttl_sec: 3600, limit: 1, owner_pid: 999_999, owner_start_time: "dead-start", now: NOW
      )
      assert dead.claimed

      replacement = store.claim_provider(
        provider: "pi-main", model: nil, attempt_id: "replacement",
        max_concurrent: 1, ttl_sec: 3600
      )
      assert replacement.claimed
    end
  end

  def test_release_frees_provider_capacity_and_complete_retains_recovery_deduplication
    with_store do |store, _path|
      provider = store.claim_provider(
        provider: "codex-main", model: nil, attempt_id: "one", max_concurrent: 1,
        ttl_sec: 3600
      )
      assert store.release(provider.lease)
      assert store.claim_provider(
        provider: "codex-main", model: nil, attempt_id: "two", max_concurrent: 1,
        ttl_sec: 3600
      ).claimed

      recovery = store.claim_recovery(
        workflow_id: "bench/run-1", checkpoint_generation: 7, ttl_sec: 3600
      )
      assert recovery.claimed
      assert store.complete(recovery.lease)
      duplicate = store.claim_recovery(
        workflow_id: "bench/run-1", checkpoint_generation: 7, ttl_sec: 3600
      )
      refute duplicate.claimed
      assert_equal "already_recovered", duplicate.reason
      assert store.claim_recovery(
        workflow_id: "bench/run-1", checkpoint_generation: 8, ttl_sec: 3600
      ).claimed
    end
  end

  def test_same_recovery_generation_has_one_winner_across_processes
    skip "fork unavailable" unless Process.respond_to?(:fork)

    with_store do |_store, path|
      pids = 4.times.map do
        fork do
          claim = store_at(path).claim_recovery(
            workflow_id: "campaign-1", checkpoint_generation: 3, ttl_sec: 3600, now: NOW
          )
          exit!(claim.claimed ? 0 : 1)
        end
      end
      statuses = pids.map { |pid| Process.wait2(pid).last.exitstatus }

      assert_equal 1, statuses.count(0)
      assert_equal 3, statuses.count(1)
    end
  end

  def test_corrupt_store_fails_closed_without_replacing_evidence
    with_store do |_store, path|
      File.write(path, "not-json\n")
      before = File.binread(path)

      error = assert_raises(Hive::AttemptLeaseStoreError) do
        store_at(path).claim_provider(provider: "claude-main", model: nil, attempt_id: "a1")
      end

      assert_includes error.message, "attempt lease store"
      assert_equal before, File.binread(path)
    end
  end

  private

  def with_store(owner_alive: ->(_pid, _start) { true })
    with_tmp_dir do |dir|
      path = File.join(dir, "attempt-leases.v1.json")
      yield store_at(path, owner_alive: owner_alive), path
    end
  end

  def store_at(path, owner_alive: ->(_pid, _start) { true })
    Hive::AttemptLeaseStore.new(path: path, clock: -> { NOW }, owner_alive: owner_alive)
  end
end
