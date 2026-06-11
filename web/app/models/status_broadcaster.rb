# Bridges the gem's StatusFeed poller to Turbo Streams: one background
# subscriber per process watches for snapshot changes and broadcasts a
# replace of the projects frame to every connected dashboard. Pages render
# the same snapshot synchronously on first paint, so the stream only ever
# *updates* what the server already rendered.
class StatusBroadcaster
  CHANNEL = "status".freeze

  # Seconds to back off after the subscriber loop dies before resubscribing.
  RETRY_SEC = 5

  class << self
    # Injectable for tests; one feed per process in production.
    attr_writer :feed

    def feed
      @feed ||= Hive::Web::StatusFeed.new
    end

    def snapshot
      feed.snapshot
    end

    # Self-healing by construction: a raising broadcast (a solid_cable
    # hiccup, one bad row blowing up the partial render) must not silently
    # freeze live updates forever — the first version logged once and let
    # the thread die, with `@thread ||=` pinning the corpse so even another
    # start! was a no-op. The loop resubscribes after a backoff, and start!
    # discards a dead thread before the ||=.
    def start!
      @thread = nil unless @thread&.alive?
      @thread ||= Thread.new do
        Thread.current.name = "status-broadcaster"
        loop do
          # The feed dedups (volatile fields stripped), so every yield is a
          # genuine change worth broadcasting.
          feed.each_snapshot { |payload| broadcast(payload) }
        rescue StandardError => e
          Rails.logger.error("status broadcaster error (#{e.class}: #{e.message}); resubscribing in #{RETRY_SEC}s")
          sleep RETRY_SEC
        end
      end
    end

    def stop!
      @thread&.kill
      @thread = nil
      @feed&.stop
      @feed = nil
    end

    private

    def broadcast(payload)
      Turbo::StreamsChannel.broadcast_replace_to(
        CHANNEL,
        target: "projects",
        partial: "status/projects",
        locals: { projects: payload.fetch("projects", []) }
      )
    end
  end
end
