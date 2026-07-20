# Bridges the gem's StatusFeed poller to Turbo Streams: one background
# subscriber per process watches for snapshot changes and broadcasts a
# replace of the projects frame to every connected dashboard. Pages render
# the same snapshot synchronously on first paint, so the stream only ever
# *updates* what the server already rendered.
require "securerandom"
require "monitor"

class StatusBroadcaster
  CHANNEL = "status".freeze
  BAND_FALLBACK_THRESHOLD = 10

  # Seconds to back off after the subscriber loop dies before resubscribing.
  RETRY_SEC = 5
  STREAM_MONITOR = Monitor.new

  class << self
    # Injectable for tests; one feed per process in production.
    attr_writer :feed

    def feed
      @feed ||= Hive::Web::StatusFeed.new
    end

    def snapshot
      feed.snapshot
    end

    def snapshot_with_cursor
      STREAM_MONITOR.synchronize { [ snapshot, stream_cursor ] }
    end

    def stream_cursor
      STREAM_MONITOR.synchronize do
        @stream_epoch ||= SecureRandom.uuid
        @stream_generation ||= 0
        { epoch: @stream_epoch, generation: @stream_generation }
      end
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
      begin
        @last_payload ||= feed.snapshot
      rescue StandardError => e
        Rails.logger.error("status broadcaster baseline error (#{e.class}: #{e.message}); reconciling first update")
      end
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
      @last_payload = nil
    end

    private

    def broadcast(payload)
      STREAM_MONITOR.synchronize do
        cursor = advance_stream!
        broadcast_board_changes(@last_payload, payload)
        # A refresh action is constant-sized and lets URL-filtered boards,
        # classic grids, task pages, and open drawers each rebuild from their
        # own current URL without shipping the complete projects grid over
        # Cable for every changed card.
        Turbo::StreamsChannel.broadcast_refresh_to(CHANNEL)
        Turbo::StreamsChannel.broadcast_replace_to(
          CHANNEL,
          target: "board_sync",
          partial: "board/sync",
          locals: cursor.merge(refresh_required: true)
        )
        @last_payload = payload
      end
    end

    def broadcast_board_changes(previous, current)
      return true unless previous

      old_bands = bands_by_key(previous)
      new_bands = bands_by_key(current)
      refresh_required = false
      (old_bands.keys | new_bands.keys).each do |key|
        old_band = old_bands[key]
        new_band = new_bands[key]
        unless old_band && new_band
          refresh_required = true
          next
        end

        changes = changed_card_keys(old_band, new_band)
        next if changes.empty?

        if layout_signature(old_band) != layout_signature(new_band) ||
           changes.size >= BAND_FALLBACK_THRESHOLD
          broadcast_band(new_band)
          refresh_required = true
          next
        end

        old_cards = cards_by_slug(old_band)
        new_cards = cards_by_slug(new_band)
        changes.each do |slug|
          old_card = old_cards[slug]
          new_card = new_cards[slug]
          if old_card && new_card && old_card["stage"] == new_card["stage"]
            broadcast_card(new_band.fetch("project"), new_card)
            # A queued transition can leave this card optimistically parked in
            # its requested destination even though canonical stage data has
            # not moved yet. Reconcile the client's URL-specific board after
            # the small card patch so the authoritative column wins.
            refresh_required = true if old_card["queued_request"] != new_card["queued_request"]
          else
            # Adds/removes/moves can alter URL-filter membership and grouping;
            # each client must reconcile its own current URL for those shapes.
            refresh_required = true
          end
        end
      end
      refresh_required
    end

    def bands_by_key(payload)
      StatusVisibility.projects(payload).each_with_object({}) do |project, bands|
        workflows = project.fetch("workflows", []).index_by { |workflow| workflow["id"].to_s }
        project.fetch("tasks", []).group_by { |task| task["workflow"].presence || "coding" }.each do |workflow_id, tasks|
          workflow = workflows[workflow_id.to_s]
          next unless workflow

          bands[[ project["name"], workflow_id.to_s ]] = {
            "project" => project, "workflow" => workflow, "tasks" => tasks
          }
        end
      end
    end

    def cards_by_slug(band)
      band.fetch("tasks").index_by { |task| task.fetch("slug") }
    end

    def changed_card_keys(old_band, new_band)
      old_cards = cards_by_slug(old_band)
      new_cards = cards_by_slug(new_band)
      (old_cards.keys | new_cards.keys).select do |slug|
        old_cards.dig(slug, "card_digest") != new_cards.dig(slug, "card_digest")
      end
    end

    def layout_signature(band)
      band.dig("workflow", "stages").to_a.map { |stage| stage["dir"] }
    end

    def broadcast_card(project, task)
      Turbo::StreamsChannel.broadcast_replace_to(
        CHANNEL,
        target: dom_id("card", project.fetch("name"), task.fetch("slug")),
        method: :morph,
        partial: "board/card",
        locals: { project: project, task: task }
      )
    end

    def broadcast_band(band)
      Turbo::StreamsChannel.broadcast_replace_to(
        CHANNEL,
        target: dom_id("band", band.dig("project", "name"), band.dig("workflow", "id")),
        partial: "board/band",
        locals: { band: band, filters: { "group" => "none" } }
      )
    end

    def dom_id(*parts)
      parts.join("_").parameterize(separator: "_")
    end

    def reset_stream!
      STREAM_MONITOR.synchronize do
        @stream_epoch = SecureRandom.uuid
        @stream_generation = 0
      end
    end

    def advance_stream!
      cursor = stream_cursor
      @stream_generation = cursor.fetch(:generation) + 1
      { epoch: cursor.fetch(:epoch), generation: @stream_generation }
    end
  end
end
