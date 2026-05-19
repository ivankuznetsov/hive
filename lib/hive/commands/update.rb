require "hive"
require "hive/install_channel"

module Hive
  module Commands
    class Update
      # Centralised org+repo + brew tap so a future rename of the
      # repository is a one-diff change. The installer URL pins to the
      # current release tag (Hive::VERSION) rather than `main` so
      # `hive update` doesn't keep re-running an unpinned script.
      REPO_OWNER = "ivankuznetsov".freeze
      REPO_NAME = "hive".freeze
      BREW_TAP = "#{REPO_OWNER}/#{REPO_NAME}/hive".freeze
      INSTALL_URL = "https://raw.githubusercontent.com/#{REPO_OWNER}/#{REPO_NAME}/v#{Hive::VERSION}/install.sh".freeze

      def initialize(dry_run: false, output: $stdout, runner: nil, env: ENV, channel: nil)
        @dry_run = dry_run
        @output = output
        @runner = runner || ->(argv) { Kernel.exec(*argv) }
        @env = env
        @channel = channel
      end

      def call
        channel = @channel || Hive::InstallChannel.detect
        argv = command_for(channel)
        if argv.nil?
          @output.puts "channel: dev"
          @output.puts "suggested action: git pull && bundle install"
          return 0
        end

        if @dry_run
          @output.puts "channel: #{channel}"
          @output.puts "command: #{argv.join(' ')}"
          return 0
        end

        invoke!(argv)
      end

      private

      def command_for(channel)
        case channel
        when "brew" then [ "brew", "upgrade", BREW_TAP ]
        when "aur" then aur_command
        when "bash" then bash_installer_command
        when "dev" then nil
        else
          raise Hive::ConfigError, "unknown hive install channel #{channel.inspect}"
        end
      end

      def bash_installer_command
        script = [
          "set -euo pipefail",
          'tmpdir="$(mktemp -d)"',
          'trap \'rm -rf "$tmpdir"\' EXIT',
          "curl -fsSL #{INSTALL_URL} -o \"$tmpdir/install.sh\"",
          'bash "$tmpdir/install.sh"'
        ].join("; ")
        [ "bash", "-c", script ]
      end

      # Preflight the helper binary so a missing `brew` / `curl` /
      # `yay` produces an actionable error instead of a Ruby ENOENT
      # stacktrace from the process-replace call. The `bash` channel
      # invokes `curl` inside the shell command, so we check curl
      # rather than bash.
      def invoke!(argv)
        helper = primary_helper(argv)
        unless helper_available?(helper)
          raise Hive::UnavailableError,
                "hive update: required helper '#{helper}' not found on PATH; install it and re-run"
        end

        @runner.call(argv)
      rescue Errno::ENOENT => e
        raise Hive::UnavailableError, "hive update: #{e.message}"
      end

      # Absolute paths come pre-resolved (e.g. from `aur_command`'s own
      # `which("yay")` lookup); skip the PATH probe for those and trust
      # the executable bit.
      def helper_available?(helper)
        return File.executable?(helper) if helper.start_with?("/")

        !which(helper).nil?
      end

      def primary_helper(argv)
        case argv.first
        when "bash" then "curl"
        else argv.first
        end
      end

      def aur_command
        helper = which("yay") || which("paru")
        unless helper
          raise Hive::UnavailableError,
                "hive update: install yay or paru, or re-run the bash installer from install.md"
        end

        [ helper, "-Syu", "hive-bin" ]
      end

      def which(name)
        Array(@env["PATH"].to_s.split(File::PATH_SEPARATOR)).each do |dir|
          path = File.join(dir, name)
          return path if File.file?(path) && File.executable?(path)
        end
        nil
      end
    end
  end
end
