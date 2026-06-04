require "hive/env_file"
require "fileutils"

module Hive
  module Web
    class App < Sinatra::Base
      get "/telegram" do
        @bot = Hive::Config.load_global_bot
        erb :telegram
      end

      post "/telegram" do
        token = params["token"].to_s.strip
        halt 422, "token required" if token.empty?
        chats = params["chat_ids"].to_s.split(/[,\s]+/).reject(&:empty?).map(&:to_i)
        write_env_value("HIVE_TELEGRAM_BOT_TOKEN", token)
        Hive::Config.update_global_config! do |data|
          data["bot"] ||= {}
          data["bot"]["enabled"] = true
          data["bot"]["chat_id_allowlist"] = chats
        end
        redirect "/telegram"
      end

      post "/telegram/test" do
        halt 501, "Telegram round-trip test requires a live bot token and chat"
      end

      helpers do
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
