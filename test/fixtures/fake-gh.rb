#!/usr/bin/env ruby
# frozen_string_literal: false

# Deterministic stand-in for `gh pr view <url> --json state` calls
# made by Hive::Daemon::PrMergeWatcher. The state is read from
# environment variables so tests can sequence different responses on
# the same fixture script.
#
# ENV controls:
#   HIVE_FAKE_GH_STATE   The PR state to emit (OPEN | MERGED | CLOSED)
#   HIVE_FAKE_GH_EXIT    Exit code (default 0)
#   HIVE_FAKE_GH_STDERR  Optional stderr text

state = ENV["HIVE_FAKE_GH_STATE"] || "OPEN"
exit_code = (ENV["HIVE_FAKE_GH_EXIT"] || "0").to_i
stderr_text = ENV["HIVE_FAKE_GH_STDERR"]

$stderr.write(stderr_text) if stderr_text

# Real gh emits the JSON only on success; on failure stderr carries
# the message and stdout is empty.
if exit_code.zero?
  require "json"
  $stdout.write(JSON.generate("state" => state))
end

exit exit_code
