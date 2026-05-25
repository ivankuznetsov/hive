require "test_helper"
require "hive/bot/supervisor"

class HiveBotSupervisorTest < Minitest::Test
  include HiveTestHelper

  ChildExit = Hive::Bot::ChildSupervisor::ChildExit
  Update = Struct.new(:chat_id, :update_id, :message_id, keyword_init: true)
  Row = Struct.new(:project, :slug, :stage, :action, :action_label, :marker, :attrs, keyword_init: true)
  StatusResult = Struct.new(:ok, :rows, :error, keyword_init: true)

  FakeTelegram = Struct.new(:messages, :raise_on_send, :keyboard_clears, keyword_init: true) do
    def send_message(chat_id:, text:, reply_markup: nil)
      raise raise_on_send if raise_on_send

      messages << { chat_id: chat_id, text: text, reply_markup: reply_markup }
    end

    def edit_message_reply_markup(chat_id:, message_id:, reply_markup: nil)
      (self.keyboard_clears ||= []) << { chat_id: chat_id, message_id: message_id, reply_markup: reply_markup }
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
                        :question_n, :answer_text, :mode, :alert_reset, :clear_keyboard, keyword_init: true)
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
          action_label: "Develop", marker: "COMPLETE", attrs: {})
    Row.new(project: project, slug: slug, stage: stage, action: action,
            action_label: action_label, marker: marker, attrs: attrs)
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
    assert_equal 'Diagnosis is available for "Red task…". Open this task on a laptop for full details.', text
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

  def test_child_completion_text_covers_exit_statuses
    assert_equal "Already advanced by another device",
                 @supervisor.send(:child_completion_text, child_exit(exit_code: Hive::ExitCodes::WRONG_STAGE))
    assert_equal "Try again - another run holds the lock",
                 @supervisor.send(:child_completion_text, child_exit(exit_code: Hive::ExitCodes::TEMPFAIL))
    assert_equal "Command completed", @supervisor.send(:child_completion_text, child_exit(exit_code: 0))
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
      command_argv: [ "hive", "status", "--json", "--project", "other" ],
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
      command_argv: [ "hive", "status", "--json", "--project", "missing" ],
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
        command_argv: [ "hive", "status", "--json", "--project", "other" ],
        project: "other"
      )

      @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

      assert_equal "No tasks for project other.", @telegram.messages.last.fetch(:text)
    end
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

  def test_start_answer_records_conversation_with_default_question_when_slug_missing
    result = FakeRouter::Result.new(action: :start_answer, slug: "missing", project: "hive", mode: :path_b)

    @supervisor.send(:start_answer, result, Update.new(chat_id: 42, update_id: 13))

    assert_equal(
      { chat_id: 42, slug: "missing", question_n: 1, mode: :path_b, project: "hive" },
      @conversation_store.starts.last
    )
    assert_includes @telegram.messages.last.fetch(:text), "Send Q1's answer"
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
    assert_equal "Command completed", @telegram.messages.last.fetch(:text)
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
      assert_equal "Got Q1.", @telegram.messages.last.fetch(:text)
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

  def test_execute_start_codex_creates_draft_and_keyboard
    with_brainstorm_file(content: "## Round 1\n### Q1. Scope?\n### A1.\n") do |path, _project|
      conversation = FakeCodexConversation.new(
        outcome: Outcome.new(kind: :draft_ready, draft: "Use focused tests."),
        calls: []
      )
      @supervisor.define_singleton_method(:brainstorm_path_for) { |_slug, project: nil| path }
      @supervisor.define_singleton_method(:codex_conversation) { conversation }
      result = FakeRouter::Result.new(
        action: :start_codex,
        slug: "bot-task-260522-aa",
        project: "hive",
        answer_text: "draft it"
      )

      @supervisor.send(:execute_start_codex, result, Update.new(chat_id: 42, update_id: 30))

      assert_equal 1, conversation.calls.length
      assert_kind_of Hive::Task, conversation.calls.first.fetch(:task)
      assert_equal "draft it", conversation.calls.first.fetch(:user_input)
      assert_equal "Codex draft for Q1:\nUse focused tests.", @telegram.messages.last.fetch(:text)
      assert_equal "codex_write:hive:bot-task-260522-aa:1",
                   @telegram.messages.last.fetch(:reply_markup).first.first.fetch(:callback_data)
      state = @conversation_store.get(chat_id: 42, slug: "bot-task-260522-aa")
      assert_equal true, state.awaiting_confirm
      assert_equal "Use focused tests.", state.draft
    end
  end

  def test_execute_start_codex_sends_reply_and_failure_without_draft
    with_brainstorm_file(content: "## Round 1\n### Q1. Scope?\n### A1.\n") do |path, _project|
      @supervisor.define_singleton_method(:brainstorm_path_for) { |_slug, project: nil| path }
      conversation = FakeCodexConversation.new(outcome: Outcome.new(kind: :reply, text: "Need more context."), calls: [])
      @supervisor.define_singleton_method(:codex_conversation) { conversation }
      result = FakeRouter::Result.new(action: :start_codex, slug: "bot-task-260522-aa", project: "hive")

      @supervisor.send(:execute_start_codex, result, Update.new(chat_id: 42, update_id: 31))
      assert_equal "Need more context.", @telegram.messages.last.fetch(:text)
      state = @conversation_store.get(chat_id: 42, slug: "bot-task-260522-aa")
      assert_equal false, state.awaiting_confirm

      conversation.outcome = Outcome.new(kind: :failed, reason: "budget_exhausted")
      @supervisor.send(:execute_start_codex, result, Update.new(chat_id: 42, update_id: 32))
      assert_equal "Codex failed: budget_exhausted. Send your answer directly.", @telegram.messages.last.fetch(:text)
    end
  end

  def test_execute_start_codex_handles_missing_path_and_no_questions
    missing = FakeRouter::Result.new(action: :start_codex, slug: "missing", project: "hive")
    @supervisor.send(:execute_start_codex, missing, Update.new(chat_id: 42, update_id: 33))
    assert_equal "Slug not found, was it archived?", @telegram.messages.last.fetch(:text)

    with_brainstorm_file(content: "## Round 1\n### Q1. Scope?\n### A1.
  Done.\n") do |path, _project|
      @supervisor.define_singleton_method(:brainstorm_path_for) { |_slug, project: nil| path }
      done = FakeRouter::Result.new(action: :start_codex, slug: "done", project: "hive")

      @supervisor.send(:execute_start_codex, done, Update.new(chat_id: 42, update_id: 34))
      assert_equal "No unanswered questions remain for done.", @telegram.messages.last.fetch(:text)
    end
  end

  def test_execute_confirm_codex_draft_writes_answer_and_advances
    content = "## Round 1\n### Q1. Scope?\n### A1.\n\n### Q2. Cadence?\n### A2.\n"
    with_brainstorm_file(content: content) do |path, _project|
      @conversation_store.start(chat_id: 42, slug: "task", question_n: 1, mode: :path_a, project: "hive")
      @conversation_store.update(chat_id: 42, slug: "task", draft: "Real answer", awaiting_confirm: true)
      @supervisor.define_singleton_method(:brainstorm_path_for) { |_slug, project: nil| path }
      result = FakeRouter::Result.new(action: :confirm_codex_draft, slug: "task", project: "hive", question_n: 1)

      @supervisor.send(:execute_confirm_codex_draft, result, Update.new(chat_id: 42, update_id: 40))

      assert_includes File.read(path), "Real answer"
      assert_equal "Draft saved as Q1.", @telegram.messages.last.fetch(:text)
      state = @conversation_store.get(chat_id: 42, slug: "task")
      assert_nil state.draft
      assert_equal false, state.awaiting_confirm
      assert_equal 2, @conversation_store.updates.last.fetch(:values).fetch(:question_n)
    end
  end

  def test_execute_confirm_codex_draft_reports_empty_missing_and_already_answered
    empty = FakeRouter::Result.new(action: :confirm_codex_draft, slug: "empty", project: "hive", question_n: 1)
    @supervisor.send(:execute_confirm_codex_draft, empty, Update.new(chat_id: 42, update_id: 41))
    assert_equal "No draft to confirm for empty.", @telegram.messages.last.fetch(:text)

    @conversation_store.start(chat_id: 42, slug: "missing", question_n: 1, mode: :path_a, project: "hive")
    @conversation_store.update(chat_id: 42, slug: "missing", draft: "Draft", awaiting_confirm: true)
    missing = FakeRouter::Result.new(action: :confirm_codex_draft, slug: "missing", project: "hive", question_n: 1)
    @supervisor.send(:execute_confirm_codex_draft, missing, Update.new(chat_id: 42, update_id: 42))
    assert_equal "Slug not found, was it archived?", @telegram.messages.last.fetch(:text)

    with_brainstorm_file(content: "## Round 1\n### Q1. Scope?\n### A1.
  Done.\n") do |path, _project|
      @conversation_store.start(chat_id: 42, slug: "answered", question_n: 1, mode: :path_a, project: "hive")
      @conversation_store.update(chat_id: 42, slug: "answered", draft: "Draft", awaiting_confirm: true)
      @supervisor.define_singleton_method(:brainstorm_path_for) { |_slug, project: nil| path }
      answered = FakeRouter::Result.new(action: :confirm_codex_draft, slug: "answered", project: "hive", question_n: 1)

      @supervisor.send(:execute_confirm_codex_draft, answered, Update.new(chat_id: 42, update_id: 43))
      assert_equal "Question 1 was already answered by another device", @telegram.messages.last.fetch(:text)
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
    @supervisor.define_singleton_method(:execute_start_codex) { |result, update| calls << [ :start_codex, result, update ] }
    @supervisor.define_singleton_method(:execute_confirm_codex_draft) { |result, update| calls << [ :confirm_codex, result, update ] }
    update = Update.new(chat_id: 42, update_id: 88)

    [
      [ :dispatch_commands, :sequence ],
      [ :start_answer, :start_answer ],
      [ :write_answer_then_reply, :answer_write ],
      [ :start_codex, :start_codex ],
      [ :confirm_codex_draft, :confirm_codex ]
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
    assert_equal "Command completed", @telegram.messages.last.fetch(:text)
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

  def test_execute_confirm_codex_draft_reports_lock_busy
    with_brainstorm_file(content: "## Round 1\n### Q1. Scope?\n### A1.\n") do |path, _project|
      @conversation_store.start(chat_id: 42, slug: "task", question_n: 1, mode: :path_a, project: "hive")
      @conversation_store.update(chat_id: 42, slug: "task", draft: "Draft", awaiting_confirm: true)
      @supervisor.define_singleton_method(:brainstorm_path_for) { |_slug, project: nil| path }
      result = FakeRouter::Result.new(action: :confirm_codex_draft, slug: "task", project: "hive", question_n: 1)

      with_replaced_singleton_method(Hive::Bot::BrainstormAnswerWriter, :append!, ->(**_kwargs) { :lock_busy }) do
        @supervisor.send(:execute_confirm_codex_draft, result, Update.new(chat_id: 42, update_id: 44))
      end

      assert_equal "Try again - another run holds the lock", @telegram.messages.last.fetch(:text)
    end
  end

  def test_execute_confirm_codex_draft_reports_missing_question
    with_brainstorm_file(content: "## Round 1\n### Q1. Scope?\n### A1.\n") do |path, _project|
      @conversation_store.start(chat_id: 42, slug: "task", question_n: 99, mode: :path_a, project: "hive")
      @conversation_store.update(chat_id: 42, slug: "task", draft: "Draft", awaiting_confirm: true)
      @supervisor.define_singleton_method(:brainstorm_path_for) { |_slug, project: nil| path }
      result = FakeRouter::Result.new(action: :confirm_codex_draft, slug: "task", project: "hive", question_n: 99)

      @supervisor.send(:execute_confirm_codex_draft, result, Update.new(chat_id: 42, update_id: 45))

      assert_equal "Question 99 was not found.", @telegram.messages.last.fetch(:text)
    end
  end

  def test_codex_conversation_memoizes_default_conversation
    first = @supervisor.send(:codex_conversation)
    second = @supervisor.send(:codex_conversation)

    assert_kind_of Hive::Bot::CodexConversation, first
    assert_same first, second
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
