require "test_helper"
require "hive/bot/supervisor"

class HiveBotSupervisorTest < Minitest::Test
  include HiveTestHelper

  ChildExit = Hive::Bot::ChildSupervisor::ChildExit
  Update = Struct.new(:chat_id, :update_id, keyword_init: true)
  Row = Struct.new(:project, :slug, :stage, :action, :action_label, :marker, :attrs, keyword_init: true)
  StatusResult = Struct.new(:ok, :rows, keyword_init: true)

  FakeTelegram = Struct.new(:messages, keyword_init: true) do
    def send_message(chat_id:, text:, reply_markup: nil)
      messages << { chat_id: chat_id, text: text, reply_markup: reply_markup }
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

  class FakeRouter
    Result = Struct.new(:action, :text, :reply_markup, :command_argv, :commands, :project, :slug,
                        :question_n, :answer_text, :mode, keyword_init: true)
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

  FakeConversationStore = Struct.new(:starts, :updates, :states, keyword_init: true) do
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

    def update_ttl(_ttl); end
  end

  def setup
    @telegram = FakeTelegram.new(messages: [])
    @logger = FakeLogger.new(events: [])
    @status_watcher = FakeStatusWatcher.new(result: StatusResult.new(ok: true, rows: []))
    @child_supervisor = FakeChildSupervisor.new(dispatch_pid: 123, dispatched: [], completed: {}, reap_batches: [])
    @conversation_store = FakeConversationStore.new(starts: [], updates: [], states: {})
    @supervisor = Hive::Bot::Supervisor.allocate
    @supervisor.instance_variable_set(:@telegram, @telegram)
    @supervisor.instance_variable_set(:@logger, @logger)
    @supervisor.instance_variable_set(:@status_watcher, @status_watcher)
    @supervisor.instance_variable_set(:@child_supervisor, @child_supervisor)
    @supervisor.instance_variable_set(:@conversation_store, @conversation_store)
    @supervisor.instance_variable_set(:@router, FakeRouter.new)
    @supervisor.instance_variable_set(:@dry_run, false)
    @supervisor.instance_variable_set(:@config, {
      "chat_id_allowlist" => [ 42, 43 ],
      "clear_retry_grace_sec" => 1,
      "conversation_ttl_sec" => 60,
      "poll_interval_sec" => 1
    })
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
    assert_includes text, "REVIEW_ERROR phase=fix pass=1"
    assert_includes text, "fix attempt timed out"
    assert_includes text, "Path: /tmp/red-status.md"
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
    assert_includes text, "hive/task-0 3-plan Develop COMPLETE"
    assert_includes text, "+ 2 more tasks"
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
    refute_nil @telegram.messages.last.fetch(:reply_markup)
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
end
