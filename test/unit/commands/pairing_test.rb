require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/pairing"

class HiveCommandsPairingTest < Minitest::Test
  include HiveTestHelper

  FakeProcess = Struct.new(:alive, :kills, keyword_init: true) do
    def kill(signal, pid)
      raise Errno::ESRCH if signal == 0 && !alive
      raise Errno::ESRCH if signal == "HUP" && !alive

      kills << [ signal, pid ]
      true
    end
  end

  HupFailureProcess = Struct.new(:kills, keyword_init: true) do
    def kill(signal, pid)
      kills << [ signal, pid ]
      raise Errno::EPERM if signal == "HUP"

      true
    end
  end

  MissingProcess = Struct.new(:kills, keyword_init: true) do
    def kill(signal, pid)
      kills << [ signal, pid ]
      raise Errno::ESRCH if signal == 0

      true
    end
  end

  ProbePermissionProcess = Struct.new(:kills, keyword_init: true) do
    def kill(signal, pid)
      if signal == 0
        kills << [ signal, pid ]
        raise Errno::EPERM
      end

      kills << [ signal, pid ]
      true
    end
  end

  FakePendingStore = Struct.new(:entries) do
    def pending
      entries
    end
  end

  def test_list_prints_empty_message
    Dir.mktmpdir("hive-pairing-command") do |state_home|
      output = StringIO.new
      command = command("list", store: store(state_home), output: output)

      command.call

      assert_equal "No pending pairing requests.\n", output.string
    end
  end

  def test_list_json_emits_empty_pending_envelope
    Dir.mktmpdir("hive-pairing-command") do |state_home|
      output = StringIO.new
      command = command("list", json: true, store: store(state_home), output: output)

      command.call

      payload = JSON.parse(output.string)
      assert_equal true, payload.fetch("ok")
      assert_equal "hive-pairing-list", payload.fetch("schema")
      assert_equal [], payload.fetch("pending")
      assert_schema_valid("hive-pairing-list", payload)
    end
  end

  def test_list_json_includes_pending_payload
    Dir.mktmpdir("hive-pairing-command") do |state_home|
      current = Time.utc(2026, 6, 30, 12, 0, 0)
      pairing_store = store(state_home, now: -> { current })
      code = pairing_store.mint_or_get(chat_id: 111)
      output = StringIO.new

      command("list", json: true, store: pairing_store, output: output, now: -> { current + 90 }).call

      payload = JSON.parse(output.string)
      assert_equal code, payload.fetch("pending").first.fetch("code")
      assert_equal 111, payload.fetch("pending").first.fetch("chat_id")
      assert_equal 90, payload.fetch("pending").first.fetch("age_sec")
      assert_schema_valid("hive-pairing-list", payload)
    end
  end

  def test_list_prints_pending_rows_sorted
    Dir.mktmpdir("hive-pairing-command") do |state_home|
      current = Time.utc(2026, 6, 30, 12, 0, 0)
      pairing_store = store(state_home, now: -> { current })
      first = pairing_store.mint_or_get(chat_id: 111)
      current += 60
      second = pairing_store.mint_or_get(chat_id: 222)
      output = StringIO.new

      command("list", store: pairing_store, output: output, now: -> { current }).call

      assert_match(/\ACODE\s+CHAT_ID\s+CREATED_AT\s+AGE\s+EXPIRES/, output.string)
      assert output.string.index(first) < output.string.index(second)
      assert_includes output.string, "111"
      assert_includes output.string, "222"
    end
  end

  def test_list_prints_day_age_with_default_now
    old_entry = Hive::Bot::PairingStore::Entry.new(
      code: "ABCDEFGH",
      chat_id: 111,
      created_at: Time.now - (3 * 86_400)
    )
    output = StringIO.new

    Hive::Commands::Pairing.new("list", store: FakePendingStore.new([ old_entry ]), output: output).call

    assert_includes output.string, "3d"
  end

  def test_list_rejects_extra_arguments_with_json_error
    output = StringIO.new
    command = command("list", args: [ "extra" ], json: true, output: output)

    error = assert_raises(Hive::InvalidTaskPath) { command.call }

    assert_match(/unexpected arguments/, error.message)
    payload = JSON.parse(output.string)
    assert_equal false, payload.fetch("ok")
    assert_equal "invalid_arguments", payload.fetch("error_kind")
    assert_equal "hive-pairing-list", payload.fetch("schema")
  end

  def test_unknown_subcommand_is_rejected
    error = assert_raises(Hive::InvalidTaskPath) do
      command("deny", output: StringIO.new).call
    end

    assert_match(/unknown subcommand/, error.message)
  end

  def test_approve_appends_allowlist_consumes_code_queues_notice_and_signals_reload
    with_tmp_global_config do |home|
      pairing_store = store(home)
      code = pairing_store.mint_or_get(chat_id: 999)
      File.write(File.join(home, ".bot.pid"), { "pid" => 4242, "started_at" => Time.now.utc.iso8601 }.to_yaml)
      process = FakeProcess.new(alive: true, kills: [])
      output = StringIO.new

      payload = command("approve", args: [ "telegram", code ], json: true,
                                   store: pairing_store, output: output, process: process).call

      config = YAML.safe_load(File.read(File.join(home, "config.yml")))
      assert_equal [ 999 ], config.dig("bot", "chat_id_allowlist")
      assert_empty pairing_store.pending
      assert_equal [ [ 0, 4242 ], [ "HUP", 4242 ] ], process.kills
      assert_equal true, payload.fetch("reloaded")
      assert_equal false, payload.fetch("already_allowlisted")
      assert_equal true, payload.fetch("notice_queued")
      assert_equal payload, JSON.parse(output.string)
      assert_schema_valid("hive-pairing-approve", payload)
      notices = Hive::Bot::PairingApprovalQueue.pending(state_home: home)
      assert_equal [ 999 ], notices.map(&:chat_id)
    end
  end

  def test_approve_text_output_mentions_reload_and_notice
    with_tmp_global_config do |home|
      pairing_store = store(home)
      code = pairing_store.mint_or_get(chat_id: 999)
      File.write(File.join(home, ".bot.pid"), { "pid" => 4242 }.to_yaml)
      output = StringIO.new

      payload = command("approve", args: [ "telegram", code ],
                                   store: pairing_store, output: output,
                                   process: FakeProcess.new(alive: true, kills: [])).call

      assert_equal true, payload.fetch("reloaded")
      assert_includes output.string, "Approved Telegram chat_id 999."
      assert_includes output.string, "Bot reload requested."
      assert_includes output.string, "Approval notice queued."
    end
  end

  def test_approve_is_idempotent_for_already_allowlisted_chat
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "bot" => { "chat_id_allowlist" => [ 999 ] }
      }.to_yaml)
      pairing_store = store(home)
      code = pairing_store.mint_or_get(chat_id: 999)

      payload = command("approve", args: [ "telegram", code ], json: true,
                                   store: pairing_store, output: StringIO.new).call

      config = YAML.safe_load(File.read(File.join(home, "config.yml")))
      assert_equal [ 999 ], config.dig("bot", "chat_id_allowlist")
      assert_equal true, payload.fetch("already_allowlisted")
    end
  end

  def test_approve_rejects_missing_arguments_with_json_error
    output = StringIO.new
    command = command("approve", args: [ "telegram" ], json: true, output: output)

    error = assert_raises(Hive::InvalidTaskPath) { command.call }

    assert_match(/usage/, error.message)
    payload = JSON.parse(output.string)
    assert_equal "invalid_arguments", payload.fetch("error_kind")
    assert_equal "hive-pairing-approve", payload.fetch("schema")
  end

  def test_approve_config_error_is_emitted_before_code_is_consumed
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "bot" => { "chat_id_allowlist" => [ "not-an-integer" ] }
      }.to_yaml)
      pairing_store = store(home)
      code = pairing_store.mint_or_get(chat_id: 999)
      output = StringIO.new

      error = assert_raises(Hive::ConfigError) do
        command("approve", args: [ "telegram", code ], json: true,
                           store: pairing_store, output: output).call
      end

      assert_match(/chat_id_allowlist/, error.message)
      assert_equal [ code ], pairing_store.pending.map(&:code)
      payload = JSON.parse(output.string)
      assert_equal "config", payload.fetch("error_kind")
      assert_equal "ConfigError", payload.fetch("error_class")
    end
  end

  def test_approve_unknown_code_does_not_mutate_config_or_queue_notice
    with_tmp_global_config do |home|
      original = File.read(File.join(home, "config.yml"))
      output = StringIO.new
      command = command("approve", args: [ "telegram", "ABCDEFGH" ], json: true,
                                   store: store(home), output: output)

      error = assert_raises(Hive::Commands::Pairing::ApprovalError) { command.call }

      assert_match(/not found/, error.message)
      assert_equal original, File.read(File.join(home, "config.yml"))
      assert_empty Hive::Bot::PairingApprovalQueue.pending(state_home: home)
      payload = JSON.parse(output.string)
      assert_equal false, payload.fetch("ok")
      assert_equal "unknown_code", payload.fetch("error_kind")
      assert_schema_valid("hive-pairing-approve", payload)
    end
  end

  def test_approve_expired_code_does_not_mutate_config_or_queue_notice
    with_tmp_global_config do |home|
      current = Time.utc(2026, 6, 30, 12, 0, 0)
      pairing_store = store(home, now: -> { current })
      code = pairing_store.mint_or_get(chat_id: 999)
      current += Hive::Bot::PairingStore::EXPIRY_SEC + 1
      original = File.read(File.join(home, "config.yml"))
      output = StringIO.new

      error = assert_raises(Hive::Commands::Pairing::ApprovalError) do
        command("approve", args: [ "telegram", code ], json: true,
                           store: pairing_store, output: output).call
      end

      assert_match(/expired/, error.message)
      assert_equal original, File.read(File.join(home, "config.yml"))
      assert_empty Hive::Bot::PairingApprovalQueue.pending(state_home: home)
      payload = JSON.parse(output.string)
      assert_equal "expired_code", payload.fetch("error_kind")
    end
  end

  def test_approve_rejects_non_telegram_platform
    with_tmp_global_config do |home|
      command = command("approve", args: [ "foo", "ABCDEFGH" ], store: store(home), output: StringIO.new)

      error = assert_raises(Hive::InvalidTaskPath) { command.call }

      assert_match(/platform must be `telegram`/, error.message)
    end
  end

  def test_approve_without_running_bot_still_persists_and_queues_notice
    with_tmp_global_config do |home|
      pairing_store = store(home)
      code = pairing_store.mint_or_get(chat_id: 999)
      output = StringIO.new

      payload = command("approve", args: [ "telegram", code ], json: true,
                                   store: pairing_store, output: output).call

      config = YAML.safe_load(File.read(File.join(home, "config.yml")))
      assert_equal [ 999 ], config.dig("bot", "chat_id_allowlist")
      assert_equal false, payload.fetch("reloaded")
      assert_equal [ 999 ], Hive::Bot::PairingApprovalQueue.pending(state_home: home).map(&:chat_id)
    end
  end

  def test_approve_skips_reload_when_pid_probe_reports_missing_process
    with_tmp_global_config do |home|
      pairing_store = store(home)
      code = pairing_store.mint_or_get(chat_id: 999)
      File.write(File.join(home, ".bot.pid"), { "pid" => 4242 }.to_yaml)
      process = MissingProcess.new(kills: [])

      payload = command("approve", args: [ "telegram", code ], json: true,
                                   store: pairing_store, output: StringIO.new,
                                   process: process).call

      assert_equal false, payload.fetch("reloaded")
      assert_equal [ [ 0, 4242 ] ], process.kills
    end
  end

  def test_approve_skips_reload_when_hup_fails
    with_tmp_global_config do |home|
      pairing_store = store(home)
      code = pairing_store.mint_or_get(chat_id: 999)
      File.write(File.join(home, ".bot.pid"), { "pid" => 4242 }.to_yaml)
      process = HupFailureProcess.new(kills: [])

      payload = command("approve", args: [ "telegram", code ], json: true,
                                   store: pairing_store, output: StringIO.new,
                                   process: process).call

      assert_equal false, payload.fetch("reloaded")
      assert_equal [ [ 0, 4242 ], [ "HUP", 4242 ] ], process.kills
    end
  end

  def test_approve_treats_probe_permission_as_alive
    with_tmp_global_config do |home|
      pairing_store = store(home)
      code = pairing_store.mint_or_get(chat_id: 999)
      File.write(File.join(home, ".bot.pid"), { "pid" => 4242 }.to_yaml)
      process = ProbePermissionProcess.new(kills: [])

      payload = command("approve", args: [ "telegram", code ], json: true,
                                   store: pairing_store, output: StringIO.new,
                                   process: process).call

      assert_equal true, payload.fetch("reloaded")
      assert_equal [ [ 0, 4242 ], [ "HUP", 4242 ] ], process.kills
    end
  end

  def test_approve_ignores_malformed_pid_file
    with_tmp_global_config do |home|
      pairing_store = store(home)
      code = pairing_store.mint_or_get(chat_id: 999)
      File.write(File.join(home, ".bot.pid"), "pid: [")

      payload = command("approve", args: [ "telegram", code ], json: true,
                                   store: pairing_store, output: StringIO.new).call

      assert_equal false, payload.fetch("reloaded")
    end
  end

  private

  def command(subcommand, args: [], json: false, output: StringIO.new, store: nil,
              process: FakeProcess.new(alive: false, kills: []), now: -> { Time.now })
    Hive::Commands::Pairing.new(
      subcommand,
      args: args,
      json: json,
      output: output,
      store: store || self.store(Dir.mktmpdir("hive-pairing-command")),
      process: process,
      now: now
    )
  end

  def store(state_home, now: -> { Time.now })
    Hive::Bot::PairingStore.new(state_home: state_home, now: now)
  end

  def assert_schema_valid(name, payload)
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(name))))
    assert schema.valid?(payload), "#{name} payload must match schema: #{payload.inspect}"
  end
end
