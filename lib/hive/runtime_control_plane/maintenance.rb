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
        @platform = host_os.match?(/darwin/i) ? :macos : (host_os.match?(/linux/i) ? :linux : :unsupported)
        @runner = runner || ->(argv) { Open3.capture3(*argv) }
      end

      def stop!(cutover_id:)
        document = journal || { "cutover_id" => cutover_id, "running" => running_services }.tap do |value|
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

        document.fetch("running").each { |name| transition!(:start, name) }
        true
      end

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
        command = if @platform == :linux
          [ "systemctl", "--user", action.to_s, name ]
        elsif action == :stop
          [ "launchctl", "bootout", "gui/#{Process.uid}/local.#{name}" ]
        else
          [ "launchctl", "bootstrap", "gui/#{Process.uid}",
            File.join(@home, "Library", "LaunchAgents", "local.#{name}.plist") ]
        end
        run!(command)
      end

      def success?(argv) = @runner.call(argv).last.success?

      def run!(argv)
        _output, error, status = @runner.call(argv)
        return true if status.success?
        raise Error.new("service lifecycle failed: #{error.to_s.strip}", code: :service_lifecycle_failed)
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
        valid = document.is_a?(Hash) && document.keys.sort == %w[cutover_id running] &&
          document["cutover_id"].is_a?(String) && running.is_a?(Array) &&
          running.uniq == running && (running - SERVICES).empty?
        raise Error.new("service journal is invalid", code: :service_lifecycle_failed) unless valid
        document
      rescue JSON::ParserError, SystemCallError
        raise Error.new("service journal is invalid", code: :service_lifecycle_failed)
      end
    end
  end
end
