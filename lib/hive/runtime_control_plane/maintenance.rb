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
        document = journal
        unless document
          document = { "cutover_id" => cutover_id, "services" => inspect_states }
          write_journal(document)
        end
        unless document.fetch("cutover_id") == cutover_id
          raise Error.new("service journal belongs to another cutover", code: :service_lifecycle_failed)
        end
        document.fetch("services").each { |state| stop_service(state) }
        true
      end

      def activate!
        document = journal
        raise Error.new("service journal is missing", code: :service_lifecycle_failed) unless document

        document.fetch("services").each { |state| start_service(state) }
        true
      end

      private

      def inspect_states
        case @platform
        when :linux
          run!(%w[systemctl --user show-environment])
          SERVICES.map do |name|
            { "name" => name,
              "running" => success?([ "systemctl", "--user", "is-active", "--quiet", name ]),
              "enabled" => success?([ "systemctl", "--user", "is-enabled", "--quiet", name ]) }
          end
        when :macos
          domain = "gui/#{Process.uid}"
          run!([ "launchctl", "print", domain ])
          SERVICES.map do |name|
            { "name" => name,
              "running" => success?([ "launchctl", "print", "#{domain}/local.#{name}" ]),
              "enabled" => false }
          end
        else
          raise Error.new("supported service manager is unavailable", code: :service_manager_unavailable)
        end
      rescue Errno::ENOENT => error
        raise Error.new("service manager is unavailable: #{error.message}", code: :service_manager_unavailable)
      end

      def stop_service(state)
        return unless state.fetch("running")
        argv = @platform == :linux ?
          [ "systemctl", "--user", "stop", state.fetch("name") ] :
          [ "launchctl", "bootout", "gui/#{Process.uid}/local.#{state.fetch('name')}" ]
        run!(argv)
      end

      def start_service(state)
        return unless state.fetch("running")
        if @platform == :linux
          run!([ "systemctl", "--user", "start", state.fetch("name") ])
        else
          plist = File.join(@home, "Library", "LaunchAgents", "local.#{state.fetch('name')}.plist")
          run!([ "launchctl", "bootstrap", "gui/#{Process.uid}", plist ])
        end
      end

      def success?(argv) = @runner.call(argv).last.success?

      def run!(argv)
        _output, error, status = @runner.call(argv)
        return true if status.success?
        raise Error.new("service lifecycle failed: #{error.to_s.strip}", code: :service_lifecycle_failed)
      end

      def journal_path = File.join(@state_home, ".runtime-cutover", "current", "services.json")

      def write_journal(document)
        Hive::AtomicFile.write(journal_path, "#{JSON.generate(document)}\n", mode: 0o600)
      end

      def journal
        return unless File.exist?(journal_path) || File.symlink?(journal_path)
        status = File.lstat(journal_path)
        unless status.file? && !status.symlink? && status.nlink == 1 && status.size <= MAX_JOURNAL_BYTES
          raise Error.new("service journal is unsafe", code: :service_lifecycle_failed)
        end
        document = JSON.parse(File.binread(journal_path))
        services = document["services"]
        valid = document.is_a?(Hash) && document.keys.sort == %w[cutover_id services] &&
          document["cutover_id"].is_a?(String) && services.is_a?(Array) &&
          services.map { |state| state["name"] }.sort == SERVICES.sort &&
          services.all? do |state|
            state.keys.sort == %w[enabled name running] &&
              [ true, false ].include?(state["enabled"]) && [ true, false ].include?(state["running"])
          end
        raise Error.new("service journal is invalid", code: :service_lifecycle_failed) unless valid
        document
      rescue JSON::ParserError, SystemCallError
        raise Error.new("service journal is invalid", code: :service_lifecycle_failed)
      end
    end
  end
end
