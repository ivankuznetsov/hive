require "test_helper"
require "support/status_channel_stream_lifecycle_contract"

class UnfencedStreamLifecycleChannel < Turbo::StreamsChannel
  def stream_from(broadcasting, callback = nil, coder: nil, &block)
    ActionCable::Channel::Streams.instance_method(:stream_from).bind_call(
      self,
      broadcasting,
      callback,
      coder: coder,
      &block
    )
  end
end

class ControlledStreamLifecycleFixture
  attr_reader :connection, :confirmations, :raw_unsubscribes

  def initialize(pause_subscribe: false)
    @posted = Queue.new
    @entered_subscribe = Queue.new
    @release_subscribe = Queue.new
    @pause_subscribe = pause_subscribe
    @registrations = []
    @raw_unsubscribes = []
    @mutex = Mutex.new
    @confirmations = []

    event_loop = Object.new
    event_loop.define_singleton_method(:post) { |task = nil, &block| @posted << (task || block) }
    event_loop.instance_variable_set(:@posted, @posted)

    pubsub = Object.new
    fixture = self
    pubsub.define_singleton_method(:subscribe) do |broadcasting, handler, callback|
      fixture.enter_subscribe
      fixture.wait_for_subscribe_release if fixture.pause_subscribe?
      fixture.register(broadcasting, handler)
      callback.call
    end
    pubsub.define_singleton_method(:unsubscribe) do |broadcasting, handler|
      fixture.unregister(broadcasting, handler)
    end

    server = Struct.new(:event_loop).new(event_loop)
    @connection = Object.new
    @connection.define_singleton_method(:server) { server }
    @connection.define_singleton_method(:pubsub) { pubsub }
    @connection.define_singleton_method(:identifiers) { [] }
    @connection.define_singleton_method(:logger) { Rails.logger }
    @connection.define_singleton_method(:transmit) { |frame| fixture.record_confirmation(frame) }
  end

  def pause_subscribe?
    @pause_subscribe
  end

  def enter_subscribe
    @entered_subscribe << true
  end

  def wait_for_subscribe_release
    @release_subscribe.pop
  end

  def await_subscribe
    Timeout.timeout(5) { @entered_subscribe.pop }
  end

  def release_subscribe
    @release_subscribe << true
  end

  def run_next_posted
    Timeout.timeout(5) { @posted.pop.call }
  end

  def drain_posted
    @posted.pop(true).call until @posted.empty?
  end

  def register(broadcasting, handler)
    @mutex.synchronize { @registrations << [ broadcasting, handler ] }
  end

  def unregister(broadcasting, handler)
    @mutex.synchronize do
      @raw_unsubscribes << [ broadcasting, handler ]
      @registrations.delete([ broadcasting, handler ])
    end
  end

  def registrations
    @mutex.synchronize { @registrations.dup }
  end

  def record_confirmation(frame)
    @confirmations << frame if frame[:type] == ActionCable::INTERNAL[:message_types][:confirmation]
  end
end

class StatusChannelAsyncStreamLifecycleTest < ActiveSupport::TestCase
  include ActionCableStreamLifecycleContract

  private

  def stream_lifecycle_channel_class
    StatusChannel
  end

  def stream_lifecycle_adapter_name
    "async"
  end

  def stream_lifecycle_pending_entries(channel)
    channel.instance_variable_get(:@status_stream_attempts).to_a
  end
end

