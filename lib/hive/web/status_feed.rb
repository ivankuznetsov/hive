require "time"
require "monitor"
require "digest"
require "json"
require "hive/commands/status"
require "hive/config"

module Hive
  module Web
    # Publishes the live `hive status` snapshot to subscribers — in the
    # Rails web tier that is StatusBroadcaster, which bridges each changed
    # snapshot to a Turbo Streams broadcast.
    #
    # While at least one live page is connected, a single shared background
    # poller computes the snapshot ONCE per tick (one filesystem scan + YAML
    # parse for the whole box) and publishes it to a mutex-protected
    # latest-value. Every subscriber reads that shared value, so N subscribers
    # cost one scan per tick — not N; an idle server performs no scans.
    #
    # Contract: a new subscriber gets the current snapshot immediately (emit
    # on connect); unchanged snapshots are suppressed (dedup, volatile fields
    # stripped) and instead fire `on_idle` (a keep-alive seam — no production
    # subscriber passes it today, tests use it to observe deduped ticks); and
    # `snapshot` returns a freshly-computed payload for the per-request read
    # path (the grid render, task_row lookups).
    class StatusFeed
      DEFAULT_INTERVAL = 5.0

      def initialize(interval: DEFAULT_INTERVAL, status_command: Hive::Commands::Status.new(json: true))
        @interval = interval
        @status_command = status_command
        @monitor = Monitor.new
        @tick = @monitor.new_cond
        @generation = 0
        @latest_payload = nil
        @latest_key = nil
        @latest_token = nil
        @prime_claim = nil
        @poller = nil
      end

      # Compute a fresh snapshot. Used by the per-request read path (the grid
      # `/` route, `task_row`, `find_project!`). The SSE path goes through the
      # shared poller instead so it never pays this cost per connection.
      def snapshot
        @status_command.json_payload(Hive::Config.registered_projects)
      end

      # Seed the shared poller from the snapshot Rails already computed to
      # render the subscribing page. Without this handoff, the first Cable
      # connection immediately repeats the same full-fleet filesystem scan.
      # The first request owns the idle baseline until this poller lifecycle
      # starts. Every page receives a stable token for the exact semantic
      # payload it rendered; StatusChannel compares that token after Cable
      # confirms, so an interleaving poll or another Puma worker cannot label
      # stale content as current.
      def prime(payload)
        key = comparable_key(payload)
        token = cached_token_for(key)
        @monitor.synchronize do
          unless @poller&.alive? || @prime_claim
            @latest_payload = payload
            @latest_key = key
            @latest_token = token
            @prime_claim = Object.new
            @generation += 1
          end

          token
        end
      end

      # The poll sequence wakes subscribers on every tick so `on_idle` keeps
      # its contract. The public token changes only with semantic content,
      # preventing an unchanged background tick from making a restored page
      # look stale and trigger an unnecessary HTTP refresh.
      def current_version?(candidate)
        candidate.is_a?(String) && @monitor.synchronize { candidate == @latest_token }
      end

      # json_payload regenerates `generated_at` (and per-task `age_seconds`)
      # on every poll, so comparing raw serialized payloads re-emitted every
      # tick — the documented dedup was dead in production and the on_idle
      # keep-alive branch never ran. Strip the volatile fields for the
      # comparison; subscribers still receive the full payload.
      # mtime/folder_mtime are deliberately NOT volatile: task-page artifact
      # liveness rides on them — a state-file write is often the ONLY field
      # that changes while an agent works, and stripping it would dedup away
      # the broadcast that refreshes artifact bodies mid-write.
      VOLATILE_KEYS = %w[generated_at age_seconds].freeze

      def each_snapshot(on_idle: nil)
        ensure_poller!

        payload, last_key, seen_generation = current_snapshot
        yield payload

        loop do
          payload, key, seen_generation = await_tick(seen_generation)
          if key != last_key
            last_key = key
            yield payload
          else
            on_idle&.call
          end
        end
      end

      # Stop the shared poller thread. StatusChannel calls this after the last
      # live page disconnects; tests also use it to reclaim the thread.
      def stop
        thread = nil
        detached_prime_claim = nil
        @monitor.synchronize do
          thread = @poller
          @poller = nil
          detached_prime_claim = @prime_claim
          @prime_claim = nil unless thread
        end
        return unless thread

        thread.kill
        thread.join
        @monitor.synchronize do
          # A request can claim a new idle baseline while the detached thread
          # is joining. Release only the claim that belonged to the lifecycle
          # being stopped, never a newer claim accepted in that join window.
          if !@poller&.alive? && @prime_claim.equal?(detached_prime_claim)
            @prime_claim = nil
          end
        end
      end

      private

      # Lazily start the single shared poller on the first subscriber so a box
      # with no open dashboards does no background scanning at all.
      def ensure_poller!
        @monitor.synchronize do
          return if @poller&.alive?

          # The connect-emit compute rides the same safety net as the loop:
          # a config error at exactly boot time must not kill the subscriber
          # thread before the poller ever starts.
          unless @latest_payload
            begin
              publish(snapshot)
            rescue StandardError => e
              warn "hive web: initial status snapshot failed (#{e.class}: #{e.message}); retrying on the next tick"
              publish({ "projects" => [] })
            end
          end
          @poller = Thread.new { poll_loop }
        end
      end

      def poll_loop
        loop do
          sleep @interval
          # A transient snapshot failure (operator mid-edit on config.yml, a
          # task folder mv racing the scan) must not kill the poller thread:
          # a dead poller silently freezes every subscriber forever — ticks
          # stop, so even the on_idle keep-alive path never runs again. Log
          # and try again next tick.
          begin
            publish(snapshot)
          rescue StandardError => e
            warn "hive web: status poll failed (#{e.class}: #{e.message}); retrying"
          end
        end
      end

      # Store the newest snapshot and wake every waiting subscriber. The
      # generation counter lets a subscriber detect it slept through a tick.
      def publish(payload)
        key = comparable_key(payload)
        token = cached_token_for(key)
        @monitor.synchronize do
          @latest_payload = payload
          @latest_key = key
          @latest_token = token
          @generation += 1
          @tick.broadcast
        end
      end

      def current_snapshot
        @monitor.synchronize { [ @latest_payload, @latest_key, @generation ] }
      end

      # Block until the poller publishes a generation newer than the one this
      # subscriber last saw, then return the published value.
      def await_tick(seen_generation)
        @monitor.synchronize do
          @tick.wait while @generation == seen_generation
          [ @latest_payload, @latest_key, @generation ]
        end
      end

      def cached_token_for(key)
        cached = @monitor.synchronize { @latest_token if key == @latest_key }
        cached || token_for(key)
      end

      def comparable_key(node)
        case node
        when Hash then node.except(*VOLATILE_KEYS).transform_values { |v| comparable_key(v) }
        when Array then node.map { |v| comparable_key(v) }
        else node
        end
      end

      # A content identity, not a process-local event counter: HTTP and Cable
      # may land on different Puma workers, and an open page may reconnect
      # after a process restart. Canonical key ordering makes equal semantic
      # payloads produce the same token in every process.
      def token_for(key)
        canonical = canonicalize(key)
        "sha256:#{::Digest::SHA256.hexdigest(JSON.generate(canonical))}"
      end

      def canonicalize(node)
        case node
        when Hash
          node.keys.sort_by(&:to_s).to_h { |key| [ key.to_s, canonicalize(node.fetch(key)) ] }
        when Array
          node.map { |value| canonicalize(value) }
        else
          node
        end
      end
    end
  end
end
