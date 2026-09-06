require "set"
require "stringio"
require "timeout"

# Shared behavior for any channel class that owns Action Cable stream lifecycle.
# The including test supplies the channel class and adapter name; this contract
# deliberately observes public stream behavior rather than a scheduling mechanism.
module ActionCableStreamLifecycleContract
  extend ActiveSupport::Concern

  WAIT_TIMEOUT = 5

  class ObservedAdapter
    attr_reader :events

    def initialize(adapter)
      @adapter = adapter
      @events = Queue.new
      @recorded_events = []
      @mutex = Mutex.new
      @fail_next_subscribe = false
    end

    def broadcast(...)
      @adapter.broadcast(...)
    end

    def subscribe(broadcasting, handler, success_callback = nil)
      failure = @mutex.synchronize do
        next false unless @fail_next_subscribe

        @fail_next_subscribe = false
        true
      end
      if failure
        record([ :subscribe_failed, broadcasting, handler ])
        raise ActiveRecord::ConnectionNotEstablished, "injected adapter subscription failure"
      end

      @adapter.subscribe(broadcasting, handler, lambda do
        success_callback&.call
        record([ :registered, broadcasting, handler ])
      end)
    end

    def unsubscribe(broadcasting, handler)
      record([ :unsubscribed, broadcasting, handler ])
      @adapter.unsubscribe(broadcasting, handler)
    end

    def shutdown
      @adapter.shutdown
    end

    def fail_next_subscribe!
      @mutex.synchronize { @fail_next_subscribe = true }
    end

    def recorded_events
      @mutex.synchronize { @recorded_events.dup }
    end

    private

    def record(event)
      @mutex.synchronize { @recorded_events << event }
      @events << event
    end
  end

  Environment = Struct.new(
    :server,
    :connection,
    :adapter,
    :frames,
    :frame_events,
    :close_calls,
    :close_events,
    :channels,
    :initialized_channels,
    keyword_init: true
  )

  included do
    test "real adapter confirms registration and preserves the default transmit path" do
      with_stream_lifecycle_environment do |environment|
        channel = build_stream_lifecycle_channel(environment)
        start_stream(environment, channel, "contract-default")

        confirmation = await_frame(environment, channel) { |frame| frame[:type] == confirmation_type }
        assert_equal channel.identifier, confirmation[:identifier]

        environment.server.broadcast("contract-default", { "kind" => "default" })
        payload = await_frame(environment, channel) { |frame| frame[:message] == { "kind" => "default" } }
        assert_equal({ "kind" => "default" }, payload[:message])
      end
    end

    test "real adapter preserves explicit callbacks, blocks, and coders" do
      with_stream_lifecycle_environment do |environment|
        channel = build_stream_lifecycle_channel(environment)
        callback_payloads = Queue.new
        block_payloads = Queue.new
        decoder = Object.new
        decoder.define_singleton_method(:decode) { |payload| "decoded:#{payload}" }

        start_stream(environment, channel, "contract-callback", ->(payload) { callback_payloads << payload })
        start_stream(environment, channel, "contract-coded", coder: decoder) { |payload| block_payloads << payload }

        environment.server.broadcast("contract-callback", "callback-payload", coder: nil)
        environment.server.broadcast("contract-coded", "coded-payload", coder: nil)

        assert_equal "callback-payload", await_queue(callback_payloads, environment, channel, "explicit callback")
        assert_equal "decoded:coded-payload", await_queue(block_payloads, environment, channel, "coded block")
      end
    end

    test "real adapter targeted and global stops unsubscribe registered handlers once" do
      with_stream_lifecycle_environment do |environment|
        channel = build_stream_lifecycle_channel(environment)
        start_stream(environment, channel, "contract-targeted")
        start_stream(environment, channel, "contract-global")

        channel.stop_stream_from("contract-targeted")
        channel.stop_stream_from("contract-targeted")
        assert_equal 1, unsubscribe_count(environment, "contract-targeted")

        channel.stop_all_streams
        channel.stop_all_streams
        assert_equal 1, unsubscribe_count(environment, "contract-global")
        assert_empty channel.send(:streams)
      end
    end

    test "real adapter teardown removes the handler and suppresses later payloads" do
      with_stream_lifecycle_environment do |environment|
        channel = build_stream_lifecycle_channel(environment)
        control = build_stream_lifecycle_channel(environment)
        start_stream(environment, channel, "contract-teardown")
        start_stream(environment, control, "contract-control")

        channel.unsubscribe_from_channel
        environment.server.broadcast("contract-teardown", { "kind" => "forbidden" })
        environment.server.broadcast("contract-control", { "kind" => "control" })
        await_frame(environment, control) { |frame| frame[:message] == { "kind" => "control" } }

        assert_equal 1, unsubscribe_count(environment, "contract-teardown")
        assert_empty channel.send(:streams)
        refute environment.frames.any? { |frame| frame[:message] == { "kind" => "forbidden" } }
      end
    end

    test "real adapter subscription failure leaves clean state and later recovers" do
      with_stream_lifecycle_environment do |environment|
        environment.adapter.fail_next_subscribe!
        failed_channel = build_stream_lifecycle_channel(environment)
        begin_stream(environment, failed_channel, "contract-failure")

        close = await_close(environment, failed_channel)
        assert_equal true, close[:reconnect]
        assert_equal ActionCable::INTERNAL[:disconnect_reasons][:server_restart], close[:reason]
        assert_empty failed_channel.send(:streams)
        assert_empty stream_lifecycle_pending_entries(failed_channel)
        assert_empty environment.frames.select { |frame| frame[:type] == confirmation_type }
        assert_equal 1, environment.close_calls.length

        recovered_channel = build_stream_lifecycle_channel(environment)
        start_stream(environment, recovered_channel, "contract-recovery")
        environment.server.broadcast("contract-recovery", { "kind" => "recovered" })
        recovered = await_frame(environment, recovered_channel) do |frame|
          frame[:message] == { "kind" => "recovered" }
        end
        assert_equal({ "kind" => "recovered" }, recovered[:message])
      end
    end
  end

  private

  def with_stream_lifecycle_environment
    environment = build_stream_lifecycle_environment
    yield environment
  ensure
    shutdown_stream_lifecycle_environment(environment) if environment
  end

  def build_stream_lifecycle_environment
    logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(StringIO.new))
    configuration = ActionCable::Server::Configuration.new
    configuration.logger = logger
    configuration.cable = { "adapter" => stream_lifecycle_adapter_name }
    configuration.filter_parameters = []
    configuration.worker_pool_size = 1

    server = ActionCable::Server::Base.new(config: configuration)
    real_adapter = server.pubsub
    observed_adapter = ObservedAdapter.new(real_adapter)
    server.instance_variable_set(:@pubsub, observed_adapter)

    frames = []
    frame_events = Queue.new
    close_calls = []
    close_events = Queue.new
    connection = ActionCable::Connection::Base.new(server, {})
    connection.define_singleton_method(:transmit) do |frame|
      recorded = frame.with_indifferent_access
      frames << recorded
      frame_events << recorded
    end
    connection.define_singleton_method(:close) do |**options|
      close_calls << options
      close_events << options
    end

    Environment.new(
      server: server,
      connection: connection,
      adapter: observed_adapter,
      frames: frames,
      frame_events: frame_events,
      close_calls: close_calls,
      close_events: close_events,
      channels: [],
      initialized_channels: Set.new
    )
  end

  def build_stream_lifecycle_channel(environment)
    stream_lifecycle_channel_class.new(
      environment.connection,
      "lifecycle-contract-#{environment.channels.length}",
      {}
    ).tap { |channel| environment.channels << channel }
  end

  def start_stream(environment, channel, broadcasting, callback = nil, coder: nil, &block)
    begin_stream(environment, channel, broadcasting, callback, coder: coder, &block)
    await_adapter_event(environment, channel, :registered, broadcasting)
  end

  def begin_stream(environment, channel, broadcasting, callback = nil, coder: nil, &block)
    channel.stream_from(broadcasting, callback, coder: coder, &block)
    unless environment.initialized_channels.include?(channel.object_id)
      environment.initialized_channels << channel.object_id
      channel.send(:ensure_confirmation_sent)
    end
  end

  def await_adapter_event(environment, channel, kind, broadcasting)
    Timeout.timeout(WAIT_TIMEOUT) do
      loop do
        event = environment.adapter.events.pop
        return event if event.first == kind && event[1] == broadcasting
      end
    end
  rescue Timeout::Error
    flunk lifecycle_timeout_message(environment, channel, "adapter #{kind} for #{broadcasting.inspect}")
  end

  def await_frame(environment, channel)
    Timeout.timeout(WAIT_TIMEOUT) do
      loop do
        frame = environment.frame_events.pop
        return frame if yield(frame)
      end
    end
  rescue Timeout::Error
    flunk lifecycle_timeout_message(environment, channel, "matching Action Cable frame")
  end

  def await_queue(queue, environment, channel, label)
    Timeout.timeout(WAIT_TIMEOUT) { queue.pop }
  rescue Timeout::Error
    flunk lifecycle_timeout_message(environment, channel, label)
  end

  def await_close(environment, channel)
    Timeout.timeout(WAIT_TIMEOUT) { environment.close_events.pop }
  rescue Timeout::Error
    flunk lifecycle_timeout_message(environment, channel, "transport reconnect")
  end

  def unsubscribe_count(environment, broadcasting)
    environment.adapter.recorded_events.count do |kind, name, _handler|
      kind == :unsubscribed && name == broadcasting
    end
  end

  def confirmation_type
    ActionCable::INTERNAL[:message_types][:confirmation]
  end

  def lifecycle_timeout_message(environment, channel, awaited)
    "timed out waiting for #{awaited}; streams=#{channel.send(:streams).keys.inspect} " \
      "adapter_events=#{environment.adapter.recorded_events.inspect} " \
      "frames=#{environment.frames.inspect} closes=#{environment.close_calls.inspect}"
  end

  def shutdown_stream_lifecycle_environment(environment)
    environment.channels.reverse_each do |channel|
      channel.unsubscribe_from_channel unless channel.unsubscribed?
    rescue StandardError
      # Preserve the original assertion while still shutting down adapter threads.
    end
    environment.adapter.shutdown
    environment.server.worker_pool.halt
    environment.server.worker_pool.executor.wait_for_termination(WAIT_TIMEOUT)
    event_loop = environment.server.event_loop
    event_loop.stop
    event_loop.instance_variable_get(:@thread)&.join(WAIT_TIMEOUT)
  end
end