class StatusChannelTest < ActionCable::Channel::TestCase
  STRESS_ITERATIONS = Integer(ENV.fetch("STATUS_CHANNEL_STRESS_ITERATIONS", "0"), 10)
  STRESS_SEED = Integer(ENV.fetch("STATUS_CHANNEL_STRESS_SEED", Random.new_seed.to_s), 10)

  raise ArgumentError, "STATUS_CHANNEL_STRESS_ITERATIONS must not be negative" if STRESS_ITERATIONS.negative?

  test "a verified stream owns one broadcaster subscription for its lifetime" do
    connected = 0
    disconnected = 0
    signed_name = Turbo::StreamsChannel.signed_stream_name([ StatusBroadcaster::CHANNEL ])

    with_replaced_singleton_method(StatusBroadcaster, :subscriber_connected!, -> { connected += 1 }) do
      with_replaced_singleton_method(StatusBroadcaster, :subscriber_disconnected!, -> { disconnected += 1 }) do
        subscribe signed_stream_name: signed_name

        assert subscription.confirmed?
        assert_equal 1, connected

        unsubscribe
        assert_equal 1, disconnected
      end
    end
  end

  test "a rejected stream never starts background scanning" do
    connected = 0
    disconnected = 0

    with_replaced_singleton_method(StatusBroadcaster, :subscriber_connected!, -> { connected += 1 }) do
      with_replaced_singleton_method(StatusBroadcaster, :subscriber_disconnected!, -> { disconnected += 1 }) do
        subscribe signed_stream_name: "invalid"

        assert subscription.rejected?
        subscription.unsubscribe_from_channel
        assert_equal 0, connected
        assert_equal 0, disconnected,
                     "teardown for a rejected stream must not release a valid page's ownership"
      end
    end
  end

  test "a broadcaster startup failure rejects the channel and a later subscription recovers" do
    attempts = 0
    disconnected = 0
    signed_name = Turbo::StreamsChannel.signed_stream_name([ StatusBroadcaster::CHANNEL ])
    connect = lambda do
      attempts += 1
      raise ThreadError, "cannot create broadcaster" if attempts == 1
    end

    with_replaced_singleton_method(StatusBroadcaster, :subscriber_connected!, connect) do
      with_replaced_singleton_method(StatusBroadcaster, :subscriber_disconnected!, -> { disconnected += 1 }) do
        failed = subscribe signed_stream_name: signed_name
        assert failed.rejected?,
               "startup failure must complete the protocol with a rejection, not a pending channel"
        assert_empty failed.streams,
                     "a rejected startup must not leave a queued pub/sub registration"

        recovered = subscribe signed_stream_name: signed_name
        assert recovered.confirmed?
        assert_equal [ StatusBroadcaster::CHANNEL ], recovered.streams
        recovered.unsubscribe_from_channel
      end
    end

    assert_equal 2, attempts
    assert_equal 1, disconnected,
                 "only the recovered subscription acquired a broadcaster lease"
  end

  test "teardown while stream verification is pending never acquires a broadcaster lease" do
    connected = 0
    disconnected = 0
    entered_verification = Queue.new
    release_verification = Queue.new
    signed_name = Turbo::StreamsChannel.signed_stream_name([ StatusBroadcaster::CHANNEL ])
    original = StatusChannel.instance_method(:verified_stream_name_from_params)
    blocked_verification = proc do
      entered_verification << true
      release_verification.pop
      original.bind_call(self)
    end
    worker = nil
    released = false

    with_replaced_singleton_method(StatusBroadcaster, :subscriber_connected!, -> { connected += 1 }) do
      with_replaced_singleton_method(StatusBroadcaster, :subscriber_disconnected!, -> { disconnected += 1 }) do
        with_replaced_instance_method(StatusChannel, :verified_stream_name_from_params, blocked_verification) do
          worker = Thread.new { subscribe signed_stream_name: signed_name }
          Timeout.timeout(5) { entered_verification.pop }
          subscription.unsubscribe_from_channel
          release_verification << true
          released = true
          worker.value
        end
      end
    end

    assert_equal 0, connected
    assert_equal 0, disconnected
  ensure
    release_verification << true unless released
    worker&.join(1)
  end

  test "teardown removes an adapter stream whose deferred registration finishes late" do
    posted = Queue.new
    entered_subscribe = Queue.new
    release_subscribe = Queue.new
    registrations = []
    registration_mutex = Mutex.new
    event_loop = Object.new
    event_loop.define_singleton_method(:post) { |task = nil, &block| posted << (task || block) }
    pubsub = Object.new
    pubsub.define_singleton_method(:subscribe) do |broadcasting, handler, callback|
      entered_subscribe << true
      release_subscribe.pop
      registration_mutex.synchronize { registrations << [ broadcasting, handler ] }
      callback.call
    end
    pubsub.define_singleton_method(:unsubscribe) do |broadcasting, handler|
      registration_mutex.synchronize { registrations.delete([ broadcasting, handler ]) }
    end
    server = Struct.new(:event_loop).new(event_loop)
    connection = Object.new
    connection.define_singleton_method(:server) { server }
    connection.define_singleton_method(:pubsub) { pubsub }
    connection.define_singleton_method(:identifiers) { [] }
    connection.define_singleton_method(:logger) { Rails.logger }
    channel = StatusChannel.new(connection, "status-race", {})
    worker = nil
    released = false

    channel.stream_from(StatusBroadcaster::CHANNEL)
    worker = Thread.new { Timeout.timeout(5) { posted.pop.call } }
    Timeout.timeout(5) { entered_subscribe.pop }
    channel.unsubscribe_from_channel
    release_subscribe << true
    released = true
    worker.value
    Timeout.timeout(5) { posted.pop.call }

    assert_empty registration_mutex.synchronize { registrations.dup },
                 "a registration completed after teardown must unsubscribe itself"
  ensure
    release_subscribe << true unless released
    worker&.join(1)
  end

  test "the application fence prevents registration after teardown before deferred start" do
    unfenced, unfenced_fixture = exercise_teardown_before_deferred_start(UnfencedStreamLifecycleChannel)

    assert_predicate unfenced, :unsubscribed?
    assert_equal 1, unfenced_fixture.registrations.length,
                 "negative control must expose the framework's late registration"
    assert_equal 1, unfenced_fixture.confirmations.length,
                 "negative control must expose confirmation after teardown"

    fenced, fenced_fixture = exercise_teardown_before_deferred_start(StatusChannel)

    assert_predicate fenced, :unsubscribed?
    assert_empty fenced_fixture.registrations
    assert_empty fenced_fixture.confirmations
    assert_empty fenced_fixture.raw_unsubscribes,
                 "queued cancellation must not issue an ineffective adapter unsubscribe"
    assert_empty pending_stream_attempts(fenced)
  end

  test "the application fence removes registration completed after teardown" do
    unfenced, unfenced_fixture = exercise_teardown_during_registration(UnfencedStreamLifecycleChannel)

    assert_predicate unfenced, :unsubscribed?
    assert_equal 1, unfenced_fixture.registrations.length,
                 "negative control must expose the framework's stranded registration"
    assert_equal 1, unfenced_fixture.confirmations.length,
                 "negative control must expose confirmation after teardown"

    fenced, fenced_fixture = exercise_teardown_during_registration(StatusChannel)

    assert_predicate fenced, :unsubscribed?
    assert_empty fenced_fixture.registrations
    assert_empty fenced_fixture.confirmations
    assert_equal 1, fenced_fixture.raw_unsubscribes.length,
                 "a handler that registered after teardown must have one cleanup owner"
    assert_empty pending_stream_attempts(fenced)
  end

  test "targeted stop cancels queued work without raw unsubscribe" do
    fixture = ControlledStreamLifecycleFixture.new
    channel = StatusChannel.new(fixture.connection, "targeted-queued", {})
    channel.stream_from("targeted-queued")
    channel.send(:ensure_confirmation_sent)

    channel.stop_stream_from("targeted-queued")
    channel.stop_stream_from("targeted-queued")
    fixture.run_next_posted

    assert_empty fixture.registrations
    assert_empty fixture.raw_unsubscribes
    assert_empty channel.send(:streams)
    assert_empty pending_stream_attempts(channel)
  end

  test "targeted stop during registration waits to unsubscribe the real handler once" do
    fixture = ControlledStreamLifecycleFixture.new(pause_subscribe: true)
    channel = StatusChannel.new(fixture.connection, "targeted-registering", {})
    channel.stream_from("targeted-registering")
    channel.send(:ensure_confirmation_sent)
    worker = Thread.new { fixture.run_next_posted }
    fixture.await_subscribe

    channel.stop_stream_from("targeted-registering")
    channel.stop_stream_from("targeted-registering")
    assert_empty fixture.raw_unsubscribes

    fixture.release_subscribe
    worker.value
    fixture.drain_posted

    assert_empty fixture.registrations
    assert_equal 1, fixture.raw_unsubscribes.length
    assert_empty fixture.confirmations
    assert_empty channel.send(:streams)
    assert_empty pending_stream_attempts(channel)
  ensure
    fixture&.release_subscribe if worker&.alive?
    worker&.join(1)
  end

  test "global stop cancels every queued attempt without raw unsubscribe" do
    fixture = ControlledStreamLifecycleFixture.new
    channel = StatusChannel.new(fixture.connection, "global-queued", {})
    channel.stream_from("global-one")
    channel.stream_from("global-two")
    channel.send(:ensure_confirmation_sent)

    channel.stop_all_streams
    channel.stop_all_streams
    2.times { fixture.run_next_posted }

    assert_empty fixture.registrations
    assert_empty fixture.raw_unsubscribes
    assert_empty channel.send(:streams)
    assert_empty pending_stream_attempts(channel)
  end

  test "a later registered stream resolves confirmation after targeted pending cancellation" do
    fixture = ControlledStreamLifecycleFixture.new
    channel = StatusChannel.new(fixture.connection, "targeted-recovery", {})
    channel.stream_from("cancelled-stream")
    channel.send(:ensure_confirmation_sent)
    channel.stop_stream_from("cancelled-stream")
    channel.stream_from("replacement-stream")

    2.times { fixture.run_next_posted }

    assert_equal [ "replacement-stream" ], fixture.registrations.map(&:first)
    assert_empty fixture.raw_unsubscribes
    assert_equal 1, fixture.confirmations.length
    assert_equal [ "replacement-stream" ], channel.send(:streams).keys
    assert_empty pending_stream_attempts(channel)
  ensure
    channel&.unsubscribe_from_channel
  end

  test "targeted stop winning an adapter failure suppresses reconnect" do
    posted = Queue.new
    entered_subscribe = Queue.new
    release_subscribe = Queue.new
    raw_unsubscribes = []
    close_calls = []
    confirmations = []
    event_loop = Object.new
    event_loop.define_singleton_method(:post) { |task = nil, &block| posted << (task || block) }
    pubsub = Object.new
    pubsub.define_singleton_method(:subscribe) do |*_args|
      entered_subscribe << true
      release_subscribe.pop
      raise ActiveRecord::ConnectionNotEstablished, "adapter stopped with the stream"
    end
    pubsub.define_singleton_method(:unsubscribe) { |*args| raw_unsubscribes << args }
    server = Struct.new(:event_loop).new(event_loop)
    connection = Object.new
    connection.define_singleton_method(:server) { server }
    connection.define_singleton_method(:pubsub) { pubsub }
    connection.define_singleton_method(:identifiers) { [] }
    connection.define_singleton_method(:logger) { Rails.logger }
    connection.define_singleton_method(:close) { |**options| close_calls << options }
    connection.define_singleton_method(:transmit) { |frame| confirmations << frame }
    channel = StatusChannel.new(connection, "stopped-failure", {})
    channel.stream_from("stopped-failure")
    channel.send(:ensure_confirmation_sent)
    worker = Thread.new { Timeout.timeout(5) { posted.pop.call } }
    Timeout.timeout(5) { entered_subscribe.pop }

    channel.stop_stream_from("stopped-failure")
    release_subscribe << true
    worker.value
    Timeout.timeout(5) { posted.pop.call }

    assert_empty raw_unsubscribes
    assert_empty close_calls
    assert_empty confirmations
    assert_empty channel.send(:streams)
    assert_empty pending_stream_attempts(channel)
  ensure
    release_subscribe << true if worker&.alive?
    worker&.join(1)
  end

  test "a deferred adapter failure releases its lease and reconnects the transport" do
    posted = Queue.new
    close_calls = []
    raw_unsubscribes = []
    connected = 0
    disconnected = 0
    event_loop = Object.new
    event_loop.define_singleton_method(:post) { |task = nil, &block| posted << (task || block) }
    pubsub = Object.new
    pubsub.define_singleton_method(:subscribe) do |*_args|
      raise ActiveRecord::ConnectionNotEstablished, "cable database unavailable"
    end
    pubsub.define_singleton_method(:unsubscribe) { |*args| raw_unsubscribes << args }
    server = Struct.new(:event_loop).new(event_loop)
    connection = Object.new
    connection.define_singleton_method(:server) { server }
    connection.define_singleton_method(:pubsub) { pubsub }
    connection.define_singleton_method(:identifiers) { [] }
    connection.define_singleton_method(:logger) { Rails.logger }
    connection.define_singleton_method(:close) { |**options| close_calls << options }
    channel = StatusChannel.new(connection, "status-failure", {})

    with_replaced_singleton_method(StatusBroadcaster, :subscriber_connected!, -> { connected += 1 }) do
      with_replaced_singleton_method(StatusBroadcaster, :subscriber_disconnected!, -> { disconnected += 1 }) do
        channel.send(:begin_status_subscription!)
        channel.send(:activate_status_subscription!, StatusBroadcaster::CHANNEL)
        Timeout.timeout(5) { posted.pop.call }
        Timeout.timeout(5) { posted.pop.call }
        channel.unsubscribe_from_channel
      end
    end

    assert_equal 1, connected
    assert_equal 1, disconnected
    assert_equal [ {
      reason: ActionCable::INTERNAL[:disconnect_reasons][:server_restart],
      reconnect: true
    } ], close_calls
    assert_empty raw_unsubscribes
    assert_empty channel.send(:streams)
    assert_empty pending_stream_attempts(channel)
    assert_equal :closed, channel.instance_variable_get(:@status_subscription_state)
  end

  test "the lifecycle fence private Action Cable dependencies retain their call shape" do
    required_private_methods = %i[
      worker_pool_stream_handler
      defer_subscription_confirmation!
      ensure_confirmation_sent
      streams
    ]
    required_private_methods.each do |method_name|
      assert StatusChannel.private_method_defined?(method_name),
             "Action Cable private API changed: StatusChannel requires ##{method_name}"
    end

    [
      ActionCable::SubscriptionAdapter::Async,
      ActionCable::SubscriptionAdapter::SolidCable
    ].each do |adapter_class|
      subscribe = adapter_class.instance_method(:subscribe)
      minimum_arity = subscribe.arity.negative? ? -subscribe.arity - 1 : subscribe.arity
      accepts_success_callback = minimum_arity <= 3 && subscribe.arity != 2

      assert accepts_success_callback,
             "Action Cable adapter API changed: #{adapter_class}#subscribe must accept " \
             "(broadcasting, handler, success_callback)"
    end
  end

  if STRESS_ITERATIONS.positive?
    test "bounded stress repeats both teardown windows" do
      windows = {
        before_deferred_start: -> { exercise_teardown_before_deferred_start(StatusChannel) },
        during_registration: -> { exercise_teardown_during_registration(StatusChannel) }
      }
      windows.each_key do |window|
        puts "StatusChannel stress adapter=controlled window=#{window} " \
          "iterations=#{STRESS_ITERATIONS} seed=#{STRESS_SEED}"
      end
      random = Random.new(STRESS_SEED)

      STRESS_ITERATIONS.times do |iteration|
        windows.keys.shuffle(random: random).each do |window|
          channel, fixture = windows.fetch(window).call
          assert_empty fixture.registrations
          assert_empty fixture.confirmations
          assert_empty channel.send(:streams)
          assert_empty pending_stream_attempts(channel)
          expected_unsubscribes = window == :during_registration ? 1 : 0
          assert_equal expected_unsubscribes, fixture.raw_unsubscribes.length
        rescue Exception
          warn "StatusChannel stress failed adapter=controlled window=#{window} " \
            "iteration=#{iteration + 1}/#{STRESS_ITERATIONS} seed=#{STRESS_SEED}"
          raise
        end
      end
    end
  end

  test "repeated concurrent teardown releases each channel lease exactly once" do
    connected = 0
    disconnected = 0
    counter_mutex = Mutex.new
    signed_name = Turbo::StreamsChannel.signed_stream_name([ StatusBroadcaster::CHANNEL ])
    connect = -> { counter_mutex.synchronize { connected += 1 } }
    disconnect = -> { counter_mutex.synchronize { disconnected += 1 } }

    with_replaced_singleton_method(StatusBroadcaster, :subscriber_connected!, connect) do
      with_replaced_singleton_method(StatusBroadcaster, :subscriber_disconnected!, disconnect) do
        first = subscribe signed_stream_name: signed_name
        second = subscribe signed_stream_name: signed_name

        Array.new(2) { Thread.new { first.unsubscribe_from_channel } }.each(&:value)

        assert_equal 2, connected
        assert_equal 1, disconnected,
                     "duplicate cleanup must leave the second channel's lease intact"

        second.unsubscribe_from_channel
        assert_equal 2, disconnected
      end
    end
  end

  test "a confirmed stale page receives one targeted Turbo refresh" do
    signed_name = Turbo::StreamsChannel.signed_stream_name([ StatusBroadcaster::CHANNEL ])

    with_replaced_singleton_method(StatusBroadcaster, :subscriber_connected!, -> { }) do
      with_replaced_singleton_method(StatusBroadcaster, :subscriber_disconnected!, -> { }) do
        with_replaced_singleton_method(StatusBroadcaster, :current_version?, ->(_version) { false }) do
          subscribe signed_stream_name: signed_name
          perform :catch_up, status_version: "page-token", refresh_attempted: false

          assert_equal [ '<turbo-stream action="refresh" data-status-catch-up-for="page-token"></turbo-stream>' ],
                       transmissions
        end
      end
    end
  end

  test "a mismatched worker cannot request a second refresh for the same page token" do
    signed_name = Turbo::StreamsChannel.signed_stream_name([ StatusBroadcaster::CHANNEL ])

    with_replaced_singleton_method(StatusBroadcaster, :subscriber_connected!, -> { }) do
      with_replaced_singleton_method(StatusBroadcaster, :subscriber_disconnected!, -> { }) do
        with_replaced_singleton_method(StatusBroadcaster, :current_version?, ->(_version) { false }) do
          subscribe signed_stream_name: signed_name
          perform :catch_up, status_version: "worker-a-token", refresh_attempted: true

          assert_empty transmissions,
                       "a lagging Cable worker must not refresh-loop a page rendered by a newer HTTP worker"
        end
      end
    end
  end

  test "the targeted refresh escapes an untrusted page token" do
    tag = StatusChannel.catch_up_refresh_tag(%(<unsafe data-x="1">))

    assert_equal '<turbo-stream action="refresh" data-status-catch-up-for="&lt;unsafe data-x=&quot;1&quot;&gt;"></turbo-stream>',
                 tag
  end

  test "a confirmed current page performs no catch-up work" do
    signed_name = Turbo::StreamsChannel.signed_stream_name([ StatusBroadcaster::CHANNEL ])

    with_replaced_singleton_method(StatusBroadcaster, :subscriber_connected!, -> { }) do
      with_replaced_singleton_method(StatusBroadcaster, :subscriber_disconnected!, -> { }) do
        with_replaced_singleton_method(StatusBroadcaster, :current_version?, ->(_version) { true }) do
          subscribe signed_stream_name: signed_name
          perform :catch_up, status_version: "7"

          assert_empty transmissions
        end
      end
    end
  end

  private

  def pending_stream_attempts(channel)
    channel.instance_variable_get(:@status_stream_attempts) || {}
  end

  def exercise_teardown_before_deferred_start(channel_class)
    fixture = ControlledStreamLifecycleFixture.new
    channel = channel_class.new(fixture.connection, "before-deferred-start", {})
    channel.stream_from(StatusBroadcaster::CHANNEL)
    channel.send(:ensure_confirmation_sent)
    channel.unsubscribe_from_channel
    fixture.run_next_posted
    fixture.drain_posted
    [ channel, fixture ]
  end

  def exercise_teardown_during_registration(channel_class)
    fixture = ControlledStreamLifecycleFixture.new(pause_subscribe: true)
    channel = channel_class.new(fixture.connection, "during-registration", {})
    channel.stream_from(StatusBroadcaster::CHANNEL)
    channel.send(:ensure_confirmation_sent)
    worker = Thread.new { fixture.run_next_posted }
    fixture.await_subscribe
    channel.unsubscribe_from_channel
    fixture.release_subscribe
    worker.value
    fixture.drain_posted
    [ channel, fixture ]
  ensure
    fixture&.release_subscribe if worker&.alive?
    worker&.join(1)
  end

  def with_replaced_instance_method(receiver, name, replacement)
    original = receiver.instance_method(name)
    visibility = if receiver.private_method_defined?(name)
      :private
    elsif receiver.protected_method_defined?(name)
      :protected
    else
      :public
    end
    receiver.define_method(name, replacement)
    receiver.send(visibility, name)
    yield
  ensure
    receiver.define_method(name, original)
    receiver.send(visibility, name)
  end
end
