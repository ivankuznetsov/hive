#!/usr/bin/env ruby
# Build only: no HTTP server, controller actions, project registration or agents.
require "tmpdir"
require "fileutils"

Dir.mktmpdir("hive-static-demo-") do |home|
  ENV["RAILS_ENV"] = "test"
  ENV["HIVE_HOME"] = home
  ENV["HIVE_SKIP_LLM_WIKI_SCHEDULER"] = "1"
  ENV["HIVE_SKIP_LLM_WIKI_SYSTEMCTL"] = "1"
  require_relative "../config/environment"
  require_relative "support/demo/exporter"
  destination = ARGV.first || File.expand_path("../../demo/dist", __dir__)
  HiveDemo::Exporter.new.export(destination)
  puts "Exported the saved Hive snapshot views to #{destination}"
end
