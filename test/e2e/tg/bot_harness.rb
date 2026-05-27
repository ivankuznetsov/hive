#!/usr/bin/env ruby
# Runs the hive bot supervisor FROM THIS CHECKOUT (so local fixes are
# exercised) against the @BotFather TEST token, with all persistent state
# redirected to /tmp and the allowlist overridden to the headless driver
# account — so the production bot's token, offset, and alert state are
# never touched.
#
# Env:
#   HIVE_TEST_BOT_TOKEN   - the test bot token (required)
#   HIVE_TEST_ALLOWLIST   - comma-separated chat ids (required)
$LOAD_PATH.unshift(File.expand_path("../../../lib", __dir__))
require "hive"
require "hive/config"
require "hive/bot/supervisor"

token = ENV.fetch("HIVE_TEST_BOT_TOKEN")
allowlist = ENV.fetch("HIVE_TEST_ALLOWLIST").split(",").map { |s| Integer(s.strip) }

cfg = Hive::Config.load_global_bot.merge(
  "chat_id_allowlist"    => allowlist,
  "log_file"             => "/tmp/hive-e2e-bot.log",
  "last_seen_state_file" => "/tmp/hive-e2e-bot.last_seen",
  "alert_state_file"     => "/tmp/hive-e2e-bot.alerts",
  "pid_file"             => "/tmp/hive-e2e-bot.pid"
)

warn "[e2e-bot] fixed supervisor up; allowlist=#{allowlist.inspect} log=#{cfg['log_file']}"
Hive::Bot::Supervisor.new(config: cfg, token: token, dry_run: false).run_forever
