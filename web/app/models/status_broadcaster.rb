# Bridges the gem's StatusFeed poller to Turbo Streams: one background
# subscriber per process watches for snapshot changes and broadcasts a Turbo
# morph refresh. Pages render their selected Board or Grid view synchronously,
# so the current URL and saved preference remain the only view authority.
class StatusBroadcaster
  CHANNEL = "status".freeze
  LIFECYCLE_MUTEX = Mutex.new
  PageSnapshot = Struct.new(
    :payload, :version, :availability, :last_success_at, :error,
    keyword_init: true
  ) do
    def fresh? = availability.nil? || availability == "fresh"
    def degraded? = availability == "degraded"
    def unavailable? = availability == "unavailable"
  end

  # Seconds to back off after the subscriber loop dies before resubscribing.
  RETRY_SEC = 5

  class << self
    def feed
      @feed ||= Hive::Web::StatusFeed.new
    end

    # Injectable for tests; one feed per process in production.
    def feed=(new_feed)
      @feed = new_feed
      @broadcast_pending = false
    end

    def snapshot
      snapshot_with_version.payload
    end

    def snapshot_with_version
      current_feed = feed
      if current_feed.respond_to?(:snapshot_state)
        state = current_feed.snapshot_state
        PageSnapshot.new(
          payload: state.payload,
          version: state.token,
          availability: state.availability,
          last_success_at: state.last_success_at,
          error: state.error
        )
      else
        payload = current_feed.snapshot
        PageSnapshot.new(payload:, version: current_feed.prime(payload))
      end
    end

    # Non-scanning freshness read for task-local routes. A nil result means no
    # status scan has completed in this process yet; the target resolver still
    # resolves the requested registered task directly.
    def current_page_snapshot
      state = feed.respond_to?(:current_state) ? feed.current_state : nil
      return unless state

      PageSnapshot.new(
        payload: state.payload,
        version: state.token,
        availability: state.availability,
        last_success_at: state.last_success_at,
        error: state.error
      )
    end

    def current_version?(candidate)
      feed.current_version?(candidate)
    end

    def projects(payload)
      Array(payload && payload["projects"])
             .each_with_index
             .sort_by { |(project, index)| [ -project.fetch("tasks", []).size, index ] }
             .map { |project, _index| Project.new(project) }
    end

    # StatusChannel owns this lifecycle. A server with no open Hive pages has
    # no subscriber and therefore performs no background status scans.
    def subscriber_connected!
      LIFECYCLE_MUTEX.synchronize do
        previous_count = @subscriber_count.to_i
        @subscriber_count = previous_count + 1
        begin
          start_unlocked!
        rescue StandardError
          @subscriber_count = previous_count
          raise
        end
      end
    end

    def subscriber_disconnected!
      LIFECYCLE_MUTEX.synchronize do
        return if @subscriber_count.to_i.zero?

        @subscriber_count -= 1
        stop_unlocked! if @subscriber_count.zero?
      end
    end

    def stop!
      LIFECYCLE_MUTEX.synchronize do
        @subscriber_count = 0
        stop_unlocked!
      end
    end

    private

    def start_unlocked!
      # Self-healing by construction: a raising broadcast (a solid_cable
      # hiccup, one bad row blowing up the partial render) must not silently
      # freeze live updates forever. Discard a dead subscriber thread before
      # recreating it for the still-connected channel owner.
      @thread = nil unless @thread&.alive?
      @thread ||= Thread.new do
        Thread.current.name = "status-broadcaster"
        skip_initial = !@broadcast_pending
        loop do
          begin
            # The subscribing page already rendered the first snapshot. Use
            # it as the comparison baseline instead of forcing an immediate
            # duplicate refresh; after an error, the current value is retried.
            current_feed = feed
            subscription = current_feed.respond_to?(:each_state) ? :each_state : :each_snapshot
            current_feed.public_send(subscription) do |publication|
              payload = publication.respond_to?(:payload) ? publication.payload : publication
              if skip_initial
                skip_initial = false
              else
                # Keep this bit across last-subscriber shutdown. If delivery
                # raises and the retrying thread is stopped, its replacement
                # must retry the current feed value rather than skip it as a
                # freshly rendered page baseline.
                @broadcast_pending = true
                broadcast(payload)
                @broadcast_pending = false
              end
            end
          rescue StandardError => e
            Rails.logger.error("status broadcaster error (#{e.class}: #{e.message}); resubscribing in #{RETRY_SEC}s")
            sleep RETRY_SEC
          end
        end
      end
    end

    def stop_unlocked!
      thread = @thread
      @thread = nil
      thread&.kill
      thread&.join
      # The broadcaster can lazily install @feed while shutdown is beginning.
      # Read it only after the thread is gone so that nested poller is never
      # missed by a stale pre-kill snapshot.
      @feed&.stop
    end

    def broadcast(payload)
      sorted_projects = projects(payload)
      # Render the complete multi-action message before its ONE Cable send.
      # A bad partial therefore fails before any page sees the refresh action;
      # the retry cannot create a five-second full-page request loop by
      # repeatedly delivering only the first half of an update.
      Turbo::StreamsChannel.broadcast_render_to(
        CHANNEL,
        partial: "status/broadcast",
        locals: { projects: sorted_projects }
      )
    end
  end
end
