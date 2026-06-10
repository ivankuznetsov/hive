# Bridges the gem's StatusFeed poller to Turbo Streams: one background
# subscriber per process watches for snapshot changes and broadcasts a
# replace of the projects frame to every connected dashboard. Pages render
# the same snapshot synchronously on first paint, so the stream only ever
# *updates* what the server already rendered.
class StatusBroadcaster
  CHANNEL = "status".freeze

  # json_payload regenerates `generated_at`/`age_seconds` on every poll, so
  # byte-comparing whole payloads would re-broadcast every tick. Compare the
  # projects subtree with volatile per-task fields stripped instead.
  VOLATILE_KEYS = %w[age_seconds].freeze

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
        last = nil
        feed.each_snapshot do |payload|
          key = comparable(payload)
          next if key == last

          last = key
          broadcast(payload)
        end
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

    def comparable(payload)
      projects = payload.fetch("projects", [])
      strip = lambda do |node|
        case node
        when Hash then node.except(*VOLATILE_KEYS).transform_values { |v| strip.call(v) }
        when Array then node.map { |v| strip.call(v) }
        else node
        end
      end
      strip.call(projects)
    end
  end
end
