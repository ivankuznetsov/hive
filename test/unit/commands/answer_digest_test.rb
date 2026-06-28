require "test_helper"
require "hive/commands/answer_digest"
require "hive/bot/status_watcher"
require "hive/bot/row_actions"
require "hive/bot/notification_builders"

class HiveCommandsAnswerDigestTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Bot::StatusWatcher::Row
  FetchResult = Struct.new(:ok, :rows, :error, keyword_init: true)

  StubStatusWatcher = Struct.new(:result, :fetch_count, keyword_init: true) do
    def fetch
      self.fetch_count = fetch_count.to_i + 1
      result
    end
  end

  StubTelegram = Struct.new(:messages, keyword_init: true) do
    def send_message(chat_id:, text:, reply_markup: nil, parse_mode: nil)
      messages << { chat_id: chat_id, text: text, reply_markup: reply_markup, parse_mode: parse_mode }
      [ { "message_id" => messages.length } ]
    end
  end

  StubEnvLoader = Struct.new(:calls, keyword_init: true) do
    def load!
      calls << :load
    end
  end

  CapturingLogger = Struct.new(:events, keyword_init: true) do
    def event(name, **payload)
      events << { name: name, payload: payload }
    end
  end

  def row(slug:, action: "needs_input", marker: "waiting", stage: "2-brainstorm", attrs: {},
          workflow: "coding", id: nil, display_name: nil, project_path: "/tmp/hive", pr_url: nil)
    Row.new(
      project: "hive",
      project_path: project_path,
      hive_state_path: File.join(project_path, ".hive-state"),
      slug: slug,
      id: id,
      display_name: display_name,
      stage: stage,
      workflow: workflow,
      marker: marker,
      attrs: attrs,
      folder: File.join(project_path, ".hive-state", "stages", stage, slug),
      state_file: File.join(project_path, ".hive-state", "stages", stage, slug, "task.md"),
      pr_url: pr_url,
      action: action,
      action_label: "Needs input",
      suggested_command: nil,
      diagnostic: nil
    )
  end

  def cfg(chat_ids: [ 4242 ])
    { "bot" => { "chat_id_allowlist" => chat_ids, "log_file" => "/tmp/hive-bot.log" } }
  end

  def command(rows:, output: StringIO.new, dry_run: false, json: false, config: cfg, telegram: StubTelegram.new(messages: []))
    watcher = StubStatusWatcher.new(result: FetchResult.new(ok: true, rows: rows))
    env_loader = StubEnvLoader.new(calls: [])
    cmd = Hive::Commands::AnswerDigest.new(
      date: "2026-06-27",
      dry_run: dry_run,
      json: json,
      output: output,
      cfg: config,
      status_watcher: watcher,
      env_loader: env_loader,
      telegram_factory: ->(token:, logger:) { telegram }
    )
    [ cmd, watcher, env_loader, telegram ]
  end

  def test_empty_waiting_set_sends_nothing_and_reports_empty_json
    output = StringIO.new
    cmd, _watcher, _env_loader, telegram = command(rows: [], output: output, json: true)

    result = cmd.call

    assert_equal false, result.sent
    assert_empty telegram.messages
    payload = JSON.parse(output.string)
    assert_equal false, payload.fetch("sent")
    assert_equal "empty", payload.fetch("reason")
    assert_equal "2026-06-27", payload.fetch("date")
  end

  def test_empty_dry_run_json_emits_null_message_not_empty_string
    output = StringIO.new
    cmd, = command(rows: [], output: output, dry_run: true, json: true)

    result = cmd.call

    assert_equal false, result.sent
    assert_equal "empty", result.reason
    payload = JSON.parse(output.string)
    assert_nil payload.fetch("message"),
               "an empty waiting set must emit message: null even under --dry-run, matching the schema"
  end

  def test_non_empty_waiting_set_sends_one_message_with_buttons
    output = StringIO.new
    telegram = StubTelegram.new(messages: [])
    waiting = row(
      slug: "answer-me-260625-abcd",
      id: 9281,
      display_name: "Answer Me",
      pr_url: "https://github.com/example/repo/pull/17"
    )
    cmd, _watcher, env_loader, _telegram = command(rows: [ waiting ], output: output, telegram: telegram)

    with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
      result = cmd.call

      assert_equal true, result.sent
    end

    assert_equal [ :load ], env_loader.calls
    assert_equal 1, telegram.messages.length
    message = telegram.messages.first
    assert_equal 4242, message.fetch(:chat_id)
    assert_includes message.fetch(:text), "⏳ Waiting on you (1)"
    assert_includes message.fetch(:text), "#9281 Answer Me — #17 — Brainstorm"
    assert_nil message.fetch(:parse_mode)
    buttons = message.fetch(:reply_markup).flatten
    assert_equal [ "answer:hive:answer-me-260625-abcd" ], buttons.map { |button| button.fetch(:callback_data) }
  end

  def test_dry_run_sends_nothing_and_does_not_require_chat_or_token
    output = StringIO.new
    cmd, _watcher, env_loader, telegram = command(
      rows: [ row(slug: "answer-me-260625-abcd") ],
      output: output,
      dry_run: true,
      config: cfg(chat_ids: [])
    )

    result = cmd.call

    assert_equal false, result.sent
    assert_equal "dry_run", result.reason
    assert_empty telegram.messages
    assert_empty env_loader.calls
    assert_includes output.string, "Waiting on you"
    assert_includes output.string, "Buttons: 1"
  end

  def test_missing_chat_id_raises_config_error_for_non_empty_real_send
    cmd, _watcher, _env_loader, _telegram = command(
      rows: [ row(slug: "answer-me-260625-abcd") ],
      config: cfg(chat_ids: [])
    )

    error = assert_raises(Hive::ConfigError) do
      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") { cmd.call }
    end
    assert_match(/bot\.chat_id_allowlist/, error.message)
  end

  def test_overflow_caps_buttons_and_adds_more_line
    output = StringIO.new
    telegram = StubTelegram.new(messages: [])
    rows = 11.times.map { |i| row(slug: "waiting-#{i}-260625-abcd", display_name: "Waiting #{i}") }
    cmd, _watcher, _env_loader, _telegram = command(rows: rows, output: output, telegram: telegram)

    with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") { cmd.call }

    message = telegram.messages.first
    assert_includes message.fetch(:text), "+ 1 more tasks"
    assert_equal 10, message.fetch(:reply_markup).flatten.length
  end

  def test_json_overflow_reports_full_count_capped_buttons_and_all_tasks
    output = StringIO.new
    telegram = StubTelegram.new(messages: [])
    rows = 11.times.map { |i| row(slug: "waiting-#{i}-260625-abcd", display_name: "Waiting #{i}") }
    cmd, = command(rows: rows, output: output, json: true, telegram: telegram)

    with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") { cmd.call }

    payload = JSON.parse(output.string)
    assert_equal 11, payload.fetch("count"), "JSON count must report the true backlog, not the display cap"
    assert_equal 10, payload.fetch("button_count"), "buttons stay capped at the 10-task display slice"
    assert_equal 11, payload.fetch("tasks").length, "tasks[] must list every waiting task, not the capped slice"
    assert_includes telegram.messages.first.fetch(:text), "⏳ Waiting on you (11)"
  end

  def test_real_send_plain_text_reports_total_count_not_button_cap
    output = StringIO.new
    telegram = StubTelegram.new(messages: [])
    rows = 11.times.map { |i| row(slug: "waiting-#{i}-260625-abcd") }
    cmd, = command(rows: rows, output: output, telegram: telegram)

    with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") { cmd.call }

    assert_includes output.string, "sent 11 waiting tasks",
                    "the plain-text line must report the true backlog total, not the 10-button cap"
  end

  def test_real_send_plain_text_uses_singular_for_one_task
    output = StringIO.new
    telegram = StubTelegram.new(messages: [])
    cmd, = command(rows: [ row(slug: "answer-me-260625-abcd") ], output: output, telegram: telegram)

    with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") { cmd.call }

    assert_includes output.string, "sent 1 waiting task\n"
    refute_includes output.string, "sent 1 waiting tasks"
  end

  def test_digest_keyboard_nests_one_button_per_row
    output = StringIO.new
    telegram = StubTelegram.new(messages: [])
    rows = 3.times.map { |i| row(slug: "waiting-#{i}-260625-abcd") }
    cmd, = command(rows: rows, output: output, telegram: telegram)

    with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") { cmd.call }

    keyboard = telegram.messages.first.fetch(:reply_markup)
    assert_equal 3, keyboard.length
    assert(keyboard.all? { |kbd_row| kbd_row.length == 1 },
           "each inline-keyboard row must hold exactly one button")
  end

  def test_digest_button_callback_is_byte_identical_to_row_actions_primary
    output = StringIO.new
    telegram = StubTelegram.new(messages: [])
    waiting = row(slug: "answer-me-260625-abcd", id: 9281, display_name: "Answer Me")
    cmd, = command(rows: [ waiting ], output: output, telegram: telegram)

    with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") { cmd.call }

    primary = Hive::Bot::RowActions.resolve(waiting).primary
    expected = Hive::Bot::NotificationBuilders.button("x", primary.callback).fetch(:callback_data)
    sent = telegram.messages.first.fetch(:reply_markup).flatten.first.fetch(:callback_data)
    assert_equal expected, sent,
                 "the digest button callback must derive from the same RowActions primary " \
                 "(through the same compaction) as /waiting and the push button"
  end

  def test_invalid_date_emits_json_error_then_reraises
    output = StringIO.new
    cmd, = command(rows: [], output: output, json: true)

    assert_raises(Hive::ConfigError) { cmd.call([ "--date", "06/27/2026", "--json" ]) }

    payload = JSON.parse(output.string)
    assert_equal false, payload.fetch("ok")
    assert_equal "config", payload.fetch("error_kind")
    assert_match(/YYYY-MM-DD/, payload.fetch("message"))
  end

  def test_well_formed_but_impossible_date_raises_config_error
    cmd, = command(rows: [])

    error = assert_raises(Hive::ConfigError) { cmd.call([ "--date", "2026-13-45" ]) }

    assert_match(/YYYY-MM-DD/, error.message)
  end

  def test_call_argv_parses_dry_run_json_and_uses_default_date
    output = StringIO.new
    cmd = Hive::Commands::AnswerDigest.new(
      dry_run: false,
      output: output,
      cfg: cfg(chat_ids: []),
      status_watcher: StubStatusWatcher.new(result: FetchResult.new(ok: true, rows: [ row(slug: "answer-me-260625-abcd") ])),
      env_loader: StubEnvLoader.new(calls: []),
      telegram_factory: ->(token:, logger:) { StubTelegram.new(messages: []) },
      now: -> { Time.local(2026, 6, 28, 9, 0, 0) }
    )

    result = cmd.call([ "--dry-run", "--json" ])

    payload = JSON.parse(output.string)
    assert_equal Date.new(2026, 6, 28), result.date
    assert_equal "2026-06-28", payload.fetch("date")
    assert_equal "dry_run", payload.fetch("reason")
    assert_includes payload.fetch("message"), "Waiting on you"
  end

  def test_call_argv_rejects_unknown_option
    cmd, = command(rows: [])

    error = assert_raises(Hive::ConfigError) { cmd.call([ "--bogus" ]) }

    assert_match(/invalid option/, error.message)
  end

  def test_call_argv_rejects_unexpected_positional_argument
    cmd, = command(rows: [])

    error = assert_raises(Hive::ConfigError) { cmd.call([ "extra" ]) }

    assert_match(/unexpected arguments/, error.message)
  end

  def test_status_fetch_failure_raises_hive_error
    watcher = StubStatusWatcher.new(result: FetchResult.new(ok: false, rows: [], error: "status failed"))
    cmd = Hive::Commands::AnswerDigest.new(
      date: "2026-06-27",
      dry_run: true,
      cfg: cfg,
      status_watcher: watcher,
      env_loader: StubEnvLoader.new(calls: []),
      telegram_factory: ->(token:, logger:) { StubTelegram.new(messages: []) }
    )

    error = assert_raises(Hive::Error) { cmd.call }

    assert_match(/hive status unavailable: status failed/, error.message)
  end

  def test_default_config_loader_and_now_are_used
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), "registered_projects: []\n")
      output = StringIO.new
      cmd = Hive::Commands::AnswerDigest.new(
        dry_run: true,
        output: output,
        status_watcher: StubStatusWatcher.new(result: FetchResult.new(ok: true, rows: [])),
        env_loader: StubEnvLoader.new(calls: [])
      )

      result = cmd.call

      assert_equal false, result.sent
      assert_kind_of Date, result.date
    end
  end

  def test_daemon_enabled_resolver_degrades_on_project_config_error
    cmd, = command(rows: [])
    resolver = cmd.send(:daemon_enabled_resolver)
    broken = row(slug: "plan-260625-abcd", project_path: "/tmp/broken")

    with_replaced_singleton_method(Hive::Config, :load, ->(_path) { raise Hive::ConfigError, "bad config" }) do
      assert_equal false, resolver.call(broken)
    end
  end

  def test_malformed_project_config_does_not_suppress_plan_pause
    output = StringIO.new
    with_tmp_dir do |project_path|
      FileUtils.mkdir_p(File.join(project_path, ".hive-state"))
      File.write(File.join(project_path, ".hive-state", "config.yml"), "daemon: [")
      cmd, = command(
        rows: [ row(slug: "plan-260625-abcd", project_path: project_path, stage: "3-plan") ],
        output: output,
        dry_run: true
      )

      cmd.call
    end

    assert_includes output.string, "Plan…"
  end

  def test_default_factories_construct_collaborators
    cmd = Hive::Commands::AnswerDigest.new(dry_run: true, cfg: cfg, config_loader: -> { cfg })

    assert_kind_of Hive::Bot::StatusWatcher, cmd.send(:status_watcher)
    assert_kind_of Hive::Bot::Telegram, cmd.send(:build_telegram, token: "token", logger: nil)
  end

  def test_real_send_json_envelope_reports_sent_chat_and_task_list
    output = StringIO.new
    telegram = StubTelegram.new(messages: [])
    waiting = row(
      slug: "answer-me-260625-abcd",
      id: 9281,
      display_name: "Answer Me",
      pr_url: "https://github.com/example/repo/pull/17"
    )
    cmd, = command(rows: [ waiting ], output: output, json: true, telegram: telegram)

    with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
      result = cmd.call

      assert_equal true, result.sent
    end

    assert_equal 1, telegram.messages.length
    payload = JSON.parse(output.string)
    assert_equal "hive-answer-digest", payload.fetch("schema")
    assert_equal 1, payload.fetch("schema_version")
    assert_equal true, payload.fetch("ok")
    assert_equal true, payload.fetch("sent")
    assert_nil payload.fetch("reason")
    assert_equal 4242, payload.fetch("chat_id")
    assert_equal 1, payload.fetch("button_count")
    assert_equal 1, payload.fetch("count")
    assert_nil payload.fetch("message"), "message is null on a real send, not the rendered text"
    tasks = payload.fetch("tasks")
    assert_equal 1, tasks.length
    task = tasks.first
    assert_equal "hive", task.fetch("project")
    assert_equal "answer-me-260625-abcd", task.fetch("slug")
    assert_equal 9281, task.fetch("id")
    assert_equal "2-brainstorm", task.fetch("stage")
    assert_equal "#17", task.fetch("pr")
  end

  def test_daemon_enabled_resolver_caches_config_load_per_project_path
    cmd, = command(rows: [])
    resolver = cmd.send(:daemon_enabled_resolver)
    row_a = row(slug: "plan-a-260625-abcd", project_path: "/tmp/shared", stage: "3-plan")
    row_b = row(slug: "plan-b-260625-abcd", project_path: "/tmp/shared", stage: "3-plan")
    loads = 0

    with_replaced_singleton_method(Hive::Config, :load, lambda { |_path|
      loads += 1
      { "daemon" => { "enabled" => true } }
    }) do
      assert_equal true, resolver.call(row_a)
      assert_equal true, resolver.call(row_b)
    end

    assert_equal 1, loads,
                 "two rows sharing a project_path must dedupe to one Hive::Config.load"
  end

  def test_daemon_enabled_resolver_logs_project_config_error_when_logger_present
    logger = CapturingLogger.new(events: [])
    cmd = Hive::Commands::AnswerDigest.new(
      dry_run: true, cfg: cfg, config_loader: -> { cfg },
      status_watcher: StubStatusWatcher.new(result: FetchResult.new(ok: true, rows: [])),
      env_loader: StubEnvLoader.new(calls: []), logger: logger
    )
    resolver = cmd.send(:daemon_enabled_resolver)
    broken = row(slug: "plan-260625-abcd", project_path: "/tmp/broken", stage: "3-plan")

    with_replaced_singleton_method(Hive::Config, :load, ->(_path) { raise Hive::ConfigError, "bad config" }) do
      assert_equal false, resolver.call(broken)
    end

    event = logger.events.find { |e| e[:name] == :poll_failure }
    refute_nil event, "a broken project config must be logged from the digest path, not invisible"
    assert_equal "answer_digest_daemon_check", event[:payload][:source]
    assert_equal "hive", event[:payload][:project]
  end

  def test_resolver_falls_back_to_registered_project_path_when_row_lacks_one
    cmd, = command(rows: [])
    resolver = cmd.send(:daemon_enabled_resolver)
    blank = row(slug: "plan-260625-abcd", project_path: "", stage: "3-plan")
    loaded = []

    with_replaced_singleton_method(Hive::Config, :find_project, ->(_project) { { "path" => "/tmp/registered" } }) do
      with_replaced_singleton_method(Hive::Config, :load, lambda { |path|
        loaded << path
        { "daemon" => { "enabled" => true } }
      }) do
        assert_equal true, resolver.call(blank)
      end
    end

    assert_equal [ "/tmp/registered" ], loaded,
                 "a project_path-less row must resolve the path via Config.find_project"
  end

  def test_status_failure_json_envelope_uses_status_unavailable_error_kind
    output = StringIO.new
    watcher = StubStatusWatcher.new(result: FetchResult.new(ok: false, rows: [], error: "boom"))
    cmd = Hive::Commands::AnswerDigest.new(
      date: "2026-06-27", json: true, output: output, cfg: cfg,
      status_watcher: watcher, env_loader: StubEnvLoader.new(calls: []),
      telegram_factory: ->(token:, logger:) { StubTelegram.new(messages: []) }
    )

    assert_raises(Hive::Error) { cmd.call }

    payload = JSON.parse(output.string)
    assert_equal "hive-answer-digest", payload.fetch("schema")
    assert_equal false, payload.fetch("ok")
    assert_equal "status_unavailable", payload.fetch("error_kind")
    assert_equal "StatusUnavailableError", payload.fetch("error_class")
    assert_equal Hive::ExitCodes::GENERIC, payload.fetch("exit_code")
  end

  def test_non_hive_error_json_envelope_uses_internal_error_kind_and_reraises
    output = StringIO.new
    watcher = Object.new
    def watcher.fetch = raise("kaboom")
    cmd = Hive::Commands::AnswerDigest.new(
      date: "2026-06-27", json: true, output: output, cfg: cfg,
      status_watcher: watcher, env_loader: StubEnvLoader.new(calls: []),
      telegram_factory: ->(token:, logger:) { StubTelegram.new(messages: []) }
    )

    assert_raises(RuntimeError) { cmd.call }

    payload = JSON.parse(output.string)
    assert_equal false, payload.fetch("ok")
    assert_equal "internal", payload.fetch("error_kind")
  end

  def test_result_validates_reason_chat_id_and_derives_sent
    base = {
      date: Date.new(2026, 6, 27), message: "", button_count: 0,
      reason: "empty", dry_run: false, count: 0, tasks: []
    }
    klass = Hive::Commands::AnswerDigest::Result

    empty = klass.new(**base, chat_id: nil)
    assert_equal false, empty.sent
    sent = klass.new(date: Date.new(2026, 6, 27), message: "x", button_count: 1,
                     chat_id: 42, reason: nil, dry_run: false, count: 1, tasks: [])
    assert_equal true, sent.sent

    assert_raises(ArgumentError) { klass.new(**base, chat_id: nil, reason: "bogus") }
    assert_raises(ArgumentError) do
      klass.new(date: Date.new(2026, 6, 27), message: "x", button_count: 1,
                chat_id: nil, reason: nil, dry_run: false, count: 1, tasks: [])
    end
    assert_raises(ArgumentError) { klass.new(**base, chat_id: 42) }
  end

  def test_result_reconciles_dry_run_counts_and_task_types
    klass = Hive::Commands::AnswerDigest::Result
    task = Hive::Commands::AnswerDigest::Task.new(
      project: "hive", slug: "s", id: 1, title: "t", stage: "2-brainstorm", pr: nil
    )
    ok = {
      date: Date.new(2026, 6, 27), message: "x", button_count: 1,
      chat_id: nil, reason: "dry_run", dry_run: true, count: 1, tasks: [ task ]
    }
    assert_kind_of klass, klass.new(**ok)

    # reason "dry_run" must be a dry run
    assert_raises(ArgumentError) { klass.new(**ok.merge(dry_run: false)) }
    # a real send (reason nil) must not be a dry run
    assert_raises(ArgumentError) do
      klass.new(date: Date.new(2026, 6, 27), message: "x", button_count: 1,
                chat_id: 42, reason: nil, dry_run: true, count: 1, tasks: [ task ])
    end
    # counts must be non-negative
    assert_raises(ArgumentError) { klass.new(**ok.merge(button_count: -1, count: 0, tasks: [])) }
    # button_count must not exceed count
    assert_raises(ArgumentError) { klass.new(**ok.merge(button_count: 2, count: 1)) }
    # every task must be a Task value object
    assert_raises(ArgumentError) do
      klass.new(**ok.merge(button_count: 0, count: 0, tasks: [ { "project" => "x" } ]))
    end
  end

  def test_result_freezes_tasks_collection
    klass = Hive::Commands::AnswerDigest::Result
    result = klass.new(date: Date.new(2026, 6, 27), message: "", button_count: 0,
                       chat_id: nil, reason: "empty", dry_run: false, count: 0, tasks: [])

    assert_predicate result.tasks, :frozen?, "tasks must be frozen so the value object is not shallowly mutable"
  end
end
