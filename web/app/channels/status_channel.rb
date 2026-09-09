require "monitor"

class StatusChannel < Turbo::StreamsChannel
  StatusStreamAttempt = Struct.new(
    :broadcasting,
    :handler,
    :state,
    :confirmation_pending,
    :cleanup_claimed,
    keyword_init: true
  )

  class StatusStreamHandler
    attr_reader :attempt

    def initialize(attempt, handler)
      @attempt = attempt
      @handler = handler
    end

    def call(message)
      @handler.call(message)
    end
  end

  private_constant :StatusStreamAttempt, :StatusStreamHandler

  def initialize(...)
    super
    @status_subscription_mutex = Monitor.new
    @status_stream_attempts = {}
    @status_cancelled_confirmation_count = 0
    @status_stream_reconnect_requested = false
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

  # These three overrides are one narrow ownership boundary. Rails 8.1 records
  # a handler before deferred adapter registration, so its stop methods cannot
  # distinguish queued work from a real subscription. Keep pending attempts out
  # of Rails' stream registry until registration succeeds; see the dependency
  # handoff gate in wiki/dependencies.md before removing this fence.
  def stream_from(broadcasting, callback = nil, coder: nil, &block)
    broadcasting = String(broadcasting)
    attempt = nil

    @status_subscription_mutex.synchronize do
      return if unsubscribed?

      defer_subscription_confirmation!
      attempt = StatusStreamAttempt.new(
        broadcasting: broadcasting,
        state: :queued,
        confirmation_pending: true,
        cleanup_claimed: false
      )
      worker_handler = status_worker_stream_handler(attempt, callback || block, coder: coder)
      attempt.handler = StatusStreamHandler.new(attempt, worker_handler)

      if previous = @status_stream_attempts[broadcasting]
        cancel_pending_status_stream_locked(previous)
      end
      @status_stream_attempts[broadcasting] = attempt
    end

    connection.server.event_loop.post do
      register_status_stream(attempt)
    end
  end

  def stop_stream_from(broadcasting)
    broadcasting = String(broadcasting)
    handler = nil

    @status_subscription_mutex.synchronize do
      if attempt = @status_stream_attempts.delete(broadcasting)
        cancel_pending_status_stream_locked(attempt)
      end
      handler = streams.delete(broadcasting)
      close_registered_status_stream_locked(handler) if handler
    end

    unsubscribe_registered_status_stream(broadcasting, handler) if handler
  end

  def stop_all_streams
    handlers = nil

    @status_subscription_mutex.synchronize do
      @status_stream_attempts.each_value do |attempt|
        cancel_pending_status_stream_locked(attempt)
      end
      @status_stream_attempts.clear
      handlers = streams.to_a
      streams.clear
      handlers.each { |_broadcasting, handler| close_registered_status_stream_locked(handler) }
    end

    handlers.each { |broadcasting, handler| unsubscribe_registered_status_stream(broadcasting, handler) }
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

  def status_worker_stream_handler(attempt, user_handler, coder:)
    if user_handler
      guarded_handler = lambda do |message|
        user_handler.call(message) if status_stream_deliverable?(attempt)
      end
      worker_pool_stream_handler(attempt.broadcasting, guarded_handler, coder: coder)
    else
      guarded_transmitter = lambda do |message|
        if status_stream_deliverable?(attempt)
          transmit message, via: "streamed from #{attempt.broadcasting}"
        end
      end
      worker_pool_stream_handler(
        attempt.broadcasting,
        guarded_transmitter,
        coder: coder || ActiveSupport::JSON
      )
    end
  end

  def register_status_stream(attempt)
    should_register = @status_subscription_mutex.synchronize do
      current = @status_stream_attempts[attempt.broadcasting]
      if current.equal?(attempt) && attempt.state == :queued && !unsubscribed?
        attempt.state = :registering
        true
      else
        false
      end
    end
    return unless should_register

    pubsub.subscribe(attempt.broadcasting, attempt.handler, lambda do
      complete_status_stream_registration(attempt)
    rescue StandardError => e
      schedule_status_stream_failure(attempt, e)
    end)
  rescue StandardError => e
    schedule_status_stream_failure(attempt, e)
  end

  def complete_status_stream_registration(attempt)
    cleanup = false
    registered = false
    replaced_handler = nil

    @status_subscription_mutex.synchronize do
      current = @status_stream_attempts[attempt.broadcasting]
      if current.equal?(attempt) && attempt.state == :registering && !unsubscribed?
        @status_stream_attempts.delete(attempt.broadcasting)
        replaced_handler = streams[attempt.broadcasting]
        streams[attempt.broadcasting] = attempt.handler
        attempt.state = :registered
        registered = true
        if attempt.confirmation_pending
          attempt.confirmation_pending = false
          confirmations_to_resolve = @status_cancelled_confirmation_count + 1
          @status_cancelled_confirmation_count = 0
          confirmations_to_resolve.times { ensure_confirmation_sent }
        end
      else
        @status_stream_attempts.delete(attempt.broadcasting) if current.equal?(attempt)
        cleanup = claim_late_status_stream_cleanup_locked(attempt)
      end
    end

    schedule_registered_status_stream_unsubscribe(attempt.broadcasting, replaced_handler) if replaced_handler
    if cleanup
      schedule_registered_status_stream_unsubscribe(attempt.broadcasting, attempt.handler)
    elsif registered
      logger.info "#{self.class.name} is streaming from #{attempt.broadcasting}"
    end
  rescue StandardError => e
    schedule_status_stream_failure(attempt, e)
  end

  def cancel_pending_status_stream_locked(attempt)
    return unless [ :queued, :registering ].include?(attempt.state)

    attempt.state = :cancelled
    if attempt.confirmation_pending
      attempt.confirmation_pending = false
      @status_cancelled_confirmation_count += 1 unless unsubscribed?
    end
  end

  def claim_late_status_stream_cleanup_locked(attempt)
    return false if attempt.cleanup_claimed || attempt.state == :failed

    attempt.cleanup_claimed = true
    attempt.confirmation_pending = false
    attempt.state = :closing
    true
  end

  def close_registered_status_stream_locked(handler)
    attempt = handler.respond_to?(:attempt) ? handler.attempt : nil
    return unless attempt

    attempt.confirmation_pending = false
    attempt.cleanup_claimed = true
    attempt.state = :closed
  end

  def status_stream_deliverable?(attempt)
    @status_subscription_mutex.synchronize do
      attempt.state == :registered &&
        !unsubscribed? &&
        streams[attempt.broadcasting].equal?(attempt.handler)
    end
  end

  def unsubscribe_registered_status_stream(broadcasting, handler)
    pubsub.unsubscribe(broadcasting, handler)
    logger.info "#{self.class.name} stopped streaming from #{broadcasting}"
  end

  def schedule_registered_status_stream_unsubscribe(broadcasting, handler)
    return unless handler

    connection.server.event_loop.post do
      begin
        unsubscribe_registered_status_stream(broadcasting, handler)
      ensure
        @status_subscription_mutex.synchronize do
          close_registered_status_stream_locked(handler)
        end
      end
    end
  end

  def schedule_status_stream_failure(attempt, error)
    connection.server.event_loop.post { fail_status_stream!(attempt, error) }
  end

  def fail_status_stream!(attempt, error)
    handlers = []
    release_lease = false
    reconnect = false

    @status_subscription_mutex.synchronize do
      relevant = @status_stream_attempts[attempt.broadcasting].equal?(attempt) ||
        streams[attempt.broadcasting].equal?(attempt.handler)
      return unless relevant

      @status_stream_attempts.each_value do |pending_attempt|
        pending_attempt.state = pending_attempt.equal?(attempt) ? :failed : :cancelled
        pending_attempt.confirmation_pending = false
      end
      @status_stream_attempts.clear
      @status_cancelled_confirmation_count = 0

      handlers = streams.to_a
      streams.clear
      handlers.each do |_broadcasting, handler|
        registered_attempt = handler.respond_to?(:attempt) ? handler.attempt : nil
        next unless registered_attempt

        registered_attempt.cleanup_claimed = true
        registered_attempt.confirmation_pending = false
        registered_attempt.state = :closing
      end

      release_lease = @status_subscription_state == :active
      @status_subscription_state = :closed
      unless unsubscribed? || @status_stream_reconnect_requested
        @status_stream_reconnect_requested = true
        reconnect = true
      end
    end

    handlers.each do |broadcasting, handler|
      begin
        unsubscribe_registered_status_stream(broadcasting, handler)
      rescue StandardError => unsubscribe_error
        Rails.logger.error(
          "status channel stream cleanup failed " \
          "(#{unsubscribe_error.class}: #{unsubscribe_error.message})"
        )
      ensure
        @status_subscription_mutex.synchronize { close_registered_status_stream_locked(handler) }
      end
    end
    if release_lease
      begin
        StatusBroadcaster.subscriber_disconnected!
      rescue StandardError => lease_error
        Rails.logger.error(
          "status channel lease cleanup failed " \
          "(#{lease_error.class}: #{lease_error.message})"
        )
      end
    end

    Rails.logger.error("status channel stream registration failed (#{error.class}: #{error.message}); reconnecting")
    return unless reconnect

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
