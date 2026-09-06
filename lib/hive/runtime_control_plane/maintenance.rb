require "json"
require "open3"
require "rbconfig"
require "hive/atomic_file"
require "hive/paths"
require "hive/runtime_control_plane"

module Hive
  module RuntimeControlPlane
    # Small, idempotent service quiescence boundary for the irreversible
    # cutover. Launcher publication belongs exclusively to the package manager.
    class MaintenanceServices
      SERVICES = %w[hive-daemon hive-bot hive-web].freeze
      MAX_JOURNAL_BYTES = 1024 * 1024

      def initialize(state_home: Hive::Paths.state_home, home: ENV["HOME"] || Dir.home,
                     host_os: RbConfig::CONFIG["host_os"], runner: nil)
        @state_home = File.expand_path(state_home)
        @home = File.expand_path(home)
        @host_os = host_os
        @platform = host_os.match?(/darwin/i) ? :macos : (host_os.match?(/linux/i) ? :linux : :unsupported)
        @runner = runner
      end

      def stop!(cutover_id:)
        document = journal || { "cutover_id" => cutover_id, "running" => running_services,
                                "activated" => false }.tap do |value|
          Hive::AtomicFile.write(journal_path, "#{JSON.generate(value)}\n", mode: 0o600)
        end
        raise Error.new("service journal belongs to another cutover", code: :service_lifecycle_failed) unless
          document.fetch("cutover_id") == cutover_id
        document.fetch("running").each { |name| transition!(:stop, name) }
        true
      end

      def activate!
        document = journal
        raise Error.new("service journal is missing", code: :service_lifecycle_failed) unless document
        return true if document.fetch("activated")

        document.fetch("running").each { |name| transition!(:start, name) }
        Hive::AtomicFile.write(
          journal_path, "#{JSON.generate(document.merge("activated" => true))}\n", mode: 0o600
        )
        true
      end

      def activated? = journal&.fetch("activated") == true

      private

      def running_services
        probe = case @platform
        when :linux
          run!(%w[systemctl --user show-environment])
          ->(name) { [ "systemctl", "--user", "is-active", "--quiet", name ] }
        when :macos
          domain = "gui/#{Process.uid}"
          run!([ "launchctl", "print", domain ])
          ->(name) { [ "launchctl", "print", "#{domain}/local.#{name}" ] }
        else
          raise Error.new("supported service manager is unavailable", code: :service_manager_unavailable)
        end
        SERVICES.select { |name| success?(probe.call(name)) }
      rescue Errno::ENOENT => error
        raise Error.new("service manager is unavailable: #{error.message}", code: :service_manager_unavailable)
      end

      def transition!(action, name)
        service_installer(name).public_send("#{action}!")
        true
      rescue Hive::Error => error
        raise Error.new(
          "service lifecycle failed for #{name}: #{error.message}",
          code: :service_lifecycle_failed
        )
      end

      def success?(argv)
        _error, status = command_result(argv)
        command_success?(status)
      end

      def run!(argv)
        error, status = command_result(argv)
        return true if command_success?(status)

        raise Error.new("service lifecycle failed: #{error.to_s.strip}", code: :service_lifecycle_failed)
      end

      def run_raw(argv) = @runner ? @runner.call(argv) : Open3.capture3(*argv)

      def command_result(argv)
        value = run_raw(argv)
        value.is_a?(Array) ? [ value[1], value.last ] : [ "", value ]
      end

      def command_success?(status)
        status.respond_to?(:success?) ? status.success? : !!status
      end

      def service_installer(name)
        klass = case name
        when "hive-daemon"
          require "hive/commands/daemon/service_installer"
          Hive::Commands::Daemon::ServiceInstaller
        when "hive-bot"
          require "hive/commands/bot/service_installer"
          Hive::Commands::Bot::ServiceInstaller
        when "hive-web"
          require "hive/config"
          require "hive/commands/web/service_installer"
          Hive::Commands::Web::ServiceInstaller
        else raise Error.new("unknown managed service #{name}", code: :service_lifecycle_failed)
        end
        options = {
          home: @home,
          host_os: @host_os,
          systemctl_available: @platform == :linux,
          launchctl_available: @platform == :macos
        }
        options[:runner] = ->(argv) { success?(argv) } if @runner
        options[:config] = Hive::Config::DEFAULTS.fetch("web") if name == "hive-web"
        klass.new(**options)
      end

      def journal_path = File.join(@state_home, ".runtime-cutover", "current", "services.json")

      def journal
        return unless File.exist?(journal_path) || File.symlink?(journal_path)
        status = File.lstat(journal_path)
        unless status.file? && !status.symlink? && status.nlink == 1 && status.size <= MAX_JOURNAL_BYTES
          raise Error.new("service journal is unsafe", code: :service_lifecycle_failed)
        end
        document = JSON.parse(File.binread(journal_path))
        running = document["running"]
        valid = document.is_a?(Hash) && document.keys.sort == %w[activated cutover_id running] &&
          document["cutover_id"].is_a?(String) && running.is_a?(Array) &&
          [ true, false ].include?(document["activated"]) &&
          running.uniq == running && (running - SERVICES).empty?
        raise Error.new("service journal is invalid", code: :service_lifecycle_failed) unless valid
        document
      rescue JSON::ParserError, SystemCallError
        raise Error.new("service journal is invalid", code: :service_lifecycle_failed)
      end
    end
  end
end
