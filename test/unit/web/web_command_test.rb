require "test_helper"
require "hive/commands/web"

# Unit coverage for `hive web`'s command object: the SSE cap must be derived
# strictly below the Puma thread pool, `call` must wire bind/port into a Puma
# server, and the public-bind warning must fire only for an unguarded 0.0.0.0
# bind without an https origin.
class WebCommandTest < Minitest::Test
  include HiveTestHelper

  # Records the args `call` passes to Puma and stands in for the running
  # server so the test never opens a socket or blocks on `run.join`.
  class FakePumaServer
    class << self
      attr_accessor :last
    end

    attr_reader :app, :options, :listener

    def initialize(app, _events, options)
      @app = app
      @options = options
      self.class.last = self
    end

    def add_tcp_listener(bind, port)
      @listener = [ bind, port ]
    end

    def run
      Thread.new { nil } # returns immediately; `join` is a no-op
    end
  end

  def with_fake_puma
    # Pre-require puma so `require "puma"` in `call` is a no-op, then swap the
    # Server class for the recorder. Restored afterward.
    require "puma"
    original = Puma.const_get(:Server)
    Puma.send(:remove_const, :Server)
    Puma.const_set(:Server, FakePumaServer)
    yield
  ensure
    Puma.send(:remove_const, :Server)
    Puma.const_set(:Server, original)
  end

  def test_sse_cap_is_below_thread_pool
    assert_operator Hive::Commands::Web::MAX_SSE_STREAMS, :<, Hive::Commands::Web::MAX_THREADS
    assert_equal Hive::Commands::Web::MAX_THREADS - Hive::Commands::Web::SSE_THREAD_HEADROOM,
                 Hive::Commands::Web::MAX_SSE_STREAMS
  end

  def test_call_binds_and_runs_a_puma_server
    with_tmp_global_config do
      with_fake_puma do
        out, = capture_io do
          Hive::Commands::Web.new(bind: "127.0.0.1", port: 4599).call
        end

        server = FakePumaServer.last
        assert_equal Hive::Web::App, server.app, "the Puma server must serve the Sinatra app"
        assert_equal Hive::Commands::Web::MAX_THREADS, server.options[:max_threads]
        assert_equal [ "127.0.0.1", 4599 ], server.listener, "explicit bind/port must reach the listener"
        assert_includes out, "listening on http://127.0.0.1:4599"
      end
    end
  end

  def test_call_falls_back_to_config_bind_and_port
    with_tmp_global_config do
      with_fake_puma do
        capture_io { Hive::Commands::Web.new.call }

        # Defaults from load_global_web (127.0.0.1:4567) flow through when no
        # explicit bind/port is given.
        assert_equal [ "127.0.0.1", 4567 ], FakePumaServer.last.listener
      end
    end
  end

  def test_public_bind_without_https_warns
    with_tmp_global_config do
      with_fake_puma do
        _out, err = capture_io do
          Hive::Commands::Web.new(bind: "0.0.0.0", port: 4567).call
        end

        assert_match(/WARNING binding 0.0.0.0/, err,
                     "an unguarded public bind must warn loudly")
      end
    end
  end

  def test_public_bind_with_https_origin_is_silent
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "web" => { "origin" => "https://box.example" }
      }.to_yaml)
      with_fake_puma do
        _out, err = capture_io do
          Hive::Commands::Web.new(bind: "0.0.0.0", port: 4567).call
        end

        refute_match(/WARNING/, err, "an https origin signals a trusted proxy, so no warning")
      end
    end
  end

  def test_loopback_bind_is_silent
    with_tmp_global_config do
      with_fake_puma do
        _out, err = capture_io do
          Hive::Commands::Web.new(bind: "127.0.0.1", port: 4567).call
        end

        refute_match(/WARNING/, err, "a loopback bind is never publicly exposed")
      end
    end
  end
end
