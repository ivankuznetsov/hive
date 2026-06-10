# Bridges the gem's StatusFeed poller to Turbo Streams: one background
# subscriber per process watches for snapshot changes and broadcasts a
# replace of the projects frame to every connected dashboard. Pages render
# the same snapshot synchronously on first paint, so the stream only ever
# *updates* what the server already rendered.
class StatusBroadcaster
  CHANNEL = "status".freeze

  class << self
    def feed
      @feed ||= Hive::Web::StatusFeed.new
    end

    def snapshot
      feed.snapshot
    end

    def start!
      @thread ||= Thread.new do
        Thread.current.name = "status-broadcaster"
        # The feed dedups (volatile fields stripped), so every yield is a
        # genuine change worth broadcasting.
        feed.each_snapshot { |payload| broadcast(payload) }
      rescue StandardError => e
        Rails.logger.error("status broadcaster died: #{e.class}: #{e.message}")
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
