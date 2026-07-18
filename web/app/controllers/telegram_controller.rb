require "hive/env_file"

class TelegramController < ApplicationController
  def show
    load_telegram_page
  end

  def update
    entered_token = params[:token].to_s.strip
    token = entered_token.presence || saved_telegram_token.to_s.strip
    raise Hive::Error, "token required" if token.empty?
    pairing_enabled = params[:pairing_enabled] == "1"

    # Strict parse BEFORE enabling: `to_i` would turn "@mychannel" into 0
    # (authorizing nobody the operator meant) and blank input into an empty
    # allowlist that only fails much later, at bot runtime.
    raw_chats = params[:chat_ids].to_s.split(/[,\s]+/).reject(&:empty?)
    chats = raw_chats.map { |c| Integer(c, exception: false) }
    if (raw_chats.empty? && !pairing_enabled) || chats.any?(&:nil?)
      bad = raw_chats.zip(chats).select { |_, n| n.nil? }.map(&:first)
      message = if raw_chats.empty?
        "At least one numeric chat ID is required unless pairing is enabled. Nothing was saved."
      else
        "Chat IDs must be numeric (got: #{bad.join(', ')}). Use the ID from @userinfobot, not a @handle. Nothing was saved."
      end
      return render_settings_error(message)
    end

    # Validate against the real Telegram API (getMe) BEFORE saving. An
    # invalid NEW token persists nothing. A blank token field keeps the
    # previously validated secret, so changing pairing/allowlist settings does
    # not force the operator to retrieve and re-enter it.
    if entered_token.present? && !Hive::Web::TelegramValidator.call(token)
      return render_settings_error("Telegram rejected this token (getMe failed). Nothing was saved.")
    end

    write_env_value("HIVE_TELEGRAM_BOT_TOKEN", token) if entered_token.present?
    Hive::Config.update_global_config! do |data|
      data["bot"] ||= {}
      data["bot"]["enabled"] = true
      data["bot"]["pairing_enabled"] = pairing_enabled
      data["bot"]["chat_id_allowlist"] = chats
    end
    if request_bot_restart
      redirect_to telegram_path, notice: "Telegram bot configured and (re)starting"
    else
      # Outside the supervised container (or with a dead supervisor) the HUP
      # has nowhere to go — saying "(re)starting" would be a lie while the
      # old process keeps long-polling with the previous token.
      redirect_to telegram_path,
                  notice: "Telegram settings saved. No supervisor reachable — restart the bot manually (hive bot stop && hive bot start)."
    end
  end

  # Round-trip confirmation: getMe + a real sendMessage to every configured
  # chat, reported inline.
  def test
    load_telegram_page
    token = saved_telegram_token
    if token.to_s.strip.empty?
      flash.now[:alert] = "Save a bot token before sending a test message."
      return render :show, status: :unprocessable_entity
    end

    result = Hive::Web::TelegramTester.call(token: token, chat_ids: @bot["chat_id_allowlist"])
    if result[:ok]
      flash.now[:notice] = "Sent a test message to #{result[:sent]} chat(s)."
      render :show
    else
      flash.now[:alert] = "Telegram test failed: #{result[:error]}."
      render :show, status: :unprocessable_entity
    end
  end

  def approve_pairing
    unless params[:consent] == "approve_telegram_pairing"
      raise Hive::Error, "confirm the Telegram pairing approval from the Telegram page"
    end

    result = pairing_gateway.approve(params[:code])
    notice = "Approved Telegram chat #{result.fetch('chat_id')}."
    notice += if result["reloaded"]
      " The running bot was reloaded."
    else
      " Restart the bot to load the updated allowlist."
    end
    redirect_to telegram_path, notice: notice
  end

  private

  def load_telegram_page
    @bot = Hive::Config.load_global_bot
    @token_saved = saved_telegram_token.to_s.strip.present?
    @pairings = []
    return unless @bot["pairing_enabled"]

    begin
      @pairings = pairing_gateway.pending
    rescue Hive::Error => e
      @pairing_error = e.message
    end
  end

  def render_settings_error(message)
    load_telegram_page
    flash.now[:alert] = message
    render :show, status: :unprocessable_entity
  end

  def pairing_gateway
    self.class.pairing_gateway
  end

  class << self
    def pairing_gateway
      @pairing_gateway ||= Hive::Web::TelegramPairing.new
    end
  end

  # The container supervisor sets HIVEBOX_SUPERVISOR_PID on its children and
  # reloads its child set on SIGHUP, bringing the bot up without recreating
  # the container. Returns whether the signal was actually delivered so the
  # caller can tell the operator the truth about a restart.
  def request_bot_restart
    pid = ENV["HIVEBOX_SUPERVISOR_PID"].to_i
    return false if pid <= 0

    Process.kill("HUP", pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def saved_telegram_token
    live = ENV["HIVE_TELEGRAM_BOT_TOKEN"].to_s
    return live unless live.strip.empty?

    read_env_value("HIVE_TELEGRAM_BOT_TOKEN")
  end

  def read_env_value(key)
    path = Hive::EnvFile::DEFAULT_PATH
    return nil unless File.exist?(path)

    File.readlines(path, chomp: true).reverse_each do |line|
      k, v = line.split("=", 2)
      return Hive::EnvFile.strip_outer_quotes(v) if v && k.to_s.strip == key
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
