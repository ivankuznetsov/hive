require "open3"

module Hive
  class UserService
    class Manager
      Inspection = Data.define(:available, :enabled, :running, :diagnostics)
      Action = Data.define(:ok, :restarted, :diagnostics)

      def initialize(definition:, runner:, query_available:, manager_available:,
                     status_reader: nil, launchd_running_via_list: false,
                     event_handler: nil, uid: Process.uid)
        @definition = definition
        @runner = runner
        @query_available = query_available
        @manager_available = manager_available
        @status_reader = status_reader
        @launchd_running_via_list = launchd_running_via_list
        @event_handler = event_handler
        @uid = uid
      end

      def inspect
        case @definition.platform
        when :linux then inspect_systemd
        when :macos then inspect_launchd
        else Inspection.new(available: false, enabled: false, running: false, diagnostics: [])
        end
      rescue StandardError
        Inspection.new(
          available: false,
          enabled: false,
          running: false,
          diagnostics: [ :manager_probe_failed ]
        )
      end

      def install(kind:, status:)
        case @definition.platform
        when :linux then install_systemd(kind, status)
        when :macos then install_launchd(kind, status)
        else Action.new(ok: true, restarted: false, diagnostics: [])
        end
      end

      def disable
        case @definition.platform
        when :linux
          ok = query_available? &&
               run([ "systemctl", "--user", "disable", "--now", @definition.service_name ])
          Action.new(ok: ok, restarted: false, diagnostics: ok ? [] : [ :manager_disable_failed ])
        when :macos
          ok = query_available? && run([ "launchctl", "unload", @definition.target_path ])
          Action.new(ok: ok, restarted: false, diagnostics: ok ? [] : [ :manager_disable_failed ])
        else
          Action.new(ok: true, restarted: false, diagnostics: [])
        end
      end

      def reload_after_remove
        return Action.new(ok: true, restarted: false, diagnostics: []) unless @definition.platform == :linux

        ok = query_available? && run(%w[systemctl --user daemon-reload])
        Action.new(ok: ok, restarted: false, diagnostics: ok ? [] : [ :daemon_reload_failed ])
      end

      private

      def inspect_systemd
        queryable = query_available?
        enabled = queryable && run([ "systemctl", "--user", "is-enabled", @definition.service_name ])
        running = queryable &&
                  run([ "systemctl", "--user", "is-active", "--quiet", @definition.service_name ])
        Inspection.new(
          available: manager_available?,
          enabled: enabled,
          running: running,
          diagnostics: []
        )
      end

      def inspect_launchd
        queryable = query_available?
        enabled = queryable && run([ "launchctl", "list", @definition.launchd_label ])
        running = if !queryable
          false
        elsif @launchd_running_via_list
          run([ "launchctl", "list", @definition.launchd_label ])
        else
          output, ok = read_status(
            [ "launchctl", "print", "gui/#{@uid}/#{@definition.launchd_label}" ]
          )
          ok && output.match?(/\bstate\s*=\s*running\b/i)
        end
        Inspection.new(
          available: manager_available?,
          enabled: enabled,
          running: running,
          diagnostics: []
        )
      end

      def install_systemd(kind, status)
        unless query_available? && status.manager_available?
          return Action.new(
            ok: true,
            restarted: false,
            diagnostics: [ :autostart_unavailable ]
          )
        end

        reloaded = run(%w[systemctl --user daemon-reload])
        restarted = kind == :upgraded
        if restarted
          @event_handler&.call(:before_restart, @definition)
          started = run([ "systemctl", "--user", "restart", @definition.service_name ])
        else
          started = run([ "systemctl", "--user", "enable", "--now", @definition.service_name ])
        end
        ok = reloaded && started
        Action.new(
          ok: ok,
          restarted: restarted,
          diagnostics: ok ? [] : [ :systemd_apply_failed ]
        )
      end

      def install_launchd(kind, status)
        return Action.new(ok: true, restarted: false, diagnostics: []) if kind == :unchanged && status.enabled?

        diagnostics = []
        restarted = kind == :upgraded
        if restarted
          unloaded = run([ "launchctl", "unload", @definition.target_path ])
          diagnostics << :launchd_unload_failed unless unloaded
        end
        loaded = run([ "launchctl", "load", @definition.target_path ])
        diagnostics << :launchd_load_failed unless loaded
        Action.new(ok: loaded, restarted: restarted, diagnostics: diagnostics)
      end

      def query_available?
        resolved(@query_available)
      end

      def manager_available?
        resolved(@manager_available)
      end

      def resolved(value)
        value.respond_to?(:call) ? !!value.call : !!value
      end

      def run(argv)
        !!@runner.call(argv)
      rescue SystemCallError
        false
      end

      def read_status(argv)
        return @status_reader.call(argv) if @status_reader

        output, status = Open3.capture2e(*argv)
        [ output, status.success? ]
      rescue SystemCallError
        [ "", false ]
      end
    end
  end
end
