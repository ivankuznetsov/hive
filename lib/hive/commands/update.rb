require "hive"
require "hive/install_channel"
require "shellwords"

module Hive
  module Commands
    class Update
      # Centralised org+repo + brew tap so a future rename of the
      # repository is a one-diff change. The installer URL pins to the
      # default branch so older bash-channel installs can fetch the
      # newest installer rather than re-running their own vX.Y.Z script
      # forever. The script is downloaded to a tmpfile before execution;
      # no pipe-to-bash path is used here.
      REPO_OWNER = "ivankuznetsov".freeze
      REPO_NAME = "hive".freeze
      BREW_TAP = "#{REPO_OWNER}/#{REPO_NAME}/hive".freeze
      INSTALL_URL = "https://raw.githubusercontent.com/#{REPO_OWNER}/#{REPO_NAME}/main/install.sh".freeze

      # Canonical one-line command shown to the user when they're behind,
      # per channel. Reuses BREW_TAP so a tap rename stays a one-diff change.
      # Returns nil for dev (git clone — `git pull` is the right move, but
      # there's no single canonical command to nudge). The bash channel is
      # nudge-only until the daemon auto-update spike (U7) lands; `hive update`
      # re-runs the installer in place. The aur nudge mirrors `aur_command`'s
      # `-Syu` (not a bare `-S`): a DB sync is required, or a stale local DB
      # would "update" to an older hive-bin than the release being nudged.
      def self.nudge_command(channel)
        case channel
        when "brew" then "brew upgrade #{BREW_TAP}"
        when "aur" then "yay -Syu hive-bin"
        when "bash" then "hive update"
        end
      end

      def initialize(dry_run: false, output: $stdout, runner: nil, env: ENV, channel: nil)
        @dry_run = dry_run
        @output = output
        @runner = runner || ->(argv) { Kernel.exec(*argv) }
        @env = env
        @channel = channel
      end

      def call
        channel = @channel || Hive::InstallChannel.detect
        prefix = @channel.nil? && channel == "bash" ? Hive::InstallChannel.detected_prefix : nil
        argv = command_for(channel, prefix: prefix)
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

      def command_for(channel, prefix: nil)
        case channel
        when "brew" then [ "brew", "upgrade", BREW_TAP ]
        when "aur" then aur_command
        when "bash" then bash_installer_command(prefix: prefix)
        when "dev" then nil
        else
          raise Hive::ConfigError, "unknown hive install channel #{channel.inspect}"
        end
      end

      def bash_installer_command(prefix: nil)
        prefix_arg = prefix ? " --prefix=#{Shellwords.escape(prefix)}" : ""
        script = [
          "set -euo pipefail",
          'tmpdir="$(mktemp -d)"',
          'trap \'rm -rf "$tmpdir"\' EXIT',
          "curl -fsSL #{INSTALL_URL} -o \"$tmpdir/install.sh\"",
          "bash \"$tmpdir/install.sh\"#{prefix_arg}"
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
