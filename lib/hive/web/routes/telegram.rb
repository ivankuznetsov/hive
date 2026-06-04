require "hive/env_file"
require "fileutils"

module Hive
  module Web
    class App < Sinatra::Base
      get "/telegram" do
        @bot = Hive::Config.load_global_bot
        @error = nil
        erb :telegram
      end

      post "/telegram" do
        token = params["token"].to_s.strip
        halt 422, "token required" if token.empty?

        # U6: validate against the real Telegram API (getMe) BEFORE saving.
        # An invalid token persists nothing and re-renders the form with a
        # clear inline error (no JS alert).
        unless settings.telegram_validator.call(token)
          @bot = Hive::Config.load_global_bot
          @error = "Telegram rejected this token (getMe failed). Nothing was saved."
          halt 422, erb(:telegram)
        end

        chats = params["chat_ids"].to_s.split(/[,\s]+/).reject(&:empty?).map(&:to_i)
        write_env_value("HIVE_TELEGRAM_BOT_TOKEN", token)
        Hive::Config.update_global_config! do |data|
          data["bot"] ||= {}
          data["bot"]["enabled"] = true
          data["bot"]["chat_id_allowlist"] = chats
        end
        # Ask the container supervisor to (re)start the bot so a Telegram
        # message can run a stage without recreating the container (U6/U8).
        request_bot_restart
        redirect "/telegram"
      end

      post "/telegram/test" do
        halt 501, "Telegram round-trip test requires a live bot token and chat"
      end

      helpers do
        # The container supervisor (U8) sets HIVEBOX_SUPERVISOR_PID on the
        # children it spawns and reloads its child set on SIGHUP. Signalling
        # it here lets "enable Telegram" bring the bot up immediately. No-op
        # outside the supervised container (the env var is unset), and a
        # stale pid is ignored rather than crashing the save.
        def request_bot_restart
          pid = ENV["HIVEBOX_SUPERVISOR_PID"].to_i
          return if pid <= 0

          Process.kill("HUP", pid)
        rescue Errno::ESRCH, Errno::EPERM
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
    end
  end
end
