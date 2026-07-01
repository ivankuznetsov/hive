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

  # Loads fine (so validation passes) but blows up on the allowlist write —
  # stands in for a read-only/full config dir or a malformed-on-disk config.
  StubConfigRaisingOnUpdate = Struct.new(:bot_config) do
    def load_global_bot(*) = bot_config
    def update_global_config!(*) = raise(Hive::ConfigError, "config dir is read-only")
  end

  # Fails the approval-notice write the way a full/read-only state dir would.
  module RaisingApprovalQueue
    def self.write!(chat_id:) = raise(Errno::ENOSPC)
  end

  # Returns a value outside the documented Integer | :expired | :unknown
  # contract, to exercise the loud-failure arm of resolve_code!.
  UnexpectedResolveStore = Class.new do
    def resolve(code:) = :surprise
  end

  # `pending` raises the way a read-only/full state dir would (prune-on-read +
  # lock-file open both write), exercising the clean-envelope guard on list.
  RaisingPendingStore = Class.new do
    def pending = raise(Errno::EROFS, "state dir is read-only")
  end

  # Approval succeeds through every fallible side effect, then the best-effort
  # consume cleanup blows up (full/read-only dir) — must not mask the approval.
  ConsumeRaisingStore = Class.new do
    def resolve(code:) = 999
    def consume(code:) = raise(Errno::ENOSPC)
  end

  # Probe (signal 0) reports the bot alive, but the process vanishes before the
  # SIGHUP lands — a genuine "bot not running" race, not a signal failure.
  VanishingProcess = Struct.new(:kills, keyword_init: true) do
    def kill(signal, pid)
      kills << [ signal, pid ]
      raise Errno::ESRCH if signal == "HUP"

      true
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

  def test_list_surfaces_store_read_failure_as_clean_envelope
    output = StringIO.new
    command = command("list", json: true, store: RaisingPendingStore.new, output: output)

    error = assert_raises(Hive::Commands::Pairing::ApprovalError) { command.call }

    assert_equal "store_read_failed", error.error_kind
    payload = JSON.parse(output.string)
    assert_equal false, payload.fetch("ok")
    assert_equal "store_read_failed", payload.fetch("error_kind")
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
      assert_empty pairing_store.pending,
                   "an already-allowlisted approval still consumes the code"
      assert_equal [ 999 ], Hive::Bot::PairingApprovalQueue.pending(state_home: home).map(&:chat_id),
                   "an already-allowlisted approval still queues the approval notice"
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

  def test_approve_rejects_trailing_arguments_without_side_effects
    with_tmp_global_config do |home|
      pairing_store = store(home)
      code = pairing_store.mint_or_get(chat_id: 999)
      original = File.read(File.join(home, "config.yml"))
      output = StringIO.new

      # The `extra.empty?` false arm: trailing garbage after the code must be
      # rejected as a usage error, not silently accepted.
      error = assert_raises(Hive::InvalidTaskPath) do
        command("approve", args: [ "telegram", code, "extra" ], json: true,
                           store: pairing_store, output: output).call
      end

      assert_match(/usage/, error.message)
      assert_equal original, File.read(File.join(home, "config.yml")),
                   "a usage error must not mutate the allowlist"
      assert_equal [ code ], pairing_store.pending.map(&:code),
                   "a usage error must not consume the code"
      assert_empty Hive::Bot::PairingApprovalQueue.pending(state_home: home),
                   "a usage error must not queue a notice"
      payload = JSON.parse(output.string)
      assert_equal "invalid_arguments", payload.fetch("error_kind")
      assert_equal "hive-pairing-approve", payload.fetch("schema")
    end
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
      payload = nil

      # The bot IS live (the probe passed) but the SIGHUP failed (EPERM): the
      # running bot keeps serving the stale allowlist, so the operator MUST be
      # warned on stderr to restart it — a covered-but-unasserted warn could be
      # dropped by a refactor with every test still green.
      _out, err = capture_io do
        payload = command("approve", args: [ "telegram", code ], json: true,
                                     store: pairing_store, output: StringIO.new,
                                     process: process).call
      end

      assert_equal false, payload.fetch("reloaded")
      assert_equal [ [ 0, 4242 ], [ "HUP", 4242 ] ], process.kills
      assert_match(/failed to signal live bot \(pid 4242\)/, err,
                   "a live bot whose SIGHUP failed must warn the operator on stderr")
      assert_match(/restart the bot/, err,
                   "the warn must tell the operator to restart so the new allowlist takes effect")
    end
  end

  def test_approve_treats_non_positive_pid_as_bot_down_without_signalling
    with_tmp_global_config do |home|
      pairing_store = store(home)
      code = pairing_store.mint_or_get(chat_id: 999)
      # A corrupt/hand-edited `pid: 0` coerces to a truthy 0; without a `pid > 0`
      # guard `Process.kill("HUP", 0)` would broadcast SIGHUP to the whole
      # process group. It must be treated as bot-down and never signalled.
      File.write(File.join(home, ".bot.pid"), { "pid" => 0 }.to_yaml)
      process = FakeProcess.new(alive: true, kills: [])

      payload = command("approve", args: [ "telegram", code ], json: true,
                                   store: pairing_store, output: StringIO.new,
                                   process: process).call

      assert_equal false, payload.fetch("reloaded"),
                   "a non-positive pid must be treated as bot-down"
      assert_empty process.kills,
                   "a pid of 0 must never be signalled — not even the alive probe"
    end
  end

  def test_approve_treats_hup_esrch_as_bot_not_running
    with_tmp_global_config do |home|
      pairing_store = store(home)
      code = pairing_store.mint_or_get(chat_id: 999)
      File.write(File.join(home, ".bot.pid"), { "pid" => 4242 }.to_yaml)
      process = VanishingProcess.new(kills: [])

      payload = command("approve", args: [ "telegram", code ], json: true,
                                   store: pairing_store, output: StringIO.new,
                                   process: process).call

      assert_equal false, payload.fetch("reloaded"),
                   "a process that vanishes before the SIGHUP lands is treated as not running"
      assert_equal [ [ 0, 4242 ], [ "HUP", 4242 ] ], process.kills
    end
  end

  def test_approve_treats_unreadable_pid_file_as_bot_down
    with_tmp_global_config do |home|
      pairing_store = store(home)
      code = pairing_store.mint_or_get(chat_id: 999)
      # A directory at the pid path passes File.exist? but makes File.read
      # raise EISDIR (a SystemCallError): degrade to "bot down", never crash.
      Dir.mkdir(File.join(home, ".bot.pid"))

      payload = command("approve", args: [ "telegram", code ], json: true,
                                   store: pairing_store, output: StringIO.new).call

      assert_equal false, payload.fetch("reloaded")
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

  def test_approve_json_echoes_the_normalized_code
    with_tmp_global_config do |home|
      pairing_store = store(home)
      code = pairing_store.mint_or_get(chat_id: 999)
      output = StringIO.new

      payload = command("approve", args: [ "telegram", "  #{code.downcase}  " ], json: true,
                                   store: pairing_store, output: output).call

      assert_equal code, payload.fetch("code"), "the echoed code must be the normalized, stored form"
      assert_match(/\A[A-Z]{8}\z/, payload.fetch("code"))
      assert_empty pairing_store.pending
      assert_schema_valid("hive-pairing-approve", payload)
    end
  end

  def test_approve_allowlist_write_failure_leaves_code_pending
    with_tmp_global_config do |home|
      pairing_store = store(home)
      code = pairing_store.mint_or_get(chat_id: 999)
      output = StringIO.new
      config = StubConfigRaisingOnUpdate.new({ "chat_id_allowlist" => [] })

      assert_raises(Hive::ConfigError) do
        command("approve", args: [ "telegram", code ], json: true,
                           store: pairing_store, output: output, config: config).call
      end

      assert_equal [ code ], pairing_store.pending.map(&:code),
                   "a failed allowlist write must leave the code pending for retry"
      assert_empty Hive::Bot::PairingApprovalQueue.pending(state_home: home)
      payload = JSON.parse(output.string)
      assert_equal "config", payload.fetch("error_kind")
    end
  end

  def test_approve_notice_write_failure_leaves_code_pending_with_clean_envelope
    with_tmp_global_config do |home|
      pairing_store = store(home)
      code = pairing_store.mint_or_get(chat_id: 999)
      output = StringIO.new

      error = assert_raises(Hive::Commands::Pairing::ApprovalError) do
        command("approve", args: [ "telegram", code ], json: true, store: pairing_store,
                           output: output, approval_queue: RaisingApprovalQueue).call
      end

      assert_equal "notice_write_failed", error.error_kind
      config = YAML.safe_load(File.read(File.join(home, "config.yml")))
      assert_equal [ 999 ], config.dig("bot", "chat_id_allowlist"),
                   "the allowlist write lands before the notice write fails (partial success)"
      assert_equal [ code ], pairing_store.pending.map(&:code),
                   "a failed notice write must leave the code pending for retry"
      payload = JSON.parse(output.string)
      assert_equal false, payload.fetch("ok")
      assert_equal "notice_write_failed", payload.fetch("error_kind")
      assert_schema_valid("hive-pairing-approve", payload)
    end
  end

  def test_approve_succeeds_even_when_consume_cleanup_fails
    with_tmp_global_config do |home|
      output = StringIO.new

      # resolve → allowlist → notice all land; only the trailing best-effort
      # consume raises. The approval is complete, so a success envelope must
      # still emit (the stale code expires on its own).
      payload = command("approve", args: [ "telegram", "ABCDEFGH" ], json: true,
                                   store: ConsumeRaisingStore.new, output: output).call

      assert_equal true, payload.fetch("ok")
      config = YAML.safe_load(File.read(File.join(home, "config.yml")))
      assert_equal [ 999 ], config.dig("bot", "chat_id_allowlist")
      assert_equal [ 999 ], Hive::Bot::PairingApprovalQueue.pending(state_home: home).map(&:chat_id)
      assert_equal payload, JSON.parse(output.string)
    end
  end

  def test_approve_raises_loudly_on_unexpected_resolve_value
    with_tmp_global_config do |home|
      output = StringIO.new

      error = assert_raises(Hive::Commands::Pairing::ApprovalError) do
        command("approve", args: [ "telegram", "ABCDEFGH" ], json: true,
                           store: UnexpectedResolveStore.new, output: output).call
      end

      assert_equal "internal_error", error.error_kind
      assert_match(/unexpected value/, error.message)
    end
  end

  private

  def command(subcommand, args: [], json: false, output: StringIO.new, store: nil,
              process: FakeProcess.new(alive: false, kills: []), now: -> { Time.now },
              config: nil, approval_queue: nil)
    kwargs = {
      args: args,
      json: json,
      output: output,
      store: store || self.store(Dir.mktmpdir("hive-pairing-command")),
      process: process,
      now: now
    }
    kwargs[:config] = config if config
    kwargs[:approval_queue] = approval_queue if approval_queue
    Hive::Commands::Pairing.new(subcommand, **kwargs)
  end

  def store(state_home, now: -> { Time.now })
    Hive::Bot::PairingStore.new(state_home: state_home, now: now)
  end

  def assert_schema_valid(name, payload)
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(name))))
    assert schema.valid?(payload), "#{name} payload must match schema: #{payload.inspect}"
  end
end
