require "test_helper"
require "hive/bot/notification_dispatcher"
require "hive/bot/notification_builders"
require "hive/bot/status_watcher"
require "hive/bot/alert_store"

# R13 lifecycle integration: a recovery alert is delivered exactly once,
# Autofix clears the AlertStore entry, and a subsequent same-fingerprint
# failure re-alerts. Unit tests cover each step in isolation; this one
# wires NotificationDispatcher + AlertStore + an AlertStore-backed reset
# call (the same path the Supervisor invokes when handling an Autofix
# callback) end-to-end so a future refactor of any single link in the
# chain cannot silently regress the contract.
class HiveBotAlertLifecycleIntegrationTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Bot::StatusWatcher::Row

  def stuck_row(pass:, attrs_extra: {})
    Row.new(
      project: "hive",
      slug: "stuck-task-260525-abcd",
      stage: "6-review",
      marker: "review_error",
      attrs: { "pass" => pass.to_s, "phase" => "fix" }.merge(attrs_extra),
      action: "recover_review"
    )
  end

  class CapturingTelegram
    attr_reader :messages
    def initialize = @messages = []
    def send_message(chat_id:, text:, reply_markup: nil, parse_mode: :markdown)
      @messages << { chat_id: chat_id, text: text }
    end
  end

  class StubLogger
    attr_reader :events
    def initialize = @events = []
    def event(name, **payload) = @events << [ name, payload ]
  end

  def test_r13_autofix_clears_alert_then_same_fingerprint_refires
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      telegram = CapturingTelegram.new
      logger = StubLogger.new
      clock = Time.utc(2026, 5, 25, 10, 0, 0)
      dispatcher = Hive::Bot::NotificationDispatcher.new(
        telegram: telegram,
        logger: logger,
        bot_config: { "chat_id_allowlist" => [ 42 ], "recovery_reminder_window_sec" => 28_800 },
        now: -> { clock }
      )
      # Manually wire AlertStore so we can drive reset_task without standing up Supervisor.
      alert_store = Hive::Bot::AlertStore.new(path: path, logger: logger)
      dispatcher.instance_variable_set(:@alert_store, alert_store)

      row1 = stuck_row(pass: 2)

      # 1. First alert delivers.
      dispatcher.process_rows([ row1 ])
      assert_equal 1, telegram.messages.size
      assert_match(/Review stuck/, telegram.messages.last[:text])
      assert_equal 1, alert_store.each_fingerprint.to_a.size

      # 2. Same row re-evaluated next tick — dedupe, no new message.
      clock += 30
      dispatcher.process_rows([ row1 ])
      assert_equal 1, telegram.messages.size, "second tick must dedupe; no duplicate ⚠ alert"

      # 3. Operator taps Autofix — Supervisor calls reset_task with the marker fingerprint.
      dispatcher.reset_task(project: row1.project, slug: row1.slug, stage: row1.stage,
                            marker: row1.marker)
      assert_empty alert_store.each_fingerprint.to_a,
                   "Autofix reset_task must clear the AlertStore entry"

      # 4. The retry stage produces the same fingerprint failure (deterministic crash).
      #    R13 says the operator must see another alert.
      clock += 5
      dispatcher.process_rows([ row1 ])
      assert_equal 2, telegram.messages.size,
                   "R13: a same-fingerprint failure after Autofix must re-alert"
      assert_match(/Review stuck/, telegram.messages.last[:text])

      # 5. Different-marker row at the same stage gets its own alert without
      #    being deduped by the row1 entry — verifies the marker-scoped fix
      #    from P2 #7 stays correct end-to-end.
      row2 = stuck_row(pass: 2, attrs_extra: { "reason" => "stale" })
      row2_diff_marker = Hive::Bot::StatusWatcher::Row.new(
        project: row2.project, slug: row2.slug, stage: row2.stage,
        marker: "review_ci_stale", attrs: row2.attrs.to_h, action: "recover_review"
      )
      dispatcher.process_rows([ row1, row2_diff_marker ])
      # The second tick may or may not produce a new message depending on dedupe,
      # but the AlertStore must now have two distinct entries.
      assert_operator alert_store.each_fingerprint.to_a.size, :>=, 2,
                      "distinct markers must produce distinct AlertStore entries"
    end
  end
end
