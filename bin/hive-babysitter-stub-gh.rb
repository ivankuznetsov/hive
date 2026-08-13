#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"

require_relative "hive-babysitter-skip-log"

scrub_dynamic_loader_env!

require_relative "../lib/hive/babysitter/gh_policy"
require_relative "../lib/hive/babysitter/passthrough_runner"

def make_gh_config_home
  128.times do
    nonce = "%d-%d-%08x" % [
      Process.pid,
      Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
      rand(0x1_0000_0000)
    ]
    path = File.join("/tmp", "hive-babysitter-gh-#{nonce}")
    begin
      Dir.mkdir(path, 0o700)
      return path
    rescue Errno::EEXIST
      next
    end
  end
  raise IOError, "failed to create temporary gh config dir under /tmp"
end

def materialize_trusted_gh_config(source_dir)
  destination_dir = make_gh_config_home
  return destination_dir if source_dir.to_s.empty?

  source_dir_stat = File.lstat(source_dir)
  return destination_dir unless File.absolute_path?(source_dir) && source_dir_stat.directory? &&
    source_dir_stat.uid == Process.uid && (source_dir_stat.mode & 0o022).zero?

  source_path = File.join(source_dir, "hosts.yml")
  preopen_stat = File.lstat(source_path)
  return destination_dir unless preopen_stat.file? && preopen_stat.uid == Process.uid &&
    preopen_stat.nlink == 1 && (preopen_stat.mode & 0o077).zero?

  File.open(source_path, File::RDONLY | File::NOFOLLOW) do |source|
    opened_stat = source.stat
    return destination_dir unless opened_stat.dev == preopen_stat.dev && opened_stat.ino == preopen_stat.ino

    destination_path = File.join(destination_dir, "hosts.yml")
    File.open(destination_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |destination|
      IO.copy_stream(source, destination)
    end
  end

  destination_dir
rescue SystemCallError, IOError
  destination_dir || make_gh_config_home
end

argv = ARGV.map(&:b)
decision = Hive::Babysitter::GhPolicy.classify(argv)
trusted_config_home = ENV["HIVE_BABYSITTER_TRUSTED_GH_CONFIG_DIR"].to_s
config_home = nil

prepare_environment = lambda do |environment|
  scrub_dynamic_loader_env!
  %w[
    RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH GEM_HOME GEM_PATH
    BUNDLER_SETUP BUNDLER_VERSION
    GH_PAGER PAGER GH_BROWSER BROWSER GH_EDITOR GIT_EDITOR VISUAL EDITOR GH_FORCE_TTY
    GH_CONFIG_DIR XDG_CONFIG_HOME HIVE_BABYSITTER_TRUSTED_GH_CONFIG_DIR
    GH_HOST GH_REPO GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
    GIT_ASKPASS GIT_EXEC_PATH GIT_EXTERNAL_DIFF GIT_PAGER GIT_PROXY_COMMAND SSH_ASKPASS
    HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy
    SSL_CERT_FILE SSL_CERT_DIR ssl_cert_file ssl_cert_dir
  ].each { |key| environment.delete(key) }
  environment.keys.grep(/\ABUNDLER_ORIG_/).each { |key| environment.delete(key) }
  environment.keys.grep(/\AGIT_CONFIG/).each { |key| environment.delete(key) }
  environment.keys.grep(/\AGIT_SSH/).each { |key| environment.delete(key) }
  environment.keys.grep(/\AGIT_TRACE/).each { |key| environment.delete(key) }
  environment["PATH"] = "/usr/bin:/bin"
  environment["GH_PROMPT_DISABLED"] = "1"
  config_home = materialize_trusted_gh_config(trusted_config_home)
  environment["HOME"] = config_home
  environment["GH_CONFIG_DIR"] = config_home
end

executor = lambda do |real, command_argv, environment|
  pid = Process.spawn(environment, real, *command_argv)
  _pid, status = Process.wait2(pid)
  status.exitstatus || 128 + status.termsig.to_i
end

cleanup = lambda do
  FileUtils.remove_entry_secure(config_home) if config_home && File.exist?(config_home)
rescue SystemCallError => e
  warn "hive-babysitter dry-run: failed to remove temporary gh config " \
       "#{config_home.inspect}: #{e.message}"
end

runner = Hive::Babysitter::PassthroughRunner.new(
  tool: "gh",
  argv: argv,
  allowed: decision.allowed?,
  real_env_key: "HIVE_BABYSITTER_REAL_GH",
  skip_reporter: -> { log_skip("gh", argv) },
  prepare_environment: prepare_environment,
  executor: executor,
  cleanup: cleanup
)
exit runner.call
