require "json"
require "time"
require "monitor"
require "hive/commands/status"
require "hive/config"

module Hive
  module Web
    # Publishes the live `hive status` snapshot to subscribers — in the
    # Rails web tier that is StatusBroadcaster, which bridges each changed
    # snapshot to a Turbo Streams broadcast.
    #
    # A single shared background poller computes the snapshot ONCE per tick
    # (one filesystem scan + YAML parse for the whole box) and publishes it to
    # a mutex-protected latest-value. Every subscriber reads that shared value,
    # so N subscribers cost one scan per tick — not N.
    #
    # Contract: a new subscriber gets the current snapshot immediately (emit
    # on connect); unchanged snapshots are suppressed (dedup, volatile fields
    # stripped) and instead fire `on_idle` (a keep-alive seam — no production
    # subscriber passes it today, tests use it to observe deduped ticks); and
    # `snapshot` returns a freshly-computed payload for the per-request read
    # path (the grid render, task_row lookups).
    class StatusFeed
      def initialize(interval: 1.0, status_command: Hive::Commands::Status.new(json: true))
        @interval = interval
        @status_command = status_command
        @monitor = Monitor.new
        @tick = @monitor.new_cond
        @generation = 0
        @latest_json = nil
        @latest_payload = nil
        @poller = nil
      end

      # Compute a fresh snapshot. Used by the per-request read path (the grid
      # `/` route, `task_row`, `find_project!`). The SSE path goes through the
      # shared poller instead so it never pays this cost per connection.
      def snapshot
        @status_command.json_payload(Hive::Config.registered_projects)
      end

      # json_payload regenerates `generated_at` (and per-task `age_seconds`)
      # on every poll, so comparing raw serialized payloads re-emitted every
      # tick — the documented dedup was dead in production and the on_idle
      # keep-alive branch never ran. Strip the volatile fields for the
      # comparison; subscribers still receive the full payload.
      VOLATILE_KEYS = %w[generated_at age_seconds].freeze

      def each_snapshot(on_idle: nil)
        ensure_poller!

        payload, _json, seen_generation = current_snapshot
        last_key = comparable_key(payload)
        yield payload

        loop do
          payload, _json, seen_generation = await_tick(seen_generation)
          key = comparable_key(payload)
          if key != last_key
            last_key = key
            yield payload
          else
            on_idle&.call
          end
        end
      end

      # Stop the shared poller thread. Tests use this to reclaim the thread;
      # the production process keeps a single poller alive for its lifetime.
      def stop
        thread = nil
        @monitor.synchronize do
          thread = @poller
          @poller = nil
        end
        return unless thread

        thread.kill
        thread.join
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
          begin
            publish(compute_json)
          rescue StandardError => e
            warn "hive web: initial status snapshot failed (#{e.class}: #{e.message}); retrying on the next tick"
            publish([ { "projects" => [] }, "{}" ])
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
            publish(compute_json)
          rescue StandardError => e
            warn "hive web: status poll failed (#{e.class}: #{e.message}); retrying"
          end
        end
      end

      def compute_json
        payload = snapshot
        [ payload, JSON.generate(payload) ]
      end

      # Store the newest snapshot and wake every waiting subscriber. The
      # generation counter lets a subscriber detect it slept through a tick.
      def publish((payload, json))
        @monitor.synchronize do
          @latest_payload = payload
          @latest_json = json
          @generation += 1
          @tick.broadcast
        end
      end

      def current_snapshot
        @monitor.synchronize { [ @latest_payload, @latest_json, @generation ] }
      end

      # Block until the poller publishes a generation newer than the one this
      # subscriber last saw, then return the published value.
      def await_tick(seen_generation)
        @monitor.synchronize do
          @tick.wait while @generation == seen_generation
          [ @latest_payload, @latest_json, @generation ]
        end
      end

      def comparable_key(node)
        case node
        when Hash then node.except(*VOLATILE_KEYS).transform_values { |v| comparable_key(v) }
        when Array then node.map { |v| comparable_key(v) }
        else node
        end
      end
    end
  end
end
