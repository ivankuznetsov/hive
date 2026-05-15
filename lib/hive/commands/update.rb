require "hive/install_channel"

module Hive
  module Commands
    class Update
      INSTALL_URL = "https://raw.githubusercontent.com/ivankuznetsov/hive/main/install.sh".freeze

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

        @runner.call(argv)
      end

      private

      def command_for(channel)
        case channel
        when "brew" then %w[brew upgrade ivankuznetsov/hive/hive]
        when "aur" then aur_command
        when "bash" then [ "bash", "-c", "curl -fsSL #{INSTALL_URL} | bash" ]
        when "dev" then nil
        else
          raise Hive::ConfigError, "unknown hive install channel #{channel.inspect}"
        end
      end

      def aur_command
        helper = which("yay") || which("paru")
        unless helper
          raise Hive::UnavailableError,
                "hive update: install yay or paru, or re-run the bash installer: curl -fsSL #{INSTALL_URL} | bash"
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
