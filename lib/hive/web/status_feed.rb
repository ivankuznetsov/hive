require "digest"
require "json"
require "monitor"
require "time"
require "hive/commands/status"
require "hive/config"
require "hive/secret_patterns"

module Hive
  module Web
    # The process-wide owner of the expensive fleet status computation.
    #
    # HTTP status renders and the Cable poller both enter refresh_state, whose
    # single-flight gate guarantees that concurrent callers share one scan.
    # Failures never manufacture a healthy empty fleet: they publish either a
    # degraded latest-good snapshot or an explicit unavailable envelope.
    class StatusFeed
      DEFAULT_INTERVAL = 5.0
      VOLATILE_KEYS = %w[generated_at age_seconds].freeze
      UNAVAILABLE_PAYLOAD = {
        "schema" => "hive-status",
        "ok" => false,
        "unavailable" => true,
        "projects" => []
      }.freeze

      State = Data.define(
        :payload, :availability, :token, :last_success_at, :error,
        :scan_count, :generation
      ) do
        def fresh? = availability == "fresh"
        def degraded? = availability == "degraded"
        def unavailable? = availability == "unavailable"

        def to_h
          {
            "payload" => payload,
            "availability" => availability,
            "token" => token,
            "last_success_at" => last_success_at,
            "error" => error,
            "scan_count" => scan_count,
            "generation" => generation
          }
        end
      end

      def initialize(
        interval: DEFAULT_INTERVAL,
        status_command: Hive::Commands::Status.new(json: true),
        archive_status_command: Hive::Commands::Status.new(json: true, archive: true),
        clock: -> { Time.now.utc }
      )
        @interval = interval
        @status_command = status_command
        @archive_status_command = archive_status_command
        @clock = clock
        @monitor = Monitor.new
        @tick = @monitor.new_cond
        @refresh_done = @monitor.new_cond
        @generation = 0
        @scan_count = 0
        @state = nil
        @latest_good = nil
        @latest_key = nil
        @latest_token = nil
        @prime_claim = nil
        @refreshing = false
        @poller = nil
      end

      # Compatibility read for callers that only consume the status payload.
      # New web callers should use snapshot_state so availability cannot be
      # mistaken for a real empty fleet.
      def snapshot
        snapshot_state.payload
      end

      # Dedicated archive reads are lossless and deliberately stay outside
      # the ordinary feed's priming, availability, and dedup lifecycle.
      def archive_snapshot
        @archive_status_command.json_payload(Hive::Config.registered_projects)
      end

      # One fresh scan, coalesced across all callers already waiting for it.
      def snapshot_state
        refresh_state
      end

      # A non-scanning read for task-local routes and reconnecting subscribers.
      def current_state
        @monitor.synchronize { @state }
      end

      def scan_count
        @monitor.synchronize { @scan_count }
      end

      # Seed the poller from a status page that already rendered a successful
      # payload. A competing page receives the token for its own content but
      # cannot replace the active lifecycle's baseline.
      def prime(payload)
        key = state_key("fresh", payload)
        token = cached_token_for(key)
        @monitor.synchronize do
          unless @poller&.alive? || @prime_claim
            now = iso_time(@clock.call)
            @generation += 1
            @latest_good = payload
            @latest_key = key
            @latest_token = token
            @state = State.new(
              payload: payload,
              availability: "fresh",
              token: token,
              last_success_at: now,
              error: nil,
              scan_count: @scan_count,
              generation: @generation
            )
            @prime_claim = Object.new
          end

          token
        end
      end

      def current_version?(candidate)
        candidate.is_a?(String) &&
          @monitor.synchronize { candidate == @state&.token }
      end

      # State-aware subscribers receive degradation and recovery transitions
      # even when the underlying last-good rows are unchanged.
      def each_state(on_idle: nil)
        ensure_poller!
        state, last_key, seen_generation = current_publication
        yield state

        loop do
          state, key, seen_generation = await_tick(seen_generation)
          if key != last_key
            last_key = key
            yield state
          else
            on_idle&.call
          end
        end
      end

      # Legacy payload-only subscription. Freshness-only transitions are idle
      # ticks here; StatusBroadcaster uses each_state.
      def each_snapshot(on_idle: nil)
        ensure_poller!
        state, = current_publication
        last_payload_key = comparable_key(state.payload)
        seen_generation = state.generation
        yield state.payload

        loop do
          state, _key, seen_generation = await_tick(seen_generation)
          payload_key = comparable_key(state.payload)
          if payload_key != last_payload_key
            last_payload_key = payload_key
            yield state.payload
          else
            on_idle&.call
          end
        end
      end

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
          if !@poller&.alive? && @prime_claim.equal?(detached_prime_claim)
            @prime_claim = nil
          end
        end
      end

      private

      def compute_snapshot
        projects = Hive::Config.registered_projects
        payload = @status_command.json_payload(projects)
        overlay_operational_recoveries(payload, projects)
      end

      def refresh_state
        owner = false
        @monitor.synchronize do
          if @refreshing
            @refresh_done.wait while @refreshing
            return @state
          end
          @refreshing = true
          @scan_count += 1
          owner = true
        end

        begin
          publish_success(compute_snapshot)
        rescue StandardError => e
          publish_failure(e)
        ensure
          if owner
            @monitor.synchronize do
              @refreshing = false
              @refresh_done.broadcast
            end
          end
        end
        @monitor.synchronize { @state }
      end

      # The web page already paid for one ordinary status scan. Reuse that
      # exact payload when asking the status producer to join the daemon's
      # owner-private snapshot, then copy only canonical recovery receipts
      # onto the matching task rows. This is a file read + in-memory join, not
      # a second fleet scan. The lean projection also avoids building the
      # complete operational envelope on every five-second web poll.
      def overlay_operational_recoveries(payload, projects)
        return payload unless @status_command.respond_to?(:operational_recoveries)

        recovery_rows = @status_command.operational_recoveries(
          projects,
          status_payload: payload
        )
        recoveries = Array(recovery_rows).to_h do |task|
          identity = task["identity"] || {}
          [ [ identity["project"].to_s, identity["slug"].to_s ], task["recovery"] ]
        end
        Array(payload["projects"]).each do |project|
          Array(project["tasks"]).each do |task|
            recovery = recoveries[[ project["name"].to_s, task["slug"].to_s ]]
            task["recovery"] = recovery if recovery.is_a?(Hash)
          end
        end
        payload
      rescue StandardError => e
        warn "hive web: operational recovery overlay failed (#{e.class}: #{e.message}); using base status"
        payload
      end

      def ensure_poller!
        needs_initial = @monitor.synchronize { @state.nil? }
        refresh_state if needs_initial

        @monitor.synchronize do
          return if @poller&.alive?

          @poller = Thread.new { poll_loop }
        end
      end

      def poll_loop
        loop do
          sleep @interval
          refresh_state
        end
      end

      def publish_success(payload)
        key = state_key("fresh", payload)
        token = cached_token_for(key)
        now = iso_time(@clock.call)
        @monitor.synchronize do
          @generation += 1
          @latest_good = payload
          @latest_key = key
          @latest_token = token
          @state = State.new(
            payload: payload,
            availability: "fresh",
            token: token,
            last_success_at: now,
            error: nil,
            scan_count: @scan_count,
            generation: @generation
          )
          @tick.broadcast
        end
      end

      # Kept as a test seam and for callers that publish an already computed
      # payload. It is a successful publication and does not increment scans.
      def publish(payload)
        publish_success(payload)
      end

      def publish_failure(error)
        diagnostic = bounded_error(error)
        warn "hive web: status snapshot failed (#{error.class}: #{diagnostic}); retrying"
        @monitor.synchronize do
          availability = @latest_good ? "degraded" : "unavailable"
          payload = @latest_good || UNAVAILABLE_PAYLOAD.dup
          key = state_key(availability, payload)
          token = key == @latest_key ? @latest_token : token_for(key)
          @generation += 1
          @latest_key = key
          @latest_token = token
          @state = State.new(
            payload: payload,
            availability: availability,
            token: token,
            last_success_at: @state&.last_success_at,
            error: "#{error.class}: #{diagnostic}",
            scan_count: @scan_count,
            generation: @generation
          )
          @tick.broadcast
        end
      end

      def current_publication
        @monitor.synchronize { [ @state, @latest_key, @generation ] }
      end

      def await_tick(seen_generation)
        @monitor.synchronize do
          @tick.wait while @generation == seen_generation
          [ @state, @latest_key, @generation ]
        end
      end

      def cached_token_for(key)
        cached = @monitor.synchronize { @latest_token if key == @latest_key }
        cached || token_for(key)
      end

      def state_key(availability, payload)
        { "availability" => availability, "payload" => comparable_key(payload) }
      end

      def comparable_key(node)
        case node
        when Hash then node.except(*VOLATILE_KEYS).transform_values { |value| comparable_key(value) }
        when Array then node.map { |value| comparable_key(value) }
        else node
        end
      end

      def token_for(key)
        "sha256:#{::Digest::SHA256.hexdigest(JSON.generate(canonicalize(key)))}"
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

      def bounded_error(error)
        text = error.message.to_s.b.byteslice(0, 4 * 1024).to_s
                    .force_encoding(Encoding::UTF_8).scrub
        Hive::SecretPatterns.redact(text)
      end

      def iso_time(value)
        value.respond_to?(:utc) ? value.utc.iso8601(6) : Time.parse(value.to_s).utc.iso8601(6)
      end
    end
  end
end
