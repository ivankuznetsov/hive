require "hive/env_file"

class TelegramController < ApplicationController
  def show
    @bot = Hive::Config.load_global_bot
  end

  def update
    token = params[:token].to_s.strip
    raise Hive::Error, "token required" if token.empty?

    # Validate against the real Telegram API (getMe) BEFORE saving. An
    # invalid token persists nothing and re-renders with an inline error.
    unless Hive::Web::TelegramValidator.call(token)
      @bot = Hive::Config.load_global_bot
      flash.now[:alert] = "Telegram rejected this token (getMe failed). Nothing was saved."
      return render :show, status: :unprocessable_entity
    end

    chats = params[:chat_ids].to_s.split(/[,\s]+/).reject(&:empty?).map(&:to_i)
    write_env_value("HIVE_TELEGRAM_BOT_TOKEN", token)
    Hive::Config.update_global_config! do |data|
      data["bot"] ||= {}
      data["bot"]["enabled"] = true
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
    @bot = Hive::Config.load_global_bot
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

  private

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
