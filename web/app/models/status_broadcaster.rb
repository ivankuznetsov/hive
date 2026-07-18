# Bridges the gem's StatusFeed poller to Turbo Streams: one background
# subscriber per process watches for snapshot changes and broadcasts a
# replace of the projects frame to every connected dashboard. Pages render
# the same snapshot synchronously on first paint, so the stream only ever
# *updates* what the server already rendered.
require "securerandom"

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

    def stream_cursor
      @stream_epoch ||= SecureRandom.uuid
      @stream_generation ||= 0
      { epoch: @stream_epoch, generation: @stream_generation }
    end

    # Self-healing by construction: a raising broadcast (a solid_cable
    # hiccup, one bad row blowing up the partial render) must not silently
    # freeze live updates forever — the first version logged once and let
    # the thread die, with `@thread ||=` pinning the corpse so even another
    # start! was a no-op. The loop resubscribes after a backoff, and start!
    # discards a dead thread before the ||=.
    def start!
      @thread = nil unless @thread&.alive?
      reset_stream! unless @thread
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
      @stream_epoch = nil
      @stream_generation = 0
    end

    private

    def broadcast(payload)
      cursor = advance_stream!
      Turbo::StreamsChannel.broadcast_replace_to(
        CHANNEL,
        target: "board_sync",
        partial: "board/sync",
        locals: cursor
      )
      # Task pages and filtered board clients use a fresh, user-specific
      # morph. The cursor above lets the board detect missed or reordered
      # frames before trusting that refresh.
      Turbo::StreamsChannel.broadcast_refresh_to(CHANNEL)
      Turbo::StreamsChannel.broadcast_replace_to(
        CHANNEL,
        target: "projects",
        partial: "status/projects",
        locals: { projects: StatusVisibility.projects(payload) }
      )
    end

    def reset_stream!
      @stream_epoch = SecureRandom.uuid
      @stream_generation = 0
    end

    def advance_stream!
      cursor = stream_cursor
      @stream_generation = cursor.fetch(:generation) + 1
      { epoch: cursor.fetch(:epoch), generation: @stream_generation }
    end
  end
end
