require "test_helper"
require "hive/bot/status_watcher"
require "hive/bot/notification_dispatcher"
require "hive/bot/conversation_store"

class HiveBotNotificationDispatcherTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Bot::StatusWatcher::Row

  def row(action: "needs_input", marker: "waiting", attrs: {}, slug: "slug-260514-abcd", stage: "2-brainstorm",
          id: nil, display_name: nil)
    Row.new(
      project: "hive",
      slug: slug,
      id: id,
      display_name: display_name,
      stage: stage,
      marker: marker,
      attrs: attrs,
      action: action,
      action_label: "Needs your input",
      folder: "/tmp/#{slug}",
      suggested_command: "hive brainstorm #{slug}"
    )
  end

  def legacy_stage_dirs(review_count: 2, pr_count: 1)
    Hive::Bot::StatusWatcher::LegacyStageDirs.new(
      project: "hive",
      project_path: "/tmp/hive",
      hive_state_path: "/tmp/hive/.hive-state",
      legacy_stage_dirs: [
        { "stage_dir" => "5-review", "task_count" => review_count },
        { "stage_dir" => "6-pr", "task_count" => pr_count }
      ],
      legacy_migrate_command: "hive migrate"
    )
  end

  def recovery_row(attrs: { "pass" => "1" }, slug: "stuck-task-260525-abcd", stage: "6-review",
                   id: nil, display_name: nil)
    row(action: "recover_review", marker: "review_error", attrs: attrs, slug: slug, stage: stage,
        id: id, display_name: display_name)
  end

  def dispatcher(path: nil, now: Time.utc(2026, 5, 25, 10, 0, 0), daemon_enabled: ->(_project) { false },
                 telegram: self.telegram, fresh_install: false, conversation_store: nil)
    @clock = now
    d = Hive::Bot::NotificationDispatcher.new(
      telegram: telegram,
      logger: logger,
      bot_config: {
        "chat_id_allowlist" => [ 12345 ],
        "alert_state_file" => path,
        "recovery_reminder_window_sec" => 28_800
      },
      daemon_enabled: daemon_enabled,
      now: -> { @clock },
      conversation_store: conversation_store
    )
    # Most tests assert the FIRST tick alerts. The fresh_install
    # seeding behaviour gets its own focused tests; mark the
    # AlertStore as already-seeded by default so existing tests
    # don't need clock-advance wrappers.
    d.instance_variable_get(:@alert_store).mark_seeded! unless fresh_install
    d
  end

  def telegram
    @telegram ||= StubTelegram.new
  end

  def logger
    @logger ||= StubLogger.new
  end

  def test_legacy_stage_dirs_notify_once_and_refire_after_clean_transition
    d = dispatcher
    legacy = legacy_stage_dirs
    changed_while_dirty = legacy_stage_dirs(review_count: 3)

    d.process_rows([ legacy ])
    d.process_rows([ legacy ])
    d.process_rows([ changed_while_dirty ])
    d.process_rows([])
    d.process_rows([ changed_while_dirty ])

    assert_equal 2, telegram.messages.size
    assert_equal "Project hive has 3 tasks hidden in legacy stage dirs (5-review, 6-pr) - run `hive migrate /tmp/hive`",
                 telegram.messages.first[:text]
    assert_equal "Project hive has 4 tasks hidden in legacy stage dirs (5-review, 6-pr) - run `hive migrate /tmp/hive`",
                 telegram.messages.last[:text]
    assert(logger.events.any? { |name, _| name == :notification_skipped_dedupe },
           "legacy-stage warning must dedupe while the project remains legacy-dirty")
  end

  # AC-05 (#261): the bot's queue dispatch path deliberately does NOT reset
  # the alert at enqueue time — the daemon clears the marker later. The
  # supervisor test pins "reset_task not called"; this pins the property
  # that makes that safe. While a needs_input marker persists across status
  # ticks, the alert fires EXACTLY ONCE — the persistent fingerprint dedupes
  # the repeat, so the duplicate-alert race an early reset would open stays
  # closed.
  def test_needs_input_alert_fires_once_while_marker_persists
    d = dispatcher
    waiting = row(action: "needs_input", marker: "waiting")

    d.process_rows([ waiting ]) # tick 1: marker present → alert
    d.process_rows([ waiting ]) # tick 2: marker still present → dedupe

    assert_equal 1, telegram.messages.size,
                 "the alert must fire exactly once while the marker persists (AC-05)"
    assert(logger.events.any? { |name, _| name == :notification_skipped_dedupe },
           "the repeat tick must dedupe via the persistent fingerprint, not re-alert")
  end

  def test_fresh_install_still_alerts_legacy_stage_dirs
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      d = dispatcher(path: path, fresh_install: true)
      legacy = legacy_stage_dirs
      pre_existing = recovery_row

      d.process_rows([ pre_existing, legacy ])
      d.process_rows([ pre_existing, legacy ])

      assert_equal 1, telegram.messages.size
      assert_equal "Project hive has 3 tasks hidden in legacy stage dirs (5-review, 6-pr) - run `hive migrate /tmp/hive`",
                   telegram.messages.first[:text]
      assert(logger.events.any? { |name, attrs| name == :fresh_install_seeded && attrs[:fingerprint_count] == 1 },
             "fresh install should seed task backlog without seeding legacy-stage migration warnings")
    end
  end

  def test_process_rows_sends_new_input_gate_notification
    dispatcher.process_rows([ row ])

    assert_equal 1, telegram.messages.size
    assert_equal 12345, telegram.messages.first[:chat_id]
    assert_match(/Brainstorm questions/, telegram.messages.first[:text])
    assert_equal :notification_sent, logger.events.last.first
  end

  # A 3-plan `waiting` marker is a plan approval pause the daemon's
  # PlanApproval auto-approves. With the daemon enabled, the bot must NOT
  # race it with an unactionable "questions waiting" push (the operator
  # can't approve a plan from the `/answer` flow) — suppress + log it.
  def test_plan_pause_suppressed_when_daemon_enabled
    d = dispatcher(daemon_enabled: ->(_project) { true })

    d.process_rows([ row(stage: "3-plan", marker: "waiting", action: "needs_input") ])

    assert_empty telegram.messages,
                 "a daemon-auto-approved 3-plan pause must not page the operator"
    assert(logger.events.any? { |name, _| name == :notification_skipped_daemon_plan_pause },
           "the suppressed plan pause must be logged for an audit trail")
  end

  # With the daemon OFF, the plan pause does need the operator — but it is
  # a plan draft to review, NOT a brainstorm Q&A round, so it must be
  # labelled as such (the previous code mislabelled every `waiting` marker
  # as "Brainstorm questions").
  def test_plan_pause_notifies_with_plan_label_when_daemon_disabled
    dispatcher.process_rows([ row(stage: "3-plan", marker: "waiting", action: "needs_input") ])

    assert_equal 1, telegram.messages.size
    text = telegram.messages.first[:text]
    assert_match(/Plan draft is ready/, text)
    refute_match(/Brainstorm questions/, text, "a 3-plan pause must not be labelled a brainstorm question")
  end

  # The plan-pause gate is scoped to 3-plan only: a genuine 2-brainstorm
  # question still pages the operator even with the daemon enabled (the
  # daemon does not answer brainstorm questions).
  def test_brainstorm_question_still_notifies_when_daemon_enabled
    d = dispatcher(daemon_enabled: ->(_project) { true })

    d.process_rows([ row(stage: "2-brainstorm", marker: "waiting", action: "needs_input") ])

    assert_equal 1, telegram.messages.size
    assert_match(/Brainstorm questions/, telegram.messages.first[:text])
  end

  # The operator is actively answering this slug → suppress the proactive
  # "questions waiting" push (it would re-fire mid-answer when the row
  # flaps out of and back into WAITING, e.g. a daemon resume).
  NOW = Time.utc(2026, 5, 25, 10, 0, 0)

  def active_conversation_for(slug)
    store = Hive::Bot::ConversationStore.new(now: -> { NOW })
    store.start(chat_id: 12345, slug: slug, question_n: 1)
    store
  end

  def test_needs_input_alert_suppressed_while_answering
    d = dispatcher(now: NOW, conversation_store: active_conversation_for("slug-260514-abcd"))

    d.process_rows([ row ])

    assert_empty telegram.messages,
                 "no proactive push for a slug with an active answer conversation"
    # The suppressed row never enters the alert pipeline, so no dedup
    # entry is written — keeping it would block the eventual re-alert.
    assert_nil alert_store_via(d).entry(Hive::Bot::NotificationBuilders.fingerprint(row)),
               "a suppressed alert must not leave a dedup entry"
    assert(logger.events.any? { |name, _| name == :notification_skipped_active_conversation },
           "the suppression must be logged for audit")
  end

  # The single most important regression guard: fire → suppress while
  # answering → RE-FIRE once the conversation ends and the row is still
  # WAITING. A bug that left a stale dedup entry would silence the re-alert.
  def test_alert_refires_after_conversation_ends
    store = Hive::Bot::ConversationStore.new(now: -> { NOW })
    d = dispatcher(now: NOW, conversation_store: store)

    d.process_rows([ row ])
    assert_equal 1, telegram.messages.size, "first alert fires (no conversation yet)"

    store.start(chat_id: 12345, slug: "slug-260514-abcd", question_n: 1)
    d.process_rows([ row ])
    assert_equal 1, telegram.messages.size, "no new push while answering"

    store.clear(chat_id: 12345, slug: "slug-260514-abcd")
    d.process_rows([ row ])
    assert_equal 2, telegram.messages.size,
                 "re-engages with a fresh alert once the conversation ends"
  end

  def test_review_waiting_alert_suppressed_while_answering
    d = dispatcher(now: NOW, conversation_store: active_conversation_for("slug-260514-abcd"))

    d.process_rows([ row(action: "needs_input", marker: "review_waiting", stage: "5-review") ])

    assert_empty telegram.messages, "review-triage waiting is also gated by an active conversation"
  end

  def test_needs_input_alert_fires_with_empty_store_or_nil_store
    d_empty = dispatcher(now: NOW, conversation_store: Hive::Bot::ConversationStore.new(now: -> { NOW }))
    d_empty.process_rows([ row ])
    assert_equal 1, telegram.messages.size, "an empty store suppresses nothing"

    # Default wiring (no store) must also fire — the nil guard path.
    d_nil = dispatcher(now: NOW)
    d_nil.process_rows([ row ])
    assert_equal 2, telegram.messages.size, "no conversation store → no suppression"
  end

  def test_needs_input_alert_fires_with_store_but_no_active_conversation
    d = dispatcher(now: NOW, conversation_store: active_conversation_for("a-different-slug"))

    d.process_rows([ row ])

    assert_equal 1, telegram.messages.size,
                 "a conversation for another slug must not suppress this slug's alert"
  end

  # Only needs_input alerts are gated — an error/recovery alert still fires
  # even while the operator is answering that slug.
  def test_recovery_alert_not_suppressed_by_active_conversation
    d = dispatcher(now: NOW, conversation_store: active_conversation_for("slug-260514-abcd"))

    d.process_rows([ recovery_row(slug: "slug-260514-abcd") ])

    assert_equal 1, telegram.messages.size,
                 "recovery/error alerts must fire even mid-answer"
  end

  def test_same_row_twice_sends_one_notification
    d = dispatcher
    d.process_rows([ row ])
    d.process_rows([ row ])

    assert_equal 1, telegram.messages.size
    assert_equal :notification_skipped_dedupe, logger.events.last.first
  end

  def test_recovery_row_disappears_sends_recovered_message_and_removes_entry
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      d = dispatcher(path: path)
      named = recovery_row(id: 42, display_name: "Readable Recovery")
      d.process_rows([ named ])

      # First absence tick — within grace, no Recovered fires yet.
      d.process_rows([])
      assert_equal 1, telegram.messages.size,
                   "Recovered must not fire while absence is within recovery_grace_sec"

      # Advance past grace and re-evaluate — now Recovered fires.
      @clock += 61
      d.process_rows([])

      assert_equal 2, telegram.messages.size
      assert_equal "✅ Recovered: \"#42 Readable Recovery\" — Review", telegram.messages.last[:text]
      assert_nil Hive::Bot::AlertStore.new(path: path).entry(
        Hive::Bot::NotificationBuilders.fingerprint(named)
      )
    end
  end

  def test_recovered_message_send_failure_retries_after_backoff_without_duplicate
    # Telegram is down when the row first heals — Recovered cannot send.
    # The entry must stay in the store, backoff must apply, and the next
    # post-backoff tick must deliver exactly one Recovered message.
    failing = FlakyTelegram.new
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      d = dispatcher(path: path, telegram: failing)
      d.process_rows([ recovery_row ])
      # The first tick fails (initial alert), so the entry is persisted with
      # delivered_to: [] and a 60s backoff. Advance past backoff and past the
      # absence-grace window before the row disappears.
      @clock += 61
      d.process_rows([ recovery_row ])
      assert_equal 1, failing.messages.size, "initial alert must deliver after backoff"

      # Row heals — process_recoveries enters absence-grace.
      d.process_rows([])
      @clock += 61
      # Now past grace; Telegram is up. Recovered must fire exactly once.
      d.process_rows([])

      recovered = failing.messages.select { |msg| msg[:text].include?("Recovered") }
      assert_equal 1, recovered.size,
                   "Recovered must deliver exactly once after Telegram outage clears"
      assert_nil Hive::Bot::AlertStore.new(path: path).entry(
        Hive::Bot::NotificationBuilders.fingerprint(recovery_row)
      ), "entry must be removed after successful Recovered delivery"
    end
  end

  def test_recovered_message_send_failure_records_backoff
    # Stand up an entry via a working Telegram, then swap the dispatcher
    # for an always-failing Telegram so process_recoveries lands in the
    # record_send_failure branch.
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      store = Hive::Bot::AlertStore.new(path: path)
      store.mark_seeded!
      working = StubTelegram.new
      d_in = Hive::Bot::NotificationDispatcher.new(
        telegram: working,
        logger: logger,
        bot_config: { "chat_id_allowlist" => [ 12345 ], "recovery_reminder_window_sec" => 28_800 },
        now: -> { @clock ||= Time.utc(2026, 5, 25, 10, 0, 0) },
        alert_store: store
      )
      @clock = Time.utc(2026, 5, 25, 10, 0, 0)
      d_in.process_rows([ recovery_row ])

      failing = AlwaysFailingTelegram.new
      d_out = Hive::Bot::NotificationDispatcher.new(
        telegram: failing,
        logger: logger,
        bot_config: { "chat_id_allowlist" => [ 12345 ], "recovery_reminder_window_sec" => 28_800 },
        now: -> { @clock },
        alert_store: store
      )
      # Tick 1 absent: mark_absent only, no Recovered attempt yet.
      d_out.process_rows([])
      assert_equal 0, failing.calls
      # Tick 2 absent (past grace): Recovered attempted, send fails.
      @clock += 61
      d_out.process_rows([])
      assert_equal 1, failing.calls

      fingerprint = Hive::Bot::NotificationBuilders.fingerprint(recovery_row)
      entry = store.entry(fingerprint)
      refute_nil entry, "failed Recovered must leave the entry intact"
      refute_nil entry.next_attempt_after,
                 "Recovered send failure must call record_send_failure to schedule backoff"
    end
  end

  def test_reminder_notification_raises_on_unexpected_recovery_headline_shape
    d = dispatcher
    # Stub NotificationBuilders.recovery to return text that does not
    # start with the expected "⚠ " sentinel; reminder_notification must
    # raise rather than silently mutate the wrong line.
    original = Hive::Bot::NotificationBuilders.method(:recovery)
    Hive::Bot::NotificationBuilders.define_singleton_method(:recovery) do |row, **_kwargs|
      Hive::Bot::NotificationBuilders::Notification.new(
        text: "different headline\nbody",
        keyboard: nil
      )
    end

    err = assert_raises(RuntimeError) do
      d.send(:reminder_notification, recovery_row)
    end
    assert_match(/reminder_notification expected NotificationBuilders\.recovery/, err.message)
  ensure
    Hive::Bot::NotificationBuilders.define_singleton_method(:recovery, original) if original
  end

  def test_fresh_install_silently_seeds_first_tick_and_alerts_only_on_deltas
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      refute File.exist?(path), "precondition: alert_state_file must not yet exist"

      d = dispatcher(path: path, fresh_install: true)
      pre_existing = recovery_row
      brand_new = recovery_row(slug: "new-stuck-260525-9999")

      # Day 1: existing failure already in the snapshot. Must NOT alert.
      d.process_rows([ pre_existing ])
      assert_empty telegram.messages,
                   "fresh install must not alert on backlog failures from the very first tick"
      assert(logger.events.any? { |name, _| name == :fresh_install_seeded },
             ":fresh_install_seeded event must be logged for observability")

      # Day 2: the same pre-existing failure is still around — dedupe applies.
      @clock += 30
      d.process_rows([ pre_existing ])
      assert_empty telegram.messages, "subsequent tick must dedupe seeded entries"

      # Day 3: a NEW failure appears. This one alerts normally.
      @clock += 30
      d.process_rows([ pre_existing, brand_new ])
      assert_equal 1, telegram.messages.size, "only the delta (new failure) must alert"
      assert_match(/New stuck/, telegram.messages.last[:text])
    end
  end

  def test_existing_state_file_does_not_count_as_fresh_install
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      # Pre-create an empty but valid state file. This simulates a bot that
      # has run before but has no entries.
      File.write(path, JSON.generate({ "schema_version" => 1, "entries" => {} }))

      d = dispatcher(path: path, fresh_install: true)
      d.process_rows([ recovery_row ])

      assert_equal 1, telegram.messages.size,
                   "an existing state file (even empty) must NOT trigger silent seeding"
    end
  end

  def test_transient_row_absence_within_grace_does_not_fire_recovered
    d = dispatcher
    d.process_rows([ recovery_row(id: 42, display_name: "Readable Recovery") ])
    d.process_rows([])               # tick 2: row absent → mark_absent, no Recovered
    d.process_rows([ recovery_row ]) # tick 3: row re-appears within grace

    assert_equal 1, telegram.messages.size,
                 "Transient agent_running flicker must NOT produce a false Recovered + re-stuck pair"
    refute_match(/Recovered/, telegram.messages.first[:text])
  end

  def test_non_recovery_row_disappears_silently_drops_entry
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      d = dispatcher(path: path)
      d.process_rows([ row ])

      d.process_rows([])

      assert_equal 1, telegram.messages.size
      assert_equal [], Hive::Bot::AlertStore.new(path: path).each_fingerprint.to_a
    end
  end

  def test_same_fingerprint_reappears_after_recovery_refires
    d = dispatcher
    d.process_rows([ recovery_row ])
    d.process_rows([])               # absence tick — within grace
    @clock += 61                     # past grace, next absent-tick fires Recovered
    d.process_rows([])
    d.process_rows([ recovery_row ]) # reappears as a fresh alert

    assert_equal 3, telegram.messages.size
    assert_match(/Review stuck/, telegram.messages.first[:text])
    assert_match(/Recovered/, telegram.messages[1][:text])
    assert_match(/Review stuck/, telegram.messages.last[:text])
  end

  def test_marker_attr_change_renotifies_without_false_recovered_message
    d = dispatcher
    d.process_rows([ recovery_row(attrs: { "pass" => "2" }) ])
    d.process_rows([ recovery_row(attrs: { "pass" => "3" }) ])

    assert_equal 2, telegram.messages.size
    assert_match(/Review stuck/, telegram.messages.first[:text])
    assert_match(/Review stuck/, telegram.messages.last[:text])
    refute_match(/Recovered/, telegram.messages.map { |message| message[:text] }.join("\n"))
  end

  def test_reset_task_allows_same_fingerprint_to_refire
    d = dispatcher
    task = recovery_row(attrs: { "pass" => "2" })

    d.process_rows([ task ])
    d.reset_task(project: "hive", slug: "stuck-task-260525-abcd", stage: "6-review")
    d.process_rows([ task ])

    assert_equal 2, telegram.messages.size
    assert telegram.messages.all? { |message| message[:text].include?("Review stuck") }
  end

  def test_eight_hour_reminder_fires_exactly_once
    d = dispatcher
    named = recovery_row(id: 42, display_name: "Readable Recovery")
    d.process_rows([ named ])
    @clock += 28_800
    d.process_rows([ named ])
    @clock += 28_800
    d.process_rows([ named ])

    assert_equal 2, telegram.messages.size
    assert_match(/\A⚠ Still stuck \(8 h\) — "#42 Readable Recovery" — Review/, telegram.messages.last[:text])
  end

  def test_reminder_send_failure_applies_backoff
    # First tick: initial alert succeeds.
    d = dispatcher
    d.process_rows([ recovery_row ])
    assert_equal 1, telegram.messages.size

    # Advance to the 8h reminder boundary and swap in a Telegram that always fails.
    @clock += 28_800
    failing = AlwaysFailingTelegram.new
    failing_dispatcher = Hive::Bot::NotificationDispatcher.new(
      telegram: failing,
      logger: logger,
      bot_config: { "chat_id_allowlist" => [ 12345 ], "recovery_reminder_window_sec" => 28_800 },
      now: -> { @clock },
      alert_store: d.instance_variable_get(:@alert_store)
    )
    failing_dispatcher.process_rows([ recovery_row ])
    assert_equal 1, failing.calls, "reminder must attempt one send"
    refute alert_store_via(failing_dispatcher).entry(
      Hive::Bot::NotificationBuilders.fingerprint(recovery_row)
    ).next_attempt_after.nil?, "send failure must schedule a backoff window"

    # Immediately retry: backoff window not yet expired → skip, no extra attempt.
    failing_dispatcher.process_rows([ recovery_row ])
    assert_equal 1, failing.calls, "reminder must NOT retry within the backoff window"
    assert(logger.events.any? { |name, _| name == :notification_skipped_backoff },
           "skipped reminder retry must emit :notification_skipped_backoff")
  end

  def alert_store_via(dispatcher)
    dispatcher.instance_variable_get(:@alert_store)
  end

  def test_ninety_minute_reminder_fires_with_minutes_label
    d = Hive::Bot::NotificationDispatcher.new(
      telegram: telegram,
      logger: logger,
      bot_config: {
        "chat_id_allowlist" => [ 12345 ],
        "recovery_reminder_window_sec" => 5400
      },
      now: -> { @clock ||= Time.utc(2026, 5, 25, 10, 0, 0) }
    )
    @clock = Time.utc(2026, 5, 25, 10, 0, 0)
    d.process_rows([ recovery_row ])
    @clock += 5400
    d.process_rows([ recovery_row ])

    assert_equal 2, telegram.messages.size, "reminder should fire after 90 min"
    assert_match(/Still stuck \(1 h 30 min\)/, telegram.messages.last[:text],
                 "reminder label uses combined hours+minutes form for windows that are >= 1h but not whole-hour")
  end

  def test_dispatcher_uses_default_now_lambda_when_not_provided
    # Production callers (Supervisor) construct without `now:` and rely
    # on the default lambda returning Time.now. Exercise the default
    # so the constructor signature line is covered.
    d = Hive::Bot::NotificationDispatcher.new(
      telegram: StubTelegram.new,
      logger: StubLogger.new,
      bot_config: { "chat_id_allowlist" => [ 12345 ], "recovery_reminder_window_sec" => 28_800 }
    )
    now_lambda = d.instance_variable_get(:@now)
    refute_nil now_lambda
    assert_in_delta Time.now.to_f, now_lambda.call.to_f, 1.0,
                    "default now: lambda must return current time"
  end

  def test_reminder_label_renders_minutes_form_for_sub_hour_windows
    # Sub-hour windows aren't normally reachable via config bounds (3600 floor),
    # but the dispatcher accepts raw bot_config so the minutes form must still
    # apply if a caller bypasses validation.
    d = Hive::Bot::NotificationDispatcher.new(
      telegram: telegram,
      logger: logger,
      bot_config: { "chat_id_allowlist" => [ 12345 ], "recovery_reminder_window_sec" => 1800 },
      now: -> { @clock ||= Time.utc(2026, 5, 25, 10, 0, 0) }
    )
    @clock = Time.utc(2026, 5, 25, 10, 0, 0)
    d.process_rows([ recovery_row ])
    @clock += 1800
    d.process_rows([ recovery_row ])

    assert_match(/Still stuck \(30 min\)/, telegram.messages.last[:text],
                 "sub-1h window uses the bare 'N min' form")
  end

  def test_reminder_label_renders_pure_hours_when_whole_hour_window
    d = Hive::Bot::NotificationDispatcher.new(
      telegram: telegram,
      logger: logger,
      bot_config: { "chat_id_allowlist" => [ 12345 ], "recovery_reminder_window_sec" => 14_400 },
      now: -> { @clock ||= Time.utc(2026, 5, 25, 10, 0, 0) }
    )
    @clock = Time.utc(2026, 5, 25, 10, 0, 0)
    d.process_rows([ recovery_row ])
    @clock += 14_400
    d.process_rows([ recovery_row ])

    assert_match(/Still stuck \(4 h\)/, telegram.messages.last[:text],
                 "whole-hour window uses bare 'N h' form, no '0 min' suffix")
  end

  def test_restart_simulation_does_not_refire_same_active_row
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      dispatcher(path: path).process_rows([ recovery_row ])

      fresh = dispatcher(path: path)
      fresh.process_rows([ recovery_row ])

      assert_equal 1, telegram.messages.size
    end
  end

  def test_corrupt_store_starts_fresh_without_crashing
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      File.write(path, "{")

      dispatcher(path: path).process_rows([ recovery_row ])

      assert_equal 1, telegram.messages.size
      assert_equal :alert_store_corrupt, logger.events.first.first
      assert Dir.glob("#{path}.corrupt-*").any?
    end
  end

  def test_ready_action_suppressed_when_daemon_enabled
    d = dispatcher(daemon_enabled: ->(_project) { true })
    d.process_rows([ row(action: "ready_to_plan", marker: "complete") ])

    assert_empty telegram.messages,
                 "ready_to_X with daemon enabled must not produce a proactive Telegram message"
  end

  def test_ready_action_fires_alert_when_daemon_disabled
    # With daemon disabled the operator needs the Approve/Reject keyboard to
    # advance the workflow — fire one proactive alert per fingerprint.
    d = dispatcher(daemon_enabled: ->(_project) { false })
    d.process_rows([ row(action: "ready_to_plan", marker: "complete") ])

    assert_equal 1, telegram.messages.size,
                 "ready_to_X with daemon disabled must fire one proactive alert"
    assert_match(/Ready for/, telegram.messages.last[:text])
    labels = telegram.messages.last[:reply_markup].flatten.map { |b| b[:text] }
    assert_includes labels, "Approve"
    assert_includes labels, "Reject"
  end

  def test_multi_chat_fanout_delivers_to_all_allowed_chats
    multi = Hive::Bot::NotificationDispatcher.new(
      telegram: telegram,
      logger: logger,
      bot_config: { "chat_id_allowlist" => [ 12345, 67890 ], "recovery_reminder_window_sec" => 28_800 },
      now: -> { @clock ||= Time.utc(2026, 5, 25, 10, 0, 0) }
    )
    multi.process_rows([ row ])

    assert_equal [ 12345, 67890 ], telegram.messages.map { |msg| msg[:chat_id] }
  end

  def test_partial_multi_chat_failure_retries_only_undelivered_chats
    flaky = PartiallyFlakyTelegram.new(fail_chat_id: 67890)
    multi = Hive::Bot::NotificationDispatcher.new(
      telegram: flaky,
      logger: logger,
      bot_config: { "chat_id_allowlist" => [ 12345, 67890 ], "recovery_reminder_window_sec" => 28_800 },
      now: -> { @clock ||= Time.utc(2026, 5, 25, 10, 0, 0) }
    )

    multi.process_rows([ row ])
    multi.process_rows([ row ])

    assert_equal [ 12345, 67890, 67890 ], flaky.calls
    assert_equal [ 12345, 67890 ], flaky.messages.map { |msg| msg[:chat_id] }
    assert_equal :notification_sent, logger.events.last.first
  end

  def test_rows_without_notification_are_ignored
    dispatcher.process_rows([ row(action: "agent_running", marker: "agent_working") ])

    assert_empty telegram.messages
    assert_empty logger.events
  end

  def test_send_failures_are_logged_without_marking_seen
    flaky_telegram = FlakyTelegram.new
    d = dispatcher(telegram: flaky_telegram)

    d.process_rows([ row ])

    assert_empty flaky_telegram.messages
    assert_equal :send_failure, logger.events.map(&:first).find { |e| e == :send_failure }
    failure_event = logger.events.find { |e| e.first == :send_failure }
    assert_equal "IOError", failure_event.last[:error_class]

    @clock += 60
    d.process_rows([ row ])

    assert_equal 1, flaky_telegram.messages.size
    assert_equal :notification_sent, logger.events.last.first
  end

  def test_send_failure_applies_exponential_backoff_skipping_subsequent_ticks
    flaky_telegram = AlwaysFailingTelegram.new
    d = dispatcher(telegram: flaky_telegram)

    d.process_rows([ row ])
    assert_equal 1, flaky_telegram.calls, "first tick must attempt one send"

    # Immediately retry — backoff is 60s, should skip.
    d.process_rows([ row ])
    assert_equal 1, flaky_telegram.calls, "second tick within backoff window must skip the send"
    assert(logger.events.any? { |name, _| name == :notification_skipped_backoff },
           "skipped tick must emit :notification_skipped_backoff")

    # Advance past first backoff (60s) — try again, still fails, schedules 120s backoff.
    @clock += 61
    d.process_rows([ row ])
    assert_equal 2, flaky_telegram.calls

    # 60s later, still within 120s backoff window — skip.
    @clock += 60
    d.process_rows([ row ])
    assert_equal 2, flaky_telegram.calls
  end

  def test_ready_action_uses_config_fallback_when_no_daemon_probe
    projects = []
    loads = []
    with_config_stubs(
      find_project: ->(project) { projects << project; { "path" => "/tmp/hive" } },
      load: ->(path) { loads << path; { "daemon" => { "enabled" => true } } }
    ) do
      d = dispatcher(daemon_enabled: nil)
      d.process_rows([ row(action: "ready_to_plan", marker: "complete") ])
    end

    assert_empty telegram.messages,
                 "ready_to_X with daemon enabled in project config must be suppressed"
    assert_equal [ "hive" ], projects
    assert_equal [ "/tmp/hive" ], loads
  end

  def test_ready_action_not_suppressed_when_project_missing_from_config
    projects = []
    loads = []
    with_config_stubs(
      find_project: ->(project) { projects << project; nil },
      load: ->(_path) { loads << "loaded"; raise "Config.load should not be called" }
    ) do
      d = dispatcher(daemon_enabled: nil)
      d.process_rows([ row(action: "ready_to_plan", marker: "complete") ])
    end

    assert_equal 1, telegram.messages.size,
                 "unknown project (no config entry) defaults to daemon disabled → alert fires"
    assert_equal [ "hive" ], projects
    assert_empty loads, "Config.load is skipped when find_project returns nil"
  end

  def test_daemon_config_errors_are_logged_and_do_not_suppress_ready_actions
    with_config_stubs(
      find_project: ->(_project) { { "path" => "/tmp/hive" } },
      load: ->(_path) { raise Hive::ConfigError, "bad config" }
    ) do
      d = dispatcher(daemon_enabled: nil)
      d.process_rows([ row(action: "ready_to_plan", marker: "complete") ])
    end

    assert_equal 1, telegram.messages.size,
                 "config load failure must not silently suppress — fail open to alerting"
    event = logger.events.find { |name, _attrs| name == :poll_failure }
    refute_nil event
    assert_equal "daemon_check", event.last[:source]
    assert_equal "hive", event.last[:project]
    assert_equal "Hive::ConfigError", event.last[:error_class]
  end

  def with_config_stubs(find_project:, load:)
    original_find_project = Hive::Config.method(:find_project)
    original_load = Hive::Config.method(:load)
    Hive::Config.define_singleton_method(:find_project, &find_project)
    Hive::Config.define_singleton_method(:load, &load)
    yield
  ensure
    Hive::Config.define_singleton_method(:find_project, original_find_project)
    Hive::Config.define_singleton_method(:load, original_load)
  end

  class FlakyTelegram
    attr_reader :messages

    def initialize
      @messages = []
      @fail_next = true
    end

    def send_message(chat_id:, text:, reply_markup: nil, parse_mode: :markdown)
      if @fail_next
        @fail_next = false
        raise IOError, "delivery failed"
      end

      @messages << { chat_id: chat_id, text: text, reply_markup: reply_markup, parse_mode: parse_mode }
    end
  end

  class AlwaysFailingTelegram
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def send_message(chat_id:, text:, reply_markup: nil, parse_mode: :markdown)
      @calls += 1
      raise IOError, "delivery failed"
    end
  end

  class PartiallyFlakyTelegram
    attr_reader :messages, :calls

    def initialize(fail_chat_id:)
      @fail_chat_id = fail_chat_id
      @failed = false
      @messages = []
      @calls = []
    end

    def send_message(chat_id:, text:, reply_markup: nil, parse_mode: :markdown)
      @calls << chat_id
      if chat_id == @fail_chat_id && !@failed
        @failed = true
        raise IOError, "delivery failed"
      end

      @messages << { chat_id: chat_id, text: text, reply_markup: reply_markup, parse_mode: parse_mode }
    end
  end

  class StubTelegram
    attr_reader :messages

    def initialize
      @messages = []
    end

    def send_message(chat_id:, text:, reply_markup: nil, parse_mode: :markdown)
      @messages << { chat_id: chat_id, text: text, reply_markup: reply_markup, parse_mode: parse_mode }
    end
  end

  class StubLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def event(name, **attrs)
      @events << [ name, attrs ]
    end
  end
end
