require "json"
require "securerandom"
require "hive/atomic_file"
require "hive/attempt_lease"
require "hive/lock"
require "hive/paths"

module Hive
  class AttemptLeaseStoreError < Hive::Error
    def exit_code
      Hive::ExitCodes::UNAVAILABLE
    end
  end

  class AttemptLeaseStore
    SCHEMA_VERSION = 1
    DEFAULT_TTL_SEC = 300
    PROVIDER_NAMESPACE = "provider_attempt"
    RECOVERY_NAMESPACE = "workflow_recovery"

    Claim = Data.define(:claimed, :lease, :reason, :active_count)

    attr_reader :path, :lock_path

    def initialize(path: Hive::Paths.attempt_leases_path, lock_path: nil,
                   clock: -> { Time.now.utc }, owner_alive: nil)
      @path = path
      @lock_path = lock_path || (path == Hive::Paths.attempt_leases_path ?
        Hive::Paths.attempt_leases_lock_path : "#{path}.lock")
      @clock = clock
      @owner_alive = owner_alive || method(:process_identity_alive?)
    end

    def claim_provider(provider:, model:, attempt_id:, max_concurrent: nil,
                       ttl_sec: DEFAULT_TTL_SEC, provenance: {}, now: @clock.call)
      provider = provider.to_s
      model_key = model.nil? ? "default" : model.to_s
      attempt_id = attempt_id.to_s
      claim(
        namespace: PROVIDER_NAMESPACE,
        key: [ provider, model_key, attempt_id ].join("/"),
        group: provider,
        lease_id: "#{provider}/#{model_key}/#{attempt_id}",
        ttl_sec: ttl_sec,
        limit: max_concurrent,
        provenance: provenance,
        now: now
      )
    end

    def claim_recovery(workflow_id:, checkpoint_generation:, ttl_sec: DEFAULT_TTL_SEC,
                       provenance: {}, now: @clock.call)
      key = "#{workflow_id}/#{checkpoint_generation}"
      claim(
        namespace: RECOVERY_NAMESPACE,
        key: key,
        group: workflow_id.to_s,
        lease_id: key,
        ttl_sec: ttl_sec,
        provenance: provenance,
        deduplicate: true,
        now: now
      )
    end

    def claim(namespace:, key:, group:, lease_id: SecureRandom.uuid,
              ttl_sec: DEFAULT_TTL_SEC, limit: nil, provenance: {}, deduplicate: false,
              owner_pid: Process.pid, owner_start_time: Hive::Lock.process_start_time(Process.pid),
              now: @clock.call)
      validate_claim!(ttl_sec: ttl_sec, limit: limit)
      namespace = namespace.to_s
      key = key.to_s
      group = group.to_s
      lease_id = lease_id.to_s

      mutate(now: now) do |snapshot|
        existing = find_lease(snapshot, namespace: namespace, lease_id: lease_id)
        if existing&.active? && existing.owner_pid == owner_pid &&
            existing.owner_start_time == owner_start_time
          next [ Claim.new(claimed: true, lease: existing, reason: "already_claimed",
                           active_count: active_count_in(snapshot, namespace, group)), false ]
        end

        if deduplicate && find_by_key(snapshot, namespace: namespace, key: key)
          next [ Claim.new(claimed: false, lease: nil, reason: "already_recovered",
                           active_count: active_count_in(snapshot, namespace, group)), false ]
        end

        if existing&.active?
          next [ Claim.new(claimed: false, lease: nil, reason: "lease_in_use",
                           active_count: active_count_in(snapshot, namespace, group)), false ]
        end

        count = active_count_in(snapshot, namespace, group)
        if limit && count >= limit
          next [ Claim.new(claimed: false, lease: nil, reason: "concurrency_cap", active_count: count), false ]
        end

        lease = AttemptLease.new(
          id: lease_id,
          namespace: namespace,
          key: key,
          group: group,
          owner_pid: owner_pid,
          owner_start_time: owner_start_time,
          provenance: stringify_hash(provenance),
          acquired_at: now.utc,
          heartbeat_at: now.utc,
          expires_at: now.utc + ttl_sec,
          state: "active"
        )
        snapshot.fetch("leases")[storage_key(namespace, lease_id)] = lease.to_h
        snapshot["generation"] = snapshot.fetch("generation") + 1
        [ Claim.new(claimed: true, lease: lease, reason: "claimed", active_count: count + 1), true ]
      end
    end

    def heartbeat(lease, ttl_sec: DEFAULT_TTL_SEC, now: @clock.call)
      validate_claim!(ttl_sec: ttl_sec, limit: nil)
      mutate(now: now) do |snapshot|
        current = find_lease(snapshot, namespace: lease.namespace, lease_id: lease.id)
        next [ false, false ] unless owned_active?(current, lease)

        renewed = current.with(heartbeat_at: now.utc, expires_at: now.utc + ttl_sec)
        snapshot.fetch("leases")[storage_key(current.namespace, current.id)] = renewed.to_h
        snapshot["generation"] = snapshot.fetch("generation") + 1
        [ true, true ]
      end
    end

    def release(lease, now: @clock.call)
      mutate(now: now) do |snapshot|
        current = find_lease(snapshot, namespace: lease.namespace, lease_id: lease.id)
        next [ false, false ] unless owned_active?(current, lease)

        snapshot.fetch("leases").delete(storage_key(current.namespace, current.id))
        snapshot["generation"] = snapshot.fetch("generation") + 1
        [ true, true ]
      end
    end

    def complete(lease, now: @clock.call)
      mutate(now: now) do |snapshot|
        current = find_lease(snapshot, namespace: lease.namespace, lease_id: lease.id)
        next [ false, false ] unless owned_active?(current, lease)

        completed = current.with(state: "completed", heartbeat_at: now.utc, expires_at: now.utc)
        snapshot.fetch("leases")[storage_key(current.namespace, current.id)] = completed.to_h
        snapshot["generation"] = snapshot.fetch("generation") + 1
        [ true, true ]
      end
    end

    def active_count(namespace: PROVIDER_NAMESPACE, group:, now: @clock.call)
      mutate(now: now) do |snapshot|
        [ active_count_in(snapshot, namespace.to_s, group.to_s), false ]
      end
    end

    def active?(lease, now: @clock.call)
      mutate(now: now) do |snapshot|
        current = find_lease(snapshot, namespace: lease.namespace, lease_id: lease.id)
        [ owned_active?(current, lease), false ]
      end
    end

    def leases(namespace: nil, now: @clock.call)
      mutate(now: now) do |snapshot|
        values = snapshot.fetch("leases").values.map { |value| AttemptLease.from_h(value) }
        values.select! { |lease| lease.namespace == namespace.to_s } if namespace
        [ values.sort_by { |lease| [ lease.namespace, lease.group, lease.key, lease.id ] }, false ]
      end
    end

    def snapshot(now: @clock.call)
      mutate(now: now) { |value| [ deep_dup(value), false ] }
    end

    def with_heartbeat(lease, interval_sec: 30)
      return yield unless lease

      heartbeat_thread = Thread.new do
        loop do
          sleep interval_sec
          break unless heartbeat(lease)
        end
      end
      yield
    ensure
      heartbeat_thread&.kill
      heartbeat_thread&.join
      release(lease) if lease
    end

    private

    def mutate(now:)
      with_lock do
        snapshot = read_snapshot_unlocked
        reaped = reap_stale!(snapshot, now: now)
        result, changed = yield snapshot
        write_snapshot_unlocked(snapshot) if reaped || changed
        result
      end
    end

    def reap_stale!(snapshot, now:)
      stale = snapshot.fetch("leases").filter_map do |storage, value|
        lease = AttemptLease.from_h(value)
        next unless lease.active?
        next unless lease.expires_at <= now || !@owner_alive.call(lease.owner_pid, lease.owner_start_time)

        storage
      end
      return false if stale.empty?

      stale.each { |key| snapshot.fetch("leases").delete(key) }
      snapshot["generation"] = snapshot.fetch("generation") + 1
      true
    end

    def active_count_in(snapshot, namespace, group)
      snapshot.fetch("leases").values.count do |value|
        value["state"] == "active" && value["namespace"] == namespace && value["group"] == group
      end
    end

    def find_lease(snapshot, namespace:, lease_id:)
      value = snapshot.fetch("leases")[storage_key(namespace, lease_id)]
      value && AttemptLease.from_h(value)
    end

    def find_by_key(snapshot, namespace:, key:)
      value = snapshot.fetch("leases").values.find do |candidate|
        candidate["namespace"] == namespace && candidate["key"] == key
      end
      value && AttemptLease.from_h(value)
    end

    def owned_active?(current, supplied)
      current&.active? && current.owner_pid == supplied.owner_pid &&
        current.owner_start_time == supplied.owner_start_time
    end

    def storage_key(namespace, lease_id)
      "#{namespace}:#{lease_id}"
    end

    def validate_claim!(ttl_sec:, limit:)
      raise ArgumentError, "ttl_sec must be positive" unless ttl_sec.is_a?(Numeric) && ttl_sec.positive?
      return if limit.nil? || (limit.is_a?(Integer) && limit.positive?)

      raise ArgumentError, "limit must be a positive integer"
    end

    def process_identity_alive?(pid, recorded_start)
      Process.kill(0, pid)
      live_start = Hive::Lock.process_start_time(pid)
      recorded_start.nil? || live_start.nil? || recorded_start == live_start
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def with_lock
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.chmod(0o600)
        lock.flock(File::LOCK_EX)
        yield
      end
    rescue AttemptLeaseStoreError
      raise
    rescue SystemCallError, IOError => e
      raise AttemptLeaseStoreError, "attempt lease store at #{path} is unavailable: #{e.message}"
    end

    def read_snapshot_unlocked
      return empty_snapshot unless File.exist?(path)

      data = JSON.parse(File.read(path))
      unless data.is_a?(Hash) && data["schema_version"] == SCHEMA_VERSION && data["leases"].is_a?(Hash)
        raise AttemptLeaseStoreError,
              "attempt lease store at #{path} has unsupported or malformed schema; preserving it unchanged"
      end
      data
    rescue JSON::ParserError, TypeError, KeyError, ArgumentError => e
      raise AttemptLeaseStoreError,
            "attempt lease store at #{path} is corrupt (#{e.message}); preserving it unchanged"
    rescue AttemptLeaseStoreError
      raise
    rescue SystemCallError, IOError => e
      raise AttemptLeaseStoreError, "attempt lease store at #{path} is unreadable: #{e.message}"
    end

    def write_snapshot_unlocked(snapshot)
      Hive::AtomicFile.write(path, JSON.pretty_generate(snapshot) + "\n", mode: 0o600)
      File.chmod(0o600, path)
    rescue SystemCallError, IOError => e
      raise AttemptLeaseStoreError, "attempt lease store at #{path} could not be written: #{e.message}"
    end

    def empty_snapshot
      { "schema_version" => SCHEMA_VERSION, "generation" => 0, "leases" => {} }
    end

    def stringify_hash(value)
      value.to_h { |key, child| [ key.to_s, child ] }
    end

    def deep_dup(value)
      case value
      when Hash then value.to_h { |key, child| [ key, deep_dup(child) ] }
      when Array then value.map { |child| deep_dup(child) }
      else value
      end
    end
  end
end
