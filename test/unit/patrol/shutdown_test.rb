require "test_helper"
require "hive/patrol/shutdown"

class PatrolShutdownTest < Minitest::Test
  def setup
    Hive::Patrol::Shutdown.reset!
  end

  def teardown
    Hive::Patrol::Shutdown.reset!
  end

  def test_starts_clear_and_records_an_explicit_request
    refute_predicate Hive::Patrol::Shutdown, :requested?

    Hive::Patrol::Shutdown.request!
    assert_predicate Hive::Patrol::Shutdown, :requested?

    Hive::Patrol::Shutdown.reset!
    refute_predicate Hive::Patrol::Shutdown, :requested?
  end

  def test_a_delivered_signal_requests_shutdown_without_killing_the_process
    previous = Signal.trap("TERM", "DEFAULT")
    Hive::Patrol::Shutdown.install_trap!(signals: %w[TERM])

    Process.kill("TERM", Process.pid)
    # Signal delivery is asynchronous; give the handler a bounded chance to run
    # rather than assuming it landed before the next statement.
    20.times do
      break if Hive::Patrol::Shutdown.requested?

      sleep 0.01
    end

    assert_predicate Hive::Patrol::Shutdown, :requested?,
                     "TERM must set the cooperative flag instead of terminating patrol"
  ensure
    Signal.trap("TERM", previous || "DEFAULT")
  end

  # A platform missing one of the signals must not take the whole scan down at
  # startup; the default handler simply stays in place.
  def test_an_unavailable_signal_is_ignored
    Hive::Patrol::Shutdown.install_trap!(signals: %w[NOT_A_REAL_SIGNAL])

    refute_predicate Hive::Patrol::Shutdown, :requested?
  end

  def test_agent_child_handler_preserves_the_patrol_shutdown_request
    previous = Signal.trap("TERM", "DEFAULT")
    Hive::Patrol::Shutdown.install_trap!(signals: %w[TERM])
    agent = Hive::Agent.allocate
    child_cancelled = false
    agent.send(:install_chained_signal_trap, "TERM") { child_cancelled = true }

    Process.kill("TERM", Process.pid)
    20.times do
      break if child_cancelled && Hive::Patrol::Shutdown.requested?

      sleep 0.01
    end

    assert child_cancelled
    assert_predicate Hive::Patrol::Shutdown, :requested?
  ensure
    Signal.trap("TERM", previous || "DEFAULT")
  end

  def test_install_trap_chains_an_existing_callable_handler
    previous = Signal.trap("TERM", "DEFAULT")
    chained = false
    Signal.trap("TERM") { chained = true }
    Hive::Patrol::Shutdown.install_trap!(signals: %w[TERM])

    Process.kill("TERM", Process.pid)
    20.times do
      break if chained && Hive::Patrol::Shutdown.requested?

      sleep 0.01
    end

    assert chained
    assert_predicate Hive::Patrol::Shutdown, :requested?
  ensure
    Signal.trap("TERM", previous || "DEFAULT")
  end
end
