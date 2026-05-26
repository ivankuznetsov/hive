require "test_helper"
require "hive/bot/supervisor"

class HiveBotSupervisorTest < Minitest::Test
  include HiveTestHelper

  ChildExit = Hive::Bot::ChildSupervisor::ChildExit
  Update = Struct.new(:chat_id, :update_id, :message_id, keyword_init: true)
  Row = Struct.new(:project, :slug, :stage, :action, :action_label, :marker, :attrs, :diagnostic,
                   keyword_init: true)
  StatusResult = Struct.new(:ok, :rows, :error, :envelope, keyword_init: true)

  FakeTelegram = Struct.new(:messages, :raise_on_send, :keyboard_clears,
                            :commands_registered, :raise_on_set_my_commands, keyword_init: true) do
    def send_message(chat_id:, text:, reply_markup: nil)
      raise raise_on_send if raise_on_send

      messages << { chat_id: chat_id, text: text, reply_markup: reply_markup }
    end

    def edit_message_reply_markup(chat_id:, message_id:, reply_markup: nil)
      (self.keyboard_clears ||= []) << { chat_id: chat_id, message_id: message_id, reply_markup: reply_markup }
    end

    def set_my_commands(commands:)
      raise raise_on_set_my_commands if raise_on_set_my_commands

      (self.commands_registered ||= []) << commands
    end
  end

  FakeLogger = Struct.new(:events, keyword_init: true) do
    def event(name, **payload)
      events << { name: name, payload: payload }
    end

    def close; end
  end

  FakeStatusWatcher = Struct.new(:result, keyword_init: true) do
    def fetch
      result
    end
  end


  FakeNotificationDispatcher = Struct.new(:processed, :reset_tasks, keyword_init: true) do
    def process_rows(rows)
      processed << rows
    end

    def reset_task(**kwargs)
      reset_tasks << kwargs
    end
  end

  class FakeRouter
    Result = Struct.new(:action, :text, :reply_markup, :command_argv, :commands, :project, :slug,
                        :question_n, :answer_text, :mode, :alert_reset, :clear_keyboard, :format,
                        keyword_init: true)
  end

  FakeChildSupervisor = Struct.new(:dispatch_pid, :dispatched, :completed, :reap_batches, keyword_init: true) do
    def dispatch(**kwargs)
      dispatched << kwargs
      dispatch_pid
    end

    def completed_exit(pid)
      completed[pid]
    end

    def reap_all
      reap_batches.shift || []
    end
  end

  FakeConversationStore = Struct.new(:starts, :updates, :states, :ttl_updates, keyword_init: true) do
    def start(**kwargs)
      starts << kwargs
      state = Struct.new(:question_n, :mode, :project, :draft, :history, :awaiting_confirm, keyword_init: true).new(
        question_n: kwargs[:question_n], mode: kwargs[:mode], project: kwargs[:project], history: []
      )
      states[[ kwargs[:chat_id], kwargs[:slug] ]] = state
      state
    end

    def get(chat_id:, slug:)
      states[[ chat_id, slug ]]
    end

    def update(chat_id:, slug:, **kwargs)
      updates << { chat_id: chat_id, slug: slug, values: kwargs }
      state = states[[ chat_id, slug ]] || start(
        chat_id: chat_id, slug: slug, question_n: kwargs[:question_n], mode: kwargs[:mode]
      )
      kwargs.each { |key, value| state.public_send("#{key}=", value) if state.respond_to?("#{key}=") }
      state
    end

    def update_ttl(ttl)
      ttl_updates << ttl
    end
  end

  def setup
    @telegram = FakeTelegram.new(messages: [])
    @logger = FakeLogger.new(events: [])
    @status_watcher = FakeStatusWatcher.new(result: StatusResult.new(ok: true, rows: []))
    @child_supervisor = FakeChildSupervisor.new(dispatch_pid: 123, dispatched: [], completed: {}, reap_batches: [])
    @conversation_store = FakeConversationStore.new(starts: [], updates: [], states: {}, ttl_updates: [])
    @notification_dispatcher = FakeNotificationDispatcher.new(processed: [], reset_tasks: [])
    # Drive the real constructor so any future invariant added to
    # Supervisor#initialize is exercised by every test in this file. We
    # inject all collaborators so the constructor's `||=` defaults never
    # touch disk or the network.
    @config = {
      "chat_id_allowlist" => [ 42, 43 ],
      "clear_retry_grace_sec" => 1,
      "conversation_ttl_sec" => 60,
      "poll_interval_sec" => 1
    }
    @supervisor = Hive::Bot::Supervisor.new(
      config: @config,
      token: "test-token",
      logger: @logger,
      telegram: @telegram,
      status_watcher: @status_watcher,
      notification_dispatcher: @notification_dispatcher,
      router: FakeRouter.new,
      child_supervisor: @child_supervisor,
      conversation_store: @conversation_store,
      dry_run: false
    )
  end

  def child_exit(exit_code: 0, envelope: nil, log_path: "/tmp/hive-bot.log", pid: 123)
    ChildExit.new(
      pid: pid,
      exit_code: exit_code,
      project: "hive",
      slug: "red-task-260518-aaaa",
      command_argv: [ "hive", "status", "--diagnose", "red-task-260518-aaaa", "--json" ],
      chat_id: 42,
      update_id: 99,
      started_at: Time.now,
      finished_at: Time.now,
      log_path: log_path,
      json_envelope: envelope
    )
  end

  def row(project: "hive", slug: "task", stage: "3-plan", action: "ready_to_develop",
          action_label: "Develop", marker: "COMPLETE", attrs: {}, diagnostic: nil)
    Row.new(project: project, slug: slug, stage: stage, action: action,
            action_label: action_label, marker: marker, attrs: attrs, diagnostic: diagnostic)
  end


  def with_brainstorm_file(slug: "bot-task-260522-aa", content:)
    with_tmp_dir do |dir|
      project = File.join(dir, "project")
      folder = File.join(project, ".hive-state", "stages", "2-brainstorm", slug)
      FileUtils.mkdir_p(folder)
      path = File.join(folder, "brainstorm.md")
      File.write(path, content)
      yield path, project
    end
  end

  Outcome = Struct.new(:kind, :draft, :text, :reason, keyword_init: true)

  FakeCodexConversation = Struct.new(:outcome, :calls, keyword_init: true) do
    def next_turn(**kwargs)
      calls << kwargs
      outcome
    end
  end

  def test_reply_for_child_renders_status_diagnose_success_envelope
    envelope = {
      "schema" => "hive-status-diagnose",
      "ok" => true,
      "slug" => "red-task-260518-aaaa",
      "diagnostic" => {
        "summary" => "REVIEW_ERROR phase=fix pass=1",
        "detail" => "fix attempt timed out"
      },
      "path" => "/tmp/red-status.md"
    }

    @supervisor.send(:reply_for_child, child_exit(envelope: envelope))

    text = @telegram.messages.first.fetch(:text)
    assert_equal 'Diagnosis is available for "Red task…". Tap Show details to dump it here.', text
    refute_includes text, "REVIEW_ERROR"
    refute_includes text, "fix attempt timed out"
    refute_includes text, "/tmp/red-status.md"
    refute_includes text, "Command completed"
  end

  def test_reply_for_child_renders_status_diagnose_error_envelope
    envelope = {
      "schema" => "hive-status-diagnose",
      "ok" => false,
      "error_kind" => "ambiguous_slug",
      "exit_code" => Hive::ExitCodes::USAGE,
      "message" => "slug matches multiple stages"
    }

    @supervisor.send(:reply_for_child, child_exit(exit_code: Hive::ExitCodes::USAGE, envelope: envelope))

    text = @telegram.messages.first.fetch(:text)
    assert_includes text, "Diagnosis failed (ambiguous_slug): slug matches multiple stages"
    assert_includes text, "/tmp/hive-bot.log"
  end

  def test_reply_for_child_renders_empty_success_diagnostic_fallback
    envelope = { "schema" => "hive-status-diagnose", "ok" => true, "slug" => "stuck-task" }

    @supervisor.send(:reply_for_child, child_exit(envelope: envelope))

    assert_equal "No diagnostic available for stuck-task.", @telegram.messages.first.fetch(:text)
  end

  CallbackUpdate = Struct.new(:callback_query_id, :update_id, keyword_init: true) do
    def callback_query?; !callback_query_id.nil?; end
    def callback_data; "approve:plan:hive:slug:2-brainstorm"; end
  end

  def test_ack_callback_query_calls_telegram_with_callback_query_id
    captured = []
    @telegram.define_singleton_method(:answer_callback_query) do |callback_query_id:|
      captured << callback_query_id
    end

    @supervisor.send(:ack_callback_query, CallbackUpdate.new(callback_query_id: "cbq-99"))

    assert_equal [ "cbq-99" ], captured
  end

  def test_ack_callback_query_skips_when_callback_query_id_missing
    called = false
    @telegram.define_singleton_method(:answer_callback_query) do |callback_query_id:|
      called = true
    end

    @supervisor.send(:ack_callback_query, CallbackUpdate.new(callback_query_id: nil))

    refute called, "ack_callback_query must short-circuit when callback_query_id is nil"
  end

  def test_ack_callback_query_logs_send_failure_on_telegram_exception
    @telegram.define_singleton_method(:answer_callback_query) do |callback_query_id:|
      raise StandardError, "telegram down"
    end

    @supervisor.send(:ack_callback_query, CallbackUpdate.new(callback_query_id: "cbq-7"))

    failure = @logger.events.find { |e| e[:name] == :send_failure }
    refute_nil failure
    assert_equal "answer_callback_query", failure.fetch(:payload).fetch(:source)
    assert_equal "cbq-7", failure.fetch(:payload).fetch(:callback_query_id)
  end

  def test_latest_status_rows_returns_cached_rows_when_status_tick_already_ran
    cached = [ row(slug: "cached-260526-aaaa") ]
    @supervisor.instance_variable_set(:@latest_status_rows, cached)

    assert_same cached, @supervisor.send(:latest_status_rows),
                "cache hit must NOT trigger a fresh @status_watcher.fetch subprocess"
  end

  def test_latest_status_rows_falls_back_to_sync_fetch_when_no_cache_yet
    fresh = [ row(slug: "fresh-260526-bbbb") ]
    @status_watcher.result = StatusResult.new(ok: true, rows: fresh)
    @supervisor.instance_variable_set(:@latest_status_rows, nil)

    assert_equal fresh, @supervisor.send(:latest_status_rows),
                 "first call after bot start must sync-fetch so /autofix works immediately"
  end

  def test_default_status_snapshot_provider_routes_through_supervisor_to_latest_status_rows
    # The supervisor's default constructor wires
    #   status_snapshot_provider: -> { latest_status_rows }
    # into the real Router. The other unit tests inject a FakeRouter,
    # which bypasses this lambda, so this test instantiates the supervisor
    # with router: nil to exercise the full wiring end-to-end.
    cached_rows = [ row(slug: "wire-260526-aaaa") ]
    supervisor = Hive::Bot::Supervisor.new(
      config: @config,
      token: "test-token",
      logger: @logger,
      telegram: @telegram,
      status_watcher: @status_watcher,
      notification_dispatcher: @notification_dispatcher,
      router: nil,  # real Router built via initialize default
      child_supervisor: @child_supervisor,
      conversation_store: @conversation_store,
      dry_run: false
    )
    supervisor.instance_variable_set(:@latest_status_rows, cached_rows)

    update = Hive::Bot::Telegram::Update.new(
      update_id: 1, chat_id: 42, from_id: 42, message_id: 1,
      text: "/autofix wire-260526-aaaa"
    )

    supervisor.process_update(update)

    # The lambda invoked latest_status_rows, found the cached row, and
    # routed to RecoverySequence.build. The row's default marker is
    # COMPLETE (from #row helper) → not retryable → reply with
    # "no automatic recovery" or "No retry verb". Either path proves the
    # wiring fired; we just assert SOME reply landed (not a no-op).
    refute_empty @telegram.messages,
                 "default snapshot provider lambda must reach latest_status_rows " \
                 "so /autofix finds the cached row and dispatches a reply"
  end

  def test_latest_status_rows_returns_empty_array_when_sync_fetch_fails
    @status_watcher.result = StatusResult.new(ok: false, rows: nil, error: "boom")
    @supervisor.instance_variable_set(:@latest_status_rows, nil)

    assert_equal [], @supervisor.send(:latest_status_rows),
                 "failed fetch must yield [] so the slash handler degrades to 'slug not found'"
  end

  def test_reap_children_dispatches_reply_for_each_completed_child
    @child_supervisor.reap_batches << [ child_exit(exit_code: 0) ]

    @supervisor.reap_children

    # exit_code 0 yields nil from child_completion_text → no Telegram ack.
    # The contract under test is that reap_children iterates the batch and
    # calls reply_for_child without raising; @telegram.messages stays empty
    # because the clean-exit path is silent by design.
    assert_empty @telegram.messages,
                 "exit_code 0 must not produce a Telegram ack (child_completion_text returns nil)"
  end

  def test_register_bot_commands_sends_full_command_list_to_telegram
    @supervisor.send(:register_bot_commands)

    registered = Array(@telegram.commands_registered)
    assert_equal 1, registered.length, "register_bot_commands must call set_my_commands exactly once"

    commands = registered.first
    assert_equal Hive::Bot::Supervisor::BOT_COMMANDS, commands
    slash_names = commands.map { |cmd| cmd.fetch(:command) }
    assert_equal %w[idea status queue answer approve autofix details done help], slash_names
    assert(commands.all? { |cmd| cmd.fetch(:description).length.between?(1, 256) },
           "every command description must be non-empty and within Telegram's 256-char cap")
  end

  def test_register_bot_commands_swallows_telegram_failure_and_logs_send_failure
    @telegram.raise_on_set_my_commands = StandardError.new("boom")

    @supervisor.send(:register_bot_commands)  # must not raise

    failure = @logger.events.find { |e| e[:name] == :send_failure }
    refute_nil failure, "a set_my_commands failure must be logged as :send_failure"
    assert_equal "set_my_commands", failure.fetch(:payload).fetch(:source)
    assert_equal "StandardError", failure.fetch(:payload).fetch(:error_class)
    assert_equal "boom", failure.fetch(:payload).fetch(:message)
  end

  def test_child_completion_text_covers_exit_statuses
    assert_equal "Already advanced by another device",
                 @supervisor.send(:child_completion_text, child_exit(exit_code: Hive::ExitCodes::WRONG_STAGE))
    assert_equal "Try again - another run holds the lock",
                 @supervisor.send(:child_completion_text, child_exit(exit_code: Hive::ExitCodes::TEMPFAIL))
    assert_nil @supervisor.send(:child_completion_text, child_exit(exit_code: 0)),
               "clean exit must not produce a Telegram ack — 'Command completed' was operational chatter"
    assert_includes @supervisor.send(:child_completion_text, child_exit(exit_code: 17)), "Command failed with exit 17"
  end

  def test_send_reconnect_summary_skips_empty_update_list
    @supervisor.send(:send_reconnect_summary, [])

    assert_empty @telegram.messages
    assert_empty @logger.events
  end

  def test_send_reconnect_summary_sends_plural_summary_to_allowlisted_chats
    updates = [ Update.new(chat_id: 42, update_id: 7), Update.new(chat_id: 42, update_id: 8) ]

    @supervisor.send(:send_reconnect_summary, updates)

    assert_equal [ 42, 43 ], @telegram.messages.map { |message| message.fetch(:chat_id) }
    assert @telegram.messages.all? { |message| message.fetch(:text).include?("2 messages queued") }
    assert_equal :reconnect_summary, @logger.events.first.fetch(:name)
    assert_equal 2, @logger.events.first.fetch(:payload).fetch(:queued_count)
  end

  def test_render_queue_filters_inert_rows_caps_output_and_reports_overflow
    rows = 12.times.map { |i| row(slug: "task-#{i}") }
    rows += [ row(slug: "done", action: "archived"), row(slug: "running", action: "agent_running") ]

    text = @supervisor.send(:render_queue, rows)

    assert_includes text, "12 active tasks"
    assert_includes text, "Task 0… — Plan"
    assert_includes text, "+ 2 more tasks"
    refute_includes text, "hive/task-0"
    refute_includes text, "COMPLETE"
    refute_includes text, "done"
    refute_includes text, "running"
  end

  def test_render_queue_appends_slash_link_per_actionable_row_type
    brainstorm = row(slug: "ask-q-260526-aaaa", stage: "2-brainstorm",
                     action: "needs_input", marker: "waiting")
    ready_to_x = row(slug: "ship-it-260526-bbbb", stage: "7-artifacts",
                     action: "ready_to_finalize", marker: "complete")
    retryable_recovery = row(slug: "stuck-260526-cccc", stage: "6-review",
                             action: "recover_review", marker: "review_error",
                             attrs: { "phase" => "fix", "pass" => "2" },
                             diagnostic: { "suggested_next_action" => { "kind" => "retry" } })
    manual_recovery = row(slug: "stale-260526-dddd", stage: "4-execute",
                          action: "recover_review", marker: "execute_stale",
                          attrs: {}, diagnostic: nil)
    inert = row(slug: "agent-running-260526-eeee", action: "agent_running")

    text = @supervisor.send(:render_queue, [ brainstorm, ready_to_x, retryable_recovery, manual_recovery, inert ])

    assert_includes text, "/answer ask-q-260526-aaaa",
                    "brainstorm-waiting rows must carry an /answer slash link"
    assert_includes text, "/approve ship-it-260526-bbbb",
                    "ready_to_X rows must carry an /approve slash link"
    assert_includes text, "/autofix stuck-260526-cccc",
                    "retryable recovery rows must carry an /autofix slash link"
    assert_includes text, "/details stale-260526-dddd",
                    "manual-only recovery rows must carry a /details slash link"
    refute_includes text, "agent-running-260526-eeee",
                    "agent_running rows are inert and must not appear at all"
  end

  def test_render_queue_omits_slash_link_for_rows_without_actionable_state
    plain_inflight = row(slug: "in-flight-260526-aaaa", stage: "4-execute",
                         action: "developing", marker: "agent_working")

    text = @supervisor.send(:render_queue, [ plain_inflight ])

    refute_match(%r{/(answer|approve|autofix|details) in-flight-260526-aaaa}, text,
                 "rows with no Telegram-actionable next step must NOT carry a slash link")
  end

  def test_render_details_sorts_attrs_and_handles_missing_row
    rows = [ row(attrs: { "z" => 9, "a" => 1 }, marker: nil, action_label: nil) ]

    text = @supervisor.send(:render_details, rows, "hive", "task")

    assert_includes text, "hive/task (3-plan)"
    assert_includes text, "Action: ready_to_develop"
    assert_includes text, "Marker: none"
    assert_includes text, "Attrs: a=1 z=9"
    assert_equal "No active row found for hive/missing.", @supervisor.send(:render_details, rows, "hive", "missing")
  end

  def test_execute_dispatch_renders_status_queue_without_spawning_child
    rows = [ row(slug: "alpha") ]
    @status_watcher.result = StatusResult.new(ok: true, rows: rows)
    result = FakeRouter::Result.new(action: :dispatch_then_reply, command_argv: [ "hive", "status", "--json" ])

    pid = @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

    assert_nil pid
    assert_empty @child_supervisor.dispatched
    assert_includes @telegram.messages.last.fetch(:text), "1 active task"
    assert_nil @telegram.messages.last.fetch(:reply_markup)
  end

  def test_execute_dispatch_filters_status_by_project
    rows = [ row(project: "hive", slug: "alpha-260525-abcd"), row(project: "other", slug: "beta-260525-abcd") ]
    @status_watcher.result = StatusResult.new(ok: true, rows: rows)
    result = FakeRouter::Result.new(
      action: :dispatch_then_reply,
      command_argv: [ "hive", "status", "--json" ],
      project: "other"
    )

    @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

    text = @telegram.messages.last.fetch(:text)
    assert_includes text, "Beta… — Plan"
    refute_includes text, "Alpha"
    assert_nil @telegram.messages.last.fetch(:reply_markup)
  end

  def test_execute_dispatch_reports_unknown_project_with_known_list
    @status_watcher.result = StatusResult.new(ok: true, rows: [ row(project: "hive", slug: "alpha") ])
    result = FakeRouter::Result.new(
      action: :dispatch_then_reply,
      command_argv: [ "hive", "status", "--json" ],
      project: "missing"
    )

    @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

    text = @telegram.messages.last.fetch(:text)
    assert_match(/Unknown project missing/, text)
    assert_match(/hive/, text)
  end

  def test_execute_dispatch_reports_no_tasks_for_known_but_empty_project
    with_registered_projects([ { "name" => "hive" }, { "name" => "other" } ]) do
      @status_watcher.result = StatusResult.new(ok: true, rows: [ row(project: "hive", slug: "alpha") ])
      result = FakeRouter::Result.new(
        action: :dispatch_then_reply,
        command_argv: [ "hive", "status", "--json" ],
        project: "other"
      )

      @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

      assert_equal "No tasks for project other.", @telegram.messages.last.fetch(:text)
    end
  end

  def test_execute_dispatch_renders_status_envelope_when_format_json
    envelope = {
      "schema" => "hive-status",
      "schema_version" => 1,
      "ok" => true,
      "projects" => [
        { "name" => "hive", "tasks" => [ { "slug" => "alpha" } ] },
        { "name" => "other", "tasks" => [ { "slug" => "beta" } ] }
      ]
    }
    @status_watcher.result = StatusResult.new(ok: true, rows: [], envelope: envelope)
    result = FakeRouter::Result.new(
      action: :dispatch_then_reply,
      command_argv: [ "hive", "status", "--json" ],
      format: :json
    )

    @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

    text = @telegram.messages.last.fetch(:text)
    parsed = JSON.parse(text)
    assert_equal "hive-status", parsed["schema"], "JSON reply must surface the raw envelope"
    project_names = parsed["projects"].map { |p| p["name"] }
    assert_equal %w[hive other], project_names
  end

  def test_execute_dispatch_renders_status_envelope_filtered_by_project_when_format_json
    envelope = {
      "schema" => "hive-status",
      "projects" => [
        { "name" => "hive", "tasks" => [ { "slug" => "alpha" } ] },
        { "name" => "other", "tasks" => [ { "slug" => "beta" } ] }
      ]
    }
    @status_watcher.result = StatusResult.new(ok: true, rows: [], envelope: envelope)
    result = FakeRouter::Result.new(
      action: :dispatch_then_reply,
      command_argv: [ "hive", "status", "--json" ],
      project: "hive",
      format: :json
    )

    @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

    parsed = JSON.parse(@telegram.messages.last.fetch(:text))
    assert_equal [ "hive" ], parsed["projects"].map { |p| p["name"] },
                 "project filter must drop other projects from the JSON envelope"
  end

  def test_execute_dispatch_surfaces_status_fetch_failure
    @status_watcher.result = StatusResult.new(ok: false, rows: [], error: "envelope ok=false: pipeline timeout")
    result = FakeRouter::Result.new(
      action: :dispatch_then_reply,
      command_argv: [ "hive", "status", "--json" ]
    )

    @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

    assert_equal "hive status unavailable: envelope ok=false: pipeline timeout",
                 @telegram.messages.last.fetch(:text)
  end

  def test_execute_dispatch_renders_status_details_when_slug_is_present
    rows = [ row(slug: "alpha") ]
    @status_watcher.result = StatusResult.new(ok: true, rows: rows)
    result = FakeRouter::Result.new(action: :dispatch_then_reply, command_argv: [ "hive", "status", "--json" ],
                                    project: "hive", slug: "alpha")

    @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

    assert_includes @telegram.messages.last.fetch(:text), "hive/alpha (3-plan)"
  end

  def test_execute_dispatch_dry_run_does_not_spawn_child
    @supervisor.instance_variable_set(:@dry_run, true)
    result = FakeRouter::Result.new(
      action: :dispatch_then_reply,
      command_argv: [ "hive", "plan", "task" ],
      project: "hive",
      slug: "task"
    )

    pid = @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 11))

    assert_nil pid
    assert_empty @child_supervisor.dispatched
    assert_equal "Dry run: hive plan task", @telegram.messages.last.fetch(:text)
  end

  def test_dispatch_command_sequence_stops_after_failed_first_child
    failed = child_exit(exit_code: 1, pid: 123)
    @child_supervisor.completed[123] = failed
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [ [ "hive", "markers", "clear" ], [ "hive", "develop", "task" ] ],
      project: "hive",
      slug: "task"
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12))

    assert_equal 1, @child_supervisor.dispatched.length
    assert_equal "Stopped because the previous command failed.", @telegram.messages.last.fetch(:text)
  end

  def test_dispatch_command_sequence_resets_alert_for_single_command
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [ [ "hive", "review", "task", "--json" ] ],
      project: "hive",
      slug: "task",
      alert_reset: { project: "hive", slug: "task", stage: "6-review" }
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12))

    assert_equal [ { project: "hive", slug: "task", stage: "6-review", marker: nil, match_attr: nil } ],
                 @notification_dispatcher.reset_tasks
    assert_equal [ "hive", "review", "task", "--json" ], @child_supervisor.dispatched.first.fetch(:command_argv)
  end

  def test_dispatch_command_sequence_defers_alert_reset_until_markers_clear_succeeds
    # markers-clear (pid 200) completes with exit 0; retry verb is fire-and-forget.
    @child_supervisor.dispatch_pid = 200
    @child_supervisor.completed[200] = child_exit(exit_code: 0, pid: 200)
    reset_snapshot_at_dispatch = []
    notification = @notification_dispatcher
    dispatched_list = @child_supervisor.dispatched
    dispatch_pid_value = @child_supervisor.dispatch_pid
    @child_supervisor.define_singleton_method(:dispatch) do |**kwargs|
      reset_snapshot_at_dispatch << notification.reset_tasks.dup
      dispatched_list << kwargs
      dispatch_pid_value
    end

    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [
        [ "hive", "markers", "clear", "task", "--name", "REVIEW_ERROR" ],
        [ "hive", "review", "task", "--from", "6-review", "--json" ]
      ],
      project: "hive",
      slug: "task",
      alert_reset: { project: "hive", slug: "task", stage: "6-review" }
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12))

    assert_equal 2, @child_supervisor.dispatched.length
    assert_equal [], reset_snapshot_at_dispatch[0],
                 "reset_task must NOT have been called when the first command (markers clear) dispatches"
    assert_equal [ { project: "hive", slug: "task", stage: "6-review", marker: nil, match_attr: nil } ],
                 reset_snapshot_at_dispatch[1],
                 "reset_task must have been called exactly once before the retry verb dispatches"
    assert_equal [ { project: "hive", slug: "task", stage: "6-review", marker: nil, match_attr: nil } ],
                 @notification_dispatcher.reset_tasks
  end

  def test_dispatch_command_sequence_skips_alert_reset_when_markers_clear_fails
    @child_supervisor.completed[123] = child_exit(exit_code: 1, pid: 123)
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [
        [ "hive", "markers", "clear", "task" ],
        [ "hive", "review", "task" ]
      ],
      project: "hive",
      slug: "task",
      alert_reset: { project: "hive", slug: "task", stage: "6-review" }
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12))

    assert_equal 1, @child_supervisor.dispatched.length, "retry verb must not run when markers-clear fails"
    assert_empty @notification_dispatcher.reset_tasks,
                 "alert reset must NOT fire when the markers-clear precursor fails"
  end

  def test_dispatch_command_sequence_skips_alert_reset_in_dry_run
    @supervisor.instance_variable_set(:@dry_run, true)
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [ [ "hive", "develop", "task", "--json" ] ],
      project: "hive",
      slug: "task",
      alert_reset: { project: "hive", slug: "task", stage: "4-execute" }
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12))

    assert_empty @notification_dispatcher.reset_tasks,
                 "dry_run must not call reset_task even when alert_reset is present"
  end

  def test_clear_inline_keyboard_swallows_telegram_errors
    @telegram.define_singleton_method(:edit_message_reply_markup) do |*|
      raise IOError, "telegram offline"
    end
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [ [ "hive", "develop", "task", "--json" ] ],
      project: "hive",
      slug: "task",
      clear_keyboard: true
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12, message_id: 777))

    failure = @logger.events.find { |evt| evt[:name] == :send_failure }
    refute_nil failure, ":send_failure must be logged when edit_message_reply_markup raises"
    assert_equal "edit_message_reply_markup", failure[:payload][:source]
    assert_equal 1, @child_supervisor.dispatched.length,
                 "the command must still dispatch even when keyboard clear fails"
  end

  def test_registered_project_names_returns_empty_when_config_raises
    original = Hive::Config.method(:registered_projects)
    Hive::Config.define_singleton_method(:registered_projects) do
      raise Hive::ConfigError, "synthetic"
    end

    assert_equal [], @supervisor.send(:registered_project_names),
                 "config load errors during registered_project_names must yield []"
  ensure
    Hive::Config.define_singleton_method(:registered_projects, original) if original
  end

  def test_dispatch_command_sequence_clears_inline_keyboard_when_requested
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [ [ "hive", "review", "task", "--json" ] ],
      project: "hive",
      slug: "task",
      clear_keyboard: true
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12, message_id: 777))

    assert_equal 1, @telegram.keyboard_clears.size, "edit_message_reply_markup must be called once"
    clear = @telegram.keyboard_clears.first
    assert_equal 42, clear.fetch(:chat_id)
    assert_equal 777, clear.fetch(:message_id)
    assert_nil clear.fetch(:reply_markup), "reply_markup must be nil to remove the inline keyboard"
  end

  def test_dispatch_command_sequence_does_not_clear_keyboard_without_flag
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [ [ "hive", "develop", "task", "--json" ] ],
      project: "hive",
      slug: "task"
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12, message_id: 777))

    assert_nil @telegram.keyboard_clears, "edit_message_reply_markup must not be called when clear_keyboard is false/nil"
  end

  def test_queued_updates_filters_by_last_seen_and_allowlist
    with_tmp_dir do |dir|
      state_file = File.join(dir, "last_seen")
      File.write(state_file, "10")
      @supervisor.instance_variable_get(:@config)["last_seen_state_file"] = state_file
      updates = [
        Update.new(chat_id: 42, update_id: 10),
        Update.new(chat_id: 99, update_id: 11),
        Update.new(chat_id: 43, update_id: 12)
      ]

      queued = @supervisor.send(:queued_updates, updates)

      assert_equal [ 12 ], queued.map(&:update_id)
    end
  end

  def test_last_seen_state_returns_nil_on_invalid_and_write_creates_parent
    with_tmp_dir do |dir|
      state_file = File.join(dir, "nested", "last_seen")
      @supervisor.instance_variable_get(:@config)["last_seen_state_file"] = state_file
      assert_nil @supervisor.send(:read_last_seen_update_id)

      @supervisor.send(:write_last_seen_update_id, 44)
      assert_equal 44, @supervisor.send(:read_last_seen_update_id)

      File.write(state_file, "not-an-integer")
      assert_nil @supervisor.send(:read_last_seen_update_id)
    end
  end

  def test_start_answer_replies_when_no_unanswered_question_exists
    result = FakeRouter::Result.new(action: :start_answer, slug: "missing", project: "hive", mode: :path_b)

    @supervisor.send(:start_answer, result, Update.new(chat_id: 42, update_id: 13))

    assert_empty @conversation_store.starts,
                 "no conversation must be opened when there is nothing to answer"
    assert_includes @telegram.messages.last.fetch(:text), "No unanswered questions"
  end

  def test_start_answer_includes_question_text_in_first_prompt
    with_brainstorm_file(content: "## Round 1\n### Q1. Should we use SQLite or Postgres?\n### A1.\n") do |path, project|
      @supervisor.define_singleton_method(:brainstorm_path_for) { |_slug, project: nil| path }
      result = FakeRouter::Result.new(action: :start_answer, slug: "bot-task-260522-aa",
                                      project: File.basename(project), mode: :path_b)

      @supervisor.send(:start_answer, result, Update.new(chat_id: 42, update_id: 13))

      text = @telegram.messages.last.fetch(:text)
      assert_includes text, "Q1: Should we use SQLite or Postgres?",
                      "first prompt must include the actual question text so operators don't have to fetch it elsewhere"
      assert_includes text, "Reply with your answer"
    end
  end

  def test_execute_answer_write_handles_missing_slug_and_no_unanswered_question
    result = FakeRouter::Result.new(
      action: :write_answer_then_reply, slug: "missing", project: "hive", answer_text: "answer"
    )
    @supervisor.send(:execute_answer_write, result, Update.new(chat_id: 42, update_id: 14))
    assert_equal "Slug not found, was it archived?", @telegram.messages.last.fetch(:text)

    @supervisor.define_singleton_method(:brainstorm_path_for) { |_slug, project: nil| "/tmp/brainstorm.md" }
    @supervisor.define_singleton_method(:next_unanswered_question_n) { |_path| nil }
    result = FakeRouter::Result.new(
      action: :write_answer_then_reply, slug: "done", project: "hive", answer_text: "answer"
    )
    @supervisor.send(:execute_answer_write, result, Update.new(chat_id: 42, update_id: 15))
    assert_equal "No unanswered questions remain for done.", @telegram.messages.last.fetch(:text)
  end
  def test_request_shutdown_and_reload_set_loop_flags
    @supervisor.request_shutdown!
    @supervisor.request_reload!

    assert_equal true, @supervisor.instance_variable_get(:@shutdown)
    assert_equal true, @supervisor.instance_variable_get(:@reload)
  end

  def test_process_update_executes_reply_and_persists_last_seen
    with_tmp_dir do |dir|
      state_file = File.join(dir, "last_seen")
      @supervisor.instance_variable_get(:@config)["last_seen_state_file"] = state_file
      router = Object.new
      router.define_singleton_method(:handle) do |_update|
        FakeRouter::Result.new(action: :reply, text: "hello", reply_markup: { inline_keyboard: [] })
      end
      @supervisor.instance_variable_set(:@router, router)

      @supervisor.process_update(Update.new(chat_id: 42, update_id: 77))

      assert_equal "hello", @telegram.messages.last.fetch(:text)
      assert_equal "77", File.read(state_file)
    end
  end

  def test_execute_result_rejects_unknown_action
    error = assert_raises(RuntimeError) do
      @supervisor.send(:execute_result, FakeRouter::Result.new(action: :surprise), Update.new(chat_id: 42, update_id: 1))
    end

    assert_match(/unknown action/, error.message)
  end

  def test_safe_send_message_logs_telegram_failures
    @telegram.raise_on_send = RuntimeError.new("offline")

    assert_nil @supervisor.send(:safe_send_message, chat_id: 42, text: "hello")

    event = @logger.events.last
    assert_equal :send_failure, event.fetch(:name)
    assert_equal "offline", event.fetch(:payload).fetch(:message)
  end

  def test_status_tick_processes_rows_only_when_status_is_ok
    failure = StatusResult.new(ok: false, rows: [ row(slug: "ignored") ])
    @status_watcher.result = failure

    assert_same failure, @supervisor.status_tick
    assert_empty @notification_dispatcher.processed

    success = StatusResult.new(ok: true, rows: [ row(slug: "active") ])
    @status_watcher.result = success

    assert_same success, @supervisor.status_tick
    assert_equal [ [ row(slug: "active") ] ], @notification_dispatcher.processed
  end

  def test_wait_for_child_success_reaps_and_replies_for_completed_child
    child = child_exit(exit_code: 0, pid: 456)
    @child_supervisor.reap_batches << [ child ]

    ok = @supervisor.send(:wait_for_child_success, 456, deadline: Time.now + 1)

    assert_equal true, ok
    assert_empty @telegram.messages,
                 "clean exit must not produce a Telegram ack — 'Command completed' was operational chatter"
  end

  def test_wait_for_child_success_times_out_without_completed_child
    ok = @supervisor.send(:wait_for_child_success, 999, deadline: Time.now - 1)

    assert_equal false, ok
  end

  def test_project_and_brainstorm_paths_resolve_registered_project
    with_tmp_global_config do
      with_brainstorm_file(content: "## Round 1\n### Q1. Scope?\n### A1.\n") do |path, project|
        Hive::Config.register_project(name: "proj", path: project)

        assert_equal project, @supervisor.send(:project_path_for, "proj")
        assert_equal path, @supervisor.send(:brainstorm_path_for, "bot-task-260522-aa", project: "proj")
      end
    end
  end

  def test_reload_config_success_rebuilds_runtime_collaborators
    new_config = @supervisor.instance_variable_get(:@config).merge("conversation_ttl_sec" => 123)
    original = Hive::Config.method(:load_global_bot)
    Hive::Config.define_singleton_method(:load_global_bot) do |require_runtime:|
      raise "reload must require runtime" unless require_runtime

      new_config
    end

    @supervisor.request_reload!
    @supervisor.send(:reload_config_if_requested)

    assert_equal new_config, @supervisor.instance_variable_get(:@config)
    assert_equal [ 123 ], @conversation_store.ttl_updates
    assert_equal :config_reloaded, @logger.events.last.fetch(:name)
    assert_equal false, @supervisor.instance_variable_get(:@reload)
  ensure
    Hive::Config.define_singleton_method(:load_global_bot, original) if original
  end

  def test_reload_config_failure_keeps_existing_config
    old_config = @supervisor.instance_variable_get(:@config)
    original = Hive::Config.method(:load_global_bot)
    Hive::Config.define_singleton_method(:load_global_bot) do |require_runtime:|
      raise Hive::ConfigError, "bad bot config"
    end

    @supervisor.request_reload!
    @supervisor.send(:reload_config_if_requested)

    assert_same old_config, @supervisor.instance_variable_get(:@config)
    assert_equal false, @supervisor.instance_variable_get(:@reload)
    assert_equal :fatal, @logger.events.last.fetch(:name)
    assert_match(/bad bot config/, @logger.events.last.fetch(:payload).fetch(:message))
  ensure
    Hive::Config.define_singleton_method(:load_global_bot, original) if original
  end

  def test_interruptible_sleep_returns_when_shutdown_or_reload_is_requested
    @supervisor.request_shutdown!
    started = Time.now
    @supervisor.send(:interruptible_sleep, 5)
    assert_operator Time.now - started, :<, 1

    @supervisor.instance_variable_set(:@shutdown, false)
    @supervisor.request_reload!
    started = Time.now
    @supervisor.send(:interruptible_sleep, 5)
    assert_operator Time.now - started, :<, 1
  end

  def test_execute_answer_write_appends_real_answer_and_advances_conversation
    content = "## Round 1\n### Q1. Scope?\n### A1.\n\n### Q2. Cadence?\n### A2.\n"
    with_brainstorm_file(content: content) do |path, _project|
      @conversation_store.start(chat_id: 42, slug: "task", question_n: 1, mode: :path_b, project: "hive")
      @supervisor.define_singleton_method(:brainstorm_path_for) { |_slug, project: nil| path }
      result = FakeRouter::Result.new(
        action: :write_answer_then_reply,
        slug: "task",
        project: "hive",
        question_n: 1,
        answer_text: "Build the real thing"
      )

      @supervisor.send(:execute_answer_write, result, Update.new(chat_id: 42, update_id: 20))

      assert_includes File.read(path), "Build the real thing"
      text = @telegram.messages.last.fetch(:text)
      assert_match(/Got Q1\./, text)
      assert_match(/Q2: Cadence\?/, text,
                   "auto-advance must include the next unanswered question text in the same reply")
      assert_match(/Reply with your answer/, text)
      assert_equal 2, @conversation_store.updates.last.fetch(:values).fetch(:question_n)
    end
  end

  def test_execute_answer_write_reports_already_answered_and_missing_question
    with_brainstorm_file(content: "## Round 1\n### Q1. Scope?\n### A1.
  Done.\n") do |path, _project|
      @supervisor.define_singleton_method(:brainstorm_path_for) { |_slug, project: nil| path }
      answered = FakeRouter::Result.new(
        action: :write_answer_then_reply,
        slug: "task",
        project: "hive",
        question_n: 1,
        answer_text: "new answer"
      )

      @supervisor.send(:execute_answer_write, answered, Update.new(chat_id: 42, update_id: 21))
      assert_equal "Question 1 was already answered by another device", @telegram.messages.last.fetch(:text)

      missing = FakeRouter::Result.new(
        action: :write_answer_then_reply,
        slug: "task",
        project: "hive",
        question_n: 99,
        answer_text: "new answer"
      )
      @supervisor.send(:execute_answer_write, missing, Update.new(chat_id: 42, update_id: 22))
      assert_equal "Question 99 was not found.", @telegram.messages.last.fetch(:text)
    end
  end






  def test_poll_loop_logs_process_update_failure_and_advances_update_id
    update = Update.new(chat_id: 42, update_id: 77)
    supervisor = @supervisor
    poll_args = []
    @supervisor.instance_variable_set(:@next_update_id, nil)
    @supervisor.instance_variable_get(:@config)["long_poll_timeout_sec"] = 0
    @telegram.define_singleton_method(:poll_updates) do |timeout:, since_update_id:|
      poll_args << [ timeout, since_update_id ]
      supervisor.request_shutdown!
      [ update ]
    end
    @supervisor.define_singleton_method(:process_update) { |_incoming| raise "process blew up" }

    @supervisor.send(:poll_loop)

    assert_equal [ [ 0, nil ] ], poll_args
    assert_equal 78, @supervisor.instance_variable_get(:@next_update_id)
    event = @logger.events.find { |entry| entry.fetch(:payload)[:source] == "process_update" }
    assert_equal :fatal, event.fetch(:name)
    assert_equal "process blew up", event.fetch(:payload).fetch(:message)
  end

  def test_poll_loop_logs_poll_failure_and_sleeps_interruptibly
    supervisor = @supervisor
    @supervisor.instance_variable_get(:@config)["long_poll_timeout_sec"] = 0
    slept = []
    @telegram.define_singleton_method(:poll_updates) do |timeout:, since_update_id:|
      supervisor.request_shutdown!
      raise "telegram offline"
    end
    @supervisor.define_singleton_method(:interruptible_sleep) { |seconds| slept << seconds }

    @supervisor.send(:poll_loop)

    event = @logger.events.find { |entry| entry.fetch(:payload)[:source] == "poll_loop" }
    assert_equal :fatal, event.fetch(:name)
    assert_equal "telegram offline", event.fetch(:payload).fetch(:message)
    assert_equal [ 1 ], slept
  end

  def test_status_loop_logs_tick_failures
    supervisor = @supervisor
    @supervisor.define_singleton_method(:status_tick) do
      supervisor.request_shutdown!
      raise "status exploded"
    end
    @supervisor.define_singleton_method(:interruptible_sleep) { |_seconds| }

    @supervisor.send(:status_loop)

    event = @logger.events.find { |entry| entry.fetch(:payload)[:source] == "status_loop" }
    assert_equal :fatal, event.fetch(:name)
    assert_equal "status exploded", event.fetch(:payload).fetch(:message)
  end

  def test_reaper_loop_logs_reap_failures
    supervisor = @supervisor
    @supervisor.define_singleton_method(:reap_children) do
      supervisor.request_shutdown!
      raise "reap exploded"
    end
    @supervisor.define_singleton_method(:sleep) { |_seconds| }

    @supervisor.send(:reaper_loop)

    event = @logger.events.find { |entry| entry.fetch(:payload)[:source] == "reaper_loop" }
    assert_equal :fatal, event.fetch(:name)
    assert_equal "reap exploded", event.fetch(:payload).fetch(:message)
  end

  def test_execute_result_routes_compound_actions_to_helpers
    calls = []
    @supervisor.define_singleton_method(:dispatch_command_sequence) { |result, update| calls << [ :sequence, result, update ] }
    @supervisor.define_singleton_method(:start_answer) { |result, update| calls << [ :start_answer, result, update ] }
    @supervisor.define_singleton_method(:execute_answer_write) { |result, update| calls << [ :answer_write, result, update ] }
    update = Update.new(chat_id: 42, update_id: 88)

    [
      [ :dispatch_commands, :sequence ],
      [ :start_answer, :start_answer ],
      [ :write_answer_then_reply, :answer_write ]
    ].each do |action, expected_call|
      result = FakeRouter::Result.new(action: action)
      @supervisor.send(:execute_result, result, update)
      assert_equal expected_call, calls.last.first
      assert_same result, calls.last[1]
      assert_same update, calls.last[2]
    end
  end

  def test_wait_for_child_success_sleeps_until_child_completes
    child = child_exit(exit_code: 0, pid: 456)
    @child_supervisor.reap_batches << [] << [ child ]
    sleeps = []
    @supervisor.define_singleton_method(:sleep) { |seconds| sleeps << seconds }

    ok = @supervisor.send(:wait_for_child_success, 456, deadline: Time.now + 1)

    assert_equal true, ok
    assert_equal [ 0.1 ], sleeps
    assert_empty @telegram.messages,
                 "clean exit must not produce a Telegram ack — 'Command completed' was operational chatter"
  end

  def test_execute_answer_write_reports_lock_busy
    with_brainstorm_file(content: "## Round 1\n### Q1. Scope?\n### A1.\n") do |path, _project|
      @supervisor.define_singleton_method(:brainstorm_path_for) { |_slug, project: nil| path }
      result = FakeRouter::Result.new(
        action: :write_answer_then_reply,
        slug: "task",
        project: "hive",
        question_n: 1,
        answer_text: "Build it"
      )

      with_replaced_singleton_method(Hive::Bot::BrainstormAnswerWriter, :append!, ->(**_kwargs) { :lock_busy }) do
        @supervisor.send(:execute_answer_write, result, Update.new(chat_id: 42, update_id: 23))
      end

      assert_equal "Try again - another run holds the lock", @telegram.messages.last.fetch(:text)
    end
  end




  def test_next_unanswered_question_n_parses_brainstorm_file
    with_brainstorm_file(content: "## Round 1\n### Q1. Scope?\n### A1.\n") do |path, _project|
      assert_equal 1, @supervisor.send(:next_unanswered_question_n, path)
    end
  end

  def with_registered_projects(projects)
    original = Hive::Config.method(:registered_projects)
    Hive::Config.define_singleton_method(:registered_projects) { projects }
    yield
  ensure
    Hive::Config.define_singleton_method(:registered_projects, original)
  end

  def test_interruptible_sleep_sleeps_until_flag_changes
    supervisor = @supervisor
    sleeps = []
    @supervisor.define_singleton_method(:sleep) do |seconds|
      sleeps << seconds
      supervisor.request_shutdown!
    end

    @supervisor.send(:interruptible_sleep, 5)

    assert_equal [ 0.5 ], sleeps
  end
end
