require "hive/env_file"

class TelegramBot
  class InvalidSettings < Hive::Error; end

  Update = Data.define(:restarted?)
  PairingRequest = Data.define(:code, :chat_id, :age_sec, :expires_in_sec)

  attr_reader :attributes

  class << self
    attr_writer :pairing_gateway

    def current
      new(Hive::Config.load_global_bot)
    end

    def pairing_gateway
      @pairing_gateway ||= Hive::Web::TelegramPairing.new
    end

    def reset_pairing_gateway!
      remove_instance_variable(:@pairing_gateway) if instance_variable_defined?(:@pairing_gateway)
    end
  end

  def initialize(attributes)
    @attributes = attributes
  end

  def enabled?
    attributes["enabled"] == true
  end

  def pairing_enabled?
    attributes["pairing_enabled"] == true
  end

  def chat_ids
    Array(attributes["chat_id_allowlist"])
  end

  def token_saved?
    saved_token.present?
  end

  def pending_pairings
    return [] unless pairing_enabled?

    self.class.pairing_gateway.pending.map do |pairing|
      PairingRequest.new(
        code: pairing.fetch("code"),
        chat_id: pairing.fetch("chat_id"),
        age_sec: pairing.fetch("age_sec"),
        expires_in_sec: pairing.fetch("expires_in_sec")
      )
    end
  end

  def update!(entered_token:, chat_ids:, pairing_enabled:)
    entered_token = entered_token.to_s.strip
    token = entered_token.presence || saved_token.to_s.strip
    raise InvalidSettings, "token required" if token.empty?

    chats = parse_chat_ids(chat_ids, pairing_enabled:)
    if entered_token.present? && !Hive::Web::TelegramValidator.call(token)
      raise InvalidSettings, "Telegram rejected this token (getMe failed). Nothing was saved."
    end

    write_env_value("HIVE_TELEGRAM_BOT_TOKEN", token) if entered_token.present?
    Hive::Config.update_global_config! do |data|
      data["bot"] ||= {}
      data["bot"]["enabled"] = true
      data["bot"]["pairing_enabled"] = pairing_enabled
      data["bot"]["chat_id_allowlist"] = chats
    end

    Update.new(restarted?: request_restart)
  end

  def send_test_message
    raise InvalidSettings, "Save a bot token before sending a test message." unless token_saved?

    Hive::Web::TelegramTester.call(token: saved_token, chat_ids:)
  end

  def approve_pairing!(code:, consent:)
    unless consent == "approve_telegram_pairing"
      raise Hive::Error, "confirm the Telegram pairing approval from the Telegram page"
    end

    self.class.pairing_gateway.approve(code)
  end

  private

  def parse_chat_ids(value, pairing_enabled:)
    raw_chats = value.to_s.split(/[,\s]+/).reject(&:empty?)
    chats = raw_chats.map { |chat| Integer(chat, exception: false) }
    return chats unless (raw_chats.empty? && !pairing_enabled) || chats.any?(&:nil?)

    bad = raw_chats.zip(chats).select { |_, chat| chat.nil? }.map(&:first)
    message = if raw_chats.empty?
      "At least one numeric chat ID is required unless pairing is enabled. Nothing was saved."
    else
      "Chat IDs must be numeric (got: #{bad.join(', ')}). " \
        "Use the ID from @userinfobot, not a @handle. Nothing was saved."
    end
    raise InvalidSettings, message
  end

  def request_restart
    pid = ENV["HIVEBOX_SUPERVISOR_PID"].to_i
    return false if pid <= 0

    Process.kill("HUP", pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def saved_token
    live = ENV["HIVE_TELEGRAM_BOT_TOKEN"].to_s
    return live unless live.strip.empty?

    read_env_value("HIVE_TELEGRAM_BOT_TOKEN")
  end

  def read_env_value(key)
    path = Hive::EnvFile::DEFAULT_PATH
    return unless File.exist?(path)

    File.readlines(path, chomp: true).reverse_each do |line|
      candidate, value = line.split("=", 2)
      return Hive::EnvFile.strip_outer_quotes(value) if value && candidate.to_s.strip == key
    end
    nil
  end

  def write_env_value(key, value)
    path = Hive::EnvFile::DEFAULT_PATH
    FileUtils.mkdir_p(File.dirname(path))
    lines = File.exist?(path) ? File.readlines(path, chomp: true) : []
    replaced = false
    lines.map! do |line|
      if line.split("=", 2).first.to_s.strip == key
        replaced = true
        "#{key}=#{value}"
      else
        line
      end
    end
    lines << "#{key}=#{value}" unless replaced
    File.write(path, "#{lines.join("\n")}\n", mode: "w", perm: 0o600)
  end
end
