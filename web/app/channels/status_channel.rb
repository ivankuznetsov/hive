class StatusChannel < Turbo::StreamsChannel
  def initialize(...)
    super
    @status_subscription_mutex = Mutex.new
  end

  # The browser calls this only after Action Cable confirms the stream, so no
  # status change can fall into the gap between page render and pub/sub setup.
  # The response is targeted to this subscription; current pages do no work.
  def catch_up(data)
    return unless status_subscribed?
    page_token = data["status_version"].to_s
    return if StatusBroadcaster.current_version?(page_token)
    return if data["refresh_attempted"] == true

    transmit self.class.catch_up_refresh_tag(page_token)
  end

  def self.catch_up_refresh_tag(page_token)
    ApplicationController.helpers.tag.turbo_stream(
      "",
      action: "refresh",
      "data-status-catch-up-for": page_token
    )
  end

  # Action Cable defers adapter registration to its stream executor. A socket
  # can disappear before that work runs; the framework's first unsubscribe then
  # precedes the late subscribe and cannot remove it. Fence both sides of the
  # adapter call, and remove a registration that completes after teardown.
  def stream_from(broadcasting, callback = nil, coder: nil, &block)
    return if unsubscribed?

    broadcasting = String(broadcasting)
    defer_subscription_confirmation!
    handler = worker_pool_stream_handler(broadcasting, callback || block, coder: coder)
    streams[broadcasting] = handler

    connection.server.event_loop.post do
      next if unsubscribed?

      begin
        pubsub.subscribe(broadcasting, handler, lambda do
          if unsubscribed?
            # Some adapters invoke this callback while holding their subscriber
            # mutex. Leave that call before re-entering the adapter for cleanup.
            connection.server.event_loop.post { pubsub.unsubscribe(broadcasting, handler) }
          else
            ensure_confirmation_sent
            logger.info "#{self.class.name} is streaming from #{broadcasting}"
          end
        end)
      rescue StandardError => e
        fail_status_stream!(e)
      end
    end
  end

  private

  def subscribed
    return unless begin_status_subscription!

    stream_name = verified_stream_name_from_params
    unless stream_name
      close_pending_status_subscription!
      reject
      return
    end

    activate_status_subscription!(stream_name)
  end

  def unsubscribed
    release_status_subscription!
  end

  def begin_status_subscription!
    @status_subscription_mutex.synchronize do
      return false if @status_subscription_state

      @status_subscription_state = :pending
      true
    end
  end

  def close_pending_status_subscription!
    @status_subscription_mutex.synchronize do
      @status_subscription_state = :closed if @status_subscription_state == :pending
    end
  end

  def activate_status_subscription!(stream_name)
    @status_subscription_mutex.synchronize do
      return unless @status_subscription_state == :pending

      StatusBroadcaster.subscriber_connected!
      @status_subscription_state = :active
      stream_from stream_name
    rescue StandardError => e
      StatusBroadcaster.subscriber_disconnected! if @status_subscription_state == :active
      @status_subscription_state = :closed
      reject
      Rails.logger.error("status channel startup failed (#{e.class}: #{e.message}); rejecting for client retry")
    end
  end

  def fail_status_stream!(error)
    release_status_subscription!
    Rails.logger.error("status channel stream registration failed (#{error.class}: #{error.message}); reconnecting")
    connection.close(
      reason: ActionCable::INTERNAL[:disconnect_reasons][:server_restart],
      reconnect: true
    )
  rescue StandardError => close_error
    Rails.logger.error("status channel reconnect failed (#{close_error.class}: #{close_error.message})")
  end

  def release_status_subscription!
    active = @status_subscription_mutex.synchronize do
      was_active = @status_subscription_state == :active
      @status_subscription_state = :closed
      was_active
    end
    StatusBroadcaster.subscriber_disconnected! if active
  end

  def status_subscribed?
    @status_subscription_mutex.synchronize { @status_subscription_state == :active }
  end
end
