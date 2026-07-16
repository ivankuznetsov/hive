require_relative "../../test_helper"
require "hive/provider_routing/store"

class ProviderRoutingStoreTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)

  def setup
    @account = Hive::ProviderRouting::Account.new(
      key: "claude-main", adapter: "claude", max_concurrent: nil,
      cooldown_sec: Hive::ProviderRouting::DEFAULT_COOLDOWNS,
      backoff_cap_sec: 86_400
    )
  end

  def test_closed_open_half_open_closed_lifecycle_survives_store_restart
    with_store do |store, path|
      transition = store.record(signal("session_limit"), account: @account)
      assert_equal %w[closed open], [ transition.from, transition.to ]

      later = NOW + 3600
      claim = store.claim_probe(
        provider: "claude-main", model: nil, attempt_id: "a1", owner: "pid:1", now: later
      )
      assert claim.claimed
      assert_equal "half_open", Hive::ProviderRouting::Store.new(path: path).state("claude-main").fetch("state")

      transition = Hive::ProviderRouting::Store.new(path: path).probe_succeeded(
        provider: "claude-main", model: nil, attempt_id: "a1", now: later + 1
      )
      assert_equal %w[half_open closed], [ transition.from, transition.to ]
      assert_equal "closed", Hive::ProviderRouting::Store.new(path: path).state("claude-main").fetch("state")
    end
  end

  def test_model_open_does_not_block_sibling_while_provider_open_blocks_all_models
    with_store do |store, _path|
      store.record(signal("quota", model: "opus", scope: "model"), account: @account)

      assert_equal "open", store.availability(provider: "claude-main", model: "opus").status
      assert_equal "closed", store.availability(provider: "claude-main", model: "sonnet").status

      store.record(signal("session_limit"), account: @account)
      assert_equal "open", store.availability(provider: "claude-main", model: "sonnet").status
      assert_equal "provider", store.availability(provider: "claude-main", model: "sonnet").scope
    end
  end

  def test_unknown_context_and_transient_signals_do_not_change_shared_state
    with_store do |store, _path|
      %w[unknown context_length transient timeout network stale_agent].each do |failure_class|
        assert_nil store.record(signal(failure_class), account: @account)
      end

      assert_equal "closed", store.state("claude-main").fetch("state")
      refute File.exist?(store.path), "no-policy signals should not create durable state"
    end
  end

  def test_probe_claim_is_exactly_once_across_processes
    skip "fork unavailable" unless Process.respond_to?(:fork)

    with_store do |store, path|
      store.record(signal("rate_limit"), account: @account)
      due = NOW + 300
      pids = 4.times.map do |index|
        fork do
          child = Hive::ProviderRouting::Store.new(path: path)
          claim = child.claim_probe(
            provider: "claude-main", model: nil,
            attempt_id: "attempt-#{index}", owner: "child-#{index}", now: due
          )
          exit!(claim.claimed ? 0 : 1)
        end
      end
      statuses = pids.map { |pid| Process.wait2(pid).last.exitstatus }

      assert_equal 1, statuses.count(0)
      assert_equal 3, statuses.count(1)
    end
  end

  def test_concurrent_process_updates_do_not_lose_distinct_providers
    skip "fork unavailable" unless Process.respond_to?(:fork)

    with_store do |_store, path|
      pids = %w[claude-main codex-main].map do |provider|
        fork do
          account = @account.with(key: provider, adapter: provider.start_with?("codex") ? "codex" : "claude")
          Hive::ProviderRouting::Store.new(path: path).record(
            signal("quota", provider: provider), account: account
          )
          exit! 0
        end
      end
      pids.each { |pid| Process.wait(pid) }

      providers = Hive::ProviderRouting::Store.new(path: path).snapshot.fetch("providers")
      assert_equal %w[claude-main codex-main], providers.keys.sort
      assert JSON.parse(File.read(path))
    end
  end

  def test_corrupt_snapshot_fails_closed_without_overwriting_evidence
    with_store do |_store, path|
      File.write(path, "not-json\n")
      before = File.binread(path)

      error = assert_raises(Hive::ProviderRouting::StoreError) do
        Hive::ProviderRouting::Store.new(path: path).availability(provider: "claude-main", model: nil)
      end

      assert_includes error.message, "provider circuit store"
      assert_equal before, File.binread(path)
    end
  end

  def test_durable_payload_contains_only_safe_normalized_evidence
    with_store do |store, path|
      store.record(
        Hive::ProviderRouting::Signal.new(
          provider: "claude-main", model: nil, failure_class: "quota", scope: "provider",
          reset_at: nil, safe_summary: "quota exhausted", fingerprint: "sha256:abc",
          evidence_ref: "logs/agent.log#tail"
        ),
        account: @account
      )

      payload = File.read(path)
      assert_includes payload, "quota exhausted"
      assert_includes payload, "sha256:abc"
      refute_includes payload, "api_key"
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_model_probe_claim_and_lost_probe_paths_are_fail_closed
    with_store do |store, _path|
      store.record(signal("quota", model: "opus", scope: "model"), account: @account)
      due = NOW + @account.cooldown_sec.fetch("quota")

      claim = store.claim_probe(
        provider: "claude-main", model: "opus", attempt_id: "model-probe",
        owner: "test", now: due
      )
      assert claim.claimed
      assert_equal "model", claim.scope

      refused = store.claim_probe(
        provider: "claude-main", model: "opus", attempt_id: "other",
        owner: "test", now: due
      )
      refute refused.claimed
      assert_equal "quota", refused.reason
      assert_nil store.probe_succeeded(
        provider: "claude-main", model: "opus", attempt_id: "wrong", now: due
      )
      assert store.probe_succeeded(
        provider: "claude-main", model: "opus", attempt_id: "model-probe", now: due
      )

      closed = store.claim_probe(
        provider: "claude-main", model: "sonnet", attempt_id: "not-due",
        owner: "test", now: due
      )
      refute closed.claimed
      assert_equal "closed", closed.reason
    end
  end

  def test_store_surfaces_schema_read_lock_and_write_failures
    with_store do |store, path|
      File.write(path, JSON.generate("schema_version" => 99, "providers" => {}))
      assert_raises(Hive::ProviderRouting::StoreError) { store.snapshot }

      file_read = File.method(:read)
      with_replaced_singleton_method(
        File, :read,
        ->(target, *args) { target == path ? (raise Errno::EACCES, target) : file_read.call(target, *args) }
      ) do
        assert_raises(Hive::ProviderRouting::StoreError) { store.snapshot }
      end

      FileUtils.rm_f(path)
      atomic_write = Hive::AtomicFile.method(:write)
      with_replaced_singleton_method(
        Hive::AtomicFile, :write,
        ->(target, *args, **kwargs) { target == path ? (raise Errno::ENOSPC, target) : atomic_write.call(target, *args, **kwargs) }
      ) do
        assert_raises(Hive::ProviderRouting::StoreError) do
          store.record(signal("quota"), account: @account)
        end
      end

      blocked = File.join(File.dirname(path), "blocked")
      File.write(blocked, "not a directory")
      unavailable = Hive::ProviderRouting::Store.new(
        path: path, lock_path: File.join(blocked, "lock")
      )
      assert_raises(Hive::ProviderRouting::StoreError) { unavailable.snapshot }
    end
  end

  def test_global_event_append_failure_is_non_fatal_and_deep_dup_handles_arrays
    with_store do |store, _path|
      with_tmp_dir do |dir|
        warnings = []
        store.define_singleton_method(:warn) { |message| warnings << message }
        with_replaced_singleton_method(
          Hive::Paths, :provider_circuit_events_path, -> { dir }
        ) do
          assert store.record(signal("quota"), account: @account)
        end
        assert_match(/failed to append circuit event/, warnings.join)
      end

      original = [ { "nested" => [ 1 ] } ]
      copy = store.send(:deep_dup, original)
      refute_same original, copy
      refute_same original.first.fetch("nested"), copy.first.fetch("nested")
    end
  end

  private

  def with_store
    with_tmp_dir do |dir|
      path = File.join(dir, "provider-circuits.v1.json")
      yield Hive::ProviderRouting::Store.new(path: path, clock: -> { NOW }), path
    end
  end

  def signal(failure_class, provider: "claude-main", model: nil, scope: "provider")
    Hive::ProviderRouting::Signal.new(
      provider: provider, model: model, failure_class: failure_class, scope: scope,
      reset_at: nil, safe_summary: failure_class, fingerprint: "fp-#{failure_class}",
      evidence_ref: "logs/test.log"
    )
  end
end
