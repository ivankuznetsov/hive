require "test_helper"
require "hive/commands/answer_digest"
require "hive/bot/status_watcher"

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
end
