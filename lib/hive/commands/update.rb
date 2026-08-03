require "hive"
require "hive/install_channel"
require "hive/invoked_binary"
require "shellwords"

module Hive
  module Commands
    class Update
      # Org+repo come from Hive::REPO_OWNER/REPO_NAME (one rename point). The
      # installer URL pins to the default branch so older bash-channel installs
      # fetch the newest installer rather than re-running their own vX.Y.Z
      # script forever. The script is downloaded to a tmpfile before execution;
      # no pipe-to-bash path is used here.
      BREW_TAP = "#{Hive::REPO_OWNER}/#{Hive::REPO_NAME}/hive".freeze
      INSTALL_URL = "https://raw.githubusercontent.com/#{Hive::REPO_OWNER}/#{Hive::REPO_NAME}/main/install.sh".freeze

      # Canonical one-line command shown to installed users when they're
      # behind. Routing every package channel through `hive update` keeps the
      # automatic migration phase in the guided path; the command re-dispatches
      # to the channel-specific helper. Dev clones have no single automatic
      # update action, so their nudge remains nil.
      def self.nudge_command(channel)
        case channel
        when "brew", "aur", "bash" then "hive update"
        end
      end

      CommandResult = Struct.new(:success, :exitstatus, keyword_init: true) do
        def success?
          success
        end
      end

      def initialize(dry_run: false, output: $stdout, runner: nil, env: ENV, channel: nil,
                     binary_resolver: nil)
        @dry_run = dry_run
        @output = output
        @runner = runner || method(:run_command)
        @env = env
        @channel = channel
        @binary_resolver = binary_resolver || method(:resolve_updated_binary)
      end

      def call
        channel = @channel || Hive::InstallChannel.detect
        prefix = @channel.nil? && channel == "bash" ? Hive::InstallChannel.detected_prefix : nil
        argv = command_for(channel, prefix: prefix)
        if argv.nil?
          @output.puts "channel: dev"
          @output.puts "suggested action: git pull && bundle install && hive migrate --all"
          return 0
        end

        if @dry_run
          @output.puts "channel: #{channel}"
          @output.puts "command: #{argv.join(' ')}"
          binary = @binary_resolver.call || "hive"
          @output.puts "post-update migration: #{Shellwords.join([ binary, 'migrate', '--all' ])}"
          return 0
        end

        @output.puts "hive: update: running #{channel} updater"
        invoke_updater!(argv)

        binary = @binary_resolver.call
        unless binary
          raise Hive::UnavailableError,
                "hive update: update installed but the updated Hive executable could not be found; " \
                "run `hive migrate --all` after restoring Hive on PATH"
        end

        migration_argv = [ binary, "migrate", "--all" ]
        @output.puts "hive: update: installed; starting automatic migration"
        result = @runner.call(migration_argv)
        unless command_succeeded?(result)
          raise Hive::Error,
                "hive update: automatic migration failed#{failure_detail(result)}; review the migration " \
                "errors above, then rerun `#{Shellwords.join(migration_argv)}`"
        end

        @output.puts "hive: update: complete; automatic migration succeeded"
        0
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
      def invoke_updater!(argv)
        helper = primary_helper(argv)
        unless helper_available?(helper)
          raise Hive::UnavailableError,
                "hive update: required helper '#{helper}' not found on PATH; install it and re-run"
        end

        result = @runner.call(argv)
        return result if command_succeeded?(result)

        raise Hive::Error,
              "hive update: updater failed#{failure_detail(result)}; automatic migration was not started"
      rescue Errno::ENOENT => e
        raise Hive::UnavailableError, "hive update: #{e.message}"
      end

      def run_command(argv)
        success = system(*argv)
        CommandResult.new(success: success == true, exitstatus: $?&.exitstatus)
      end

      def command_succeeded?(result)
        return result if result == true || result == false

        result.respond_to?(:success?) && result.success?
      end

      def failure_detail(result)
        status = result.exitstatus if result.respond_to?(:exitstatus)
        status ? " (exit #{status})" : ""
      end

      def resolve_updated_binary
        invoked = Hive::InvokedBinary.path(env: @env)
        names = [ File.basename(invoked.to_s), "hive", "hv" ] & Hive::InvokedBinary::VALID_NAMES
        names.each do |name|
          resolved = Hive::InvokedBinary.which(name, env: @env)
          return resolved if resolved
        end

        invoked if invoked && File.file?(invoked) && File.executable?(invoked)
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
        Hive::InvokedBinary.which(name, env: @env)
      end
    end
  end
end
