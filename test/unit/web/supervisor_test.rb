require "test_helper"
require "hive/web/supervisor"

# U8 container supervisor: the pure decision helpers — fast-failure backoff,
# the web-only-restart gate, and the SIGHUP reload that brings up the bot —
# carry the restart logic and must be pinned. start_child is stubbed (or fed a
# real quick-exit process) so no long-lived children are spawned.
class WebSupervisorTest < Minitest::Test
  include HiveTestHelper

  Child = Hive::Web::Supervisor::Child

  def build = Hive::Web::Supervisor.new

  def restart_at(sup) = sup.instance_variable_get(:@restart_at)

  def test_schedule_restart_backs_off_a_fast_failure
    with_tmp_global_config do
      sup = build
      child = Child.new(name: "web", argv: %w[x], pid: nil, started_at: Time.now)

      sup.send(:schedule_restart, child)

      assert_operator restart_at(sup)["web"], :>, Time.now + 1,
                      "a child that died almost immediately must be deferred (backoff)"
    end
  end

  def test_schedule_restart_is_immediate_for_a_long_lived_crash
    with_tmp_global_config do
      sup = build
      child = Child.new(name: "web", argv: %w[x], pid: nil, started_at: Time.now - 3600)

      sup.send(:schedule_restart, child)

      assert_operator restart_at(sup)["web"], :<=, Time.now + 0.5,
                      "a long-lived child that crashes restarts immediately"
    end
  end

  def test_reap_schedules_restart_only_for_a_failed_web_child
    with_tmp_global_config do
      sup = build
      sup.send(:start_child, "web", [ "sh", "-c", "exit 1" ])
      sup.send(:start_child, "daemon", [ "sh", "-c", "exit 1" ])
      reap_until_drained(sup)

      assert restart_at(sup).key?("web"), "a failed web child must be scheduled for restart"
      refute restart_at(sup).key?("daemon"), "daemon failures are not restarted by this gate"
    end
  end

  def test_reap_does_not_restart_a_clean_web_exit
    with_tmp_global_config do
      sup = build
      sup.send(:start_child, "web", [ "true" ])
      reap_until_drained(sup)

      refute restart_at(sup).key?("web"), "a clean (success) web exit must NOT be restarted"
    end
  end

  def test_handle_reload_starts_bot_when_enabled
    with_tmp_global_config do
      Hive::Config.update_global_config! do |data|
        data["bot"] = { "enabled" => true, "chat_id_allowlist" => [ 1 ] }
      end
      sup = build
      started = stub_start_child(sup)
      sup.instance_variable_set(:@reload_requested, true)

      sup.send(:handle_reload)

      assert_includes started, "bot", "SIGHUP reload with bot enabled must bring the bot up"
    end
  end

  def test_handle_reload_is_a_noop_when_bot_disabled
    with_tmp_global_config do
      sup = build
      started = stub_start_child(sup)

      sup.send(:handle_reload)

      refute_includes started, "bot", "reload must not start a bot the operator hasn't enabled"
    end
  end

  private

  def stub_start_child(sup)
    started = []
    sup.define_singleton_method(:start_child) { |name, _argv| started << name }
    started
  end

  # Drive reap_once until both children have been collected (or a deadline),
  # without a fixed sleep that would race the child exits.
  def reap_until_drained(sup)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      sup.send(:reap_once)
      children = sup.instance_variable_get(:@children)
      break if children.all? { |c| c.pid.nil? }
      flunk "children did not exit within deadline" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end
end
