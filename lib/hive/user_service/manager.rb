require "open3"
require "timeout"

module Hive
  class UserService
    class Manager
      AVAILABILITIES = %i[available conclusively_absent indeterminate].freeze
      DEFAULT_ACTION_TIMEOUT_SEC = 35
      ACTION_TIMEOUT_MARGIN_SEC = 5
      Inspection = Data.define(:availability, :enabled, :running, :diagnostics) do
        def initialize(availability:, enabled:, running:, diagnostics: [])
          availability = availability.to_sym
          unless Manager::AVAILABILITIES.include?(availability)
            raise ArgumentError, "unknown manager availability #{availability.inspect}"
          end

          super(
            availability: availability,
            enabled: !!enabled,
            running: !!running,
            diagnostics: diagnostics.map(&:to_sym).uniq.freeze
          )
        end

        def available = availability == :available
      end
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
        else Inspection.new(availability: :conclusively_absent, enabled: false, running: false, diagnostics: [])
        end
      rescue StandardError
        Inspection.new(
          availability: :indeterminate,
          enabled: false,
          running: false,
          diagnostics: [ :manager_probe_failed ]
        )
      end

      def apply_intent(intent)
        case @definition.platform
        when :linux then apply_systemd_intent(intent)
        when :macos then apply_launchd_intent(intent)
        else Action.new(ok: true, restarted: false, diagnostics: [])
        end
      end

      def restore(prior_enabled:, prior_running:)
        case @definition.platform
        when :linux
          return failed_action(:manager_restore_failed) unless manager_available_state == :available

          reloaded = run_action(%w[systemctl --user daemon-reload])
          restored = if prior_running
            run_action([ "systemctl", "--user", "restart", @definition.service_name ])
          elsif prior_enabled
            run_action([ "systemctl", "--user", "enable", @definition.service_name ]) &&
              run_action([ "systemctl", "--user", "stop", @definition.service_name ])
          else
            run_action([ "systemctl", "--user", "disable", "--now", @definition.service_name ])
          end
          Action.new(
            ok: reloaded && restored,
            restarted: !!prior_running,
            diagnostics: reloaded && restored ? [] : [ :manager_restore_failed ]
          )
        when :macos
          action = prior_enabled ? apply_launchd_intent(:restart) : disable
          Action.new(ok: action.ok, restarted: prior_running, diagnostics: action.diagnostics)
        else
          Action.new(ok: true, restarted: false, diagnostics: [])
        end
      end

      def start = lifecycle_action(:start)
      def stop = lifecycle_action(:stop)
      def restart = lifecycle_action(:restart)
      def takeover = lifecycle_action(:restart)

      def disable
        case @definition.platform
        when :linux
          ok = query_available? &&
               run_action([ "systemctl", "--user", "disable", "--now", @definition.service_name ])
          Action.new(ok: ok, restarted: false, diagnostics: ok ? [] : [ :manager_disable_failed ])
        when :macos
          ok = query_available? && run_action([ "launchctl", "unload", @definition.target_path ])
          Action.new(ok: ok, restarted: false, diagnostics: ok ? [] : [ :manager_disable_failed ])
        else
          Action.new(ok: true, restarted: false, diagnostics: [])
        end
      end

      def reload_after_remove
        return Action.new(ok: true, restarted: false, diagnostics: []) unless @definition.platform == :linux

        ok = query_available? && run_action(%w[systemctl --user daemon-reload])
        Action.new(ok: ok, restarted: false, diagnostics: ok ? [] : [ :daemon_reload_failed ])
      end

      private

      def inspect_systemd
        queryable = query_available?
        availability = queryable ? manager_available_state : :conclusively_absent
        return Inspection.new(
          availability: availability, enabled: false, running: false,
          diagnostics: availability == :indeterminate ? [ :manager_probe_failed ] : []
        ) unless availability == :available

        enabled = queryable && run([ "systemctl", "--user", "is-enabled", @definition.service_name ])
        running = queryable &&
                  run([ "systemctl", "--user", "is-active", "--quiet", @definition.service_name ])
        Inspection.new(
          availability: availability,
          enabled: enabled,
          running: running,
          diagnostics: []
        )
      end

      def inspect_launchd
        queryable = query_available?
        availability = queryable ? manager_available_state : :conclusively_absent
        return Inspection.new(
          availability: availability, enabled: false, running: false,
          diagnostics: availability == :indeterminate ? [ :manager_probe_failed ] : []
        ) unless availability == :available

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
          availability: availability,
          enabled: enabled,
          running: running,
          diagnostics: []
        )
      end

      def apply_systemd_intent(intent)
        unless query_available? && manager_available_state == :available
          return Action.new(ok: false, restarted: false, diagnostics: [ :autostart_unavailable ])
        end

        reloaded = run_action(%w[systemctl --user daemon-reload])
        restarted = intent.to_sym == :restart
        @event_handler&.call(:before_restart, @definition) if restarted
        command = restarted ?
          [ "systemctl", "--user", "restart", @definition.service_name ] :
          [ "systemctl", "--user", "enable", "--now", @definition.service_name ]
        activated = run_action(command)
        Action.new(
          ok: reloaded && activated,
          restarted: restarted,
          diagnostics: reloaded && activated ? [] : [ :systemd_apply_failed ]
        )
      end

      def apply_launchd_intent(intent)
        restarted = intent.to_sym == :restart
        diagnostics = []
        if restarted
          unloaded = run_action([ "launchctl", "unload", @definition.target_path ])
          diagnostics << :launchd_unload_failed unless unloaded
        end
        loaded = run_action([ "launchctl", "load", @definition.target_path ])
        diagnostics << :launchd_load_failed unless loaded
        Action.new(ok: loaded, restarted: restarted, diagnostics: diagnostics)
      end

      def lifecycle_action(verb)
        return failed_action(:manager_action_unavailable) unless query_available? && manager_available_state == :available

        case @definition.platform
        when :linux
          reloaded = !%i[start restart].include?(verb) ||
                     run_action(%w[systemctl --user daemon-reload])
          ok = reloaded && run_action([ "systemctl", "--user", verb.to_s, @definition.service_name ])
        when :macos
          ok = if verb == :stop
            run_action([ "launchctl", "unload", @definition.target_path ])
          elsif verb == :start
            run_action([ "launchctl", "load", @definition.target_path ])
          else
            run_action([ "launchctl", "unload", @definition.target_path ]) &&
              run_action([ "launchctl", "load", @definition.target_path ])
          end
        else
          ok = true
        end
        Action.new(ok: ok, restarted: verb == :restart, diagnostics: ok ? [] : [ :manager_action_failed ])
      end

      def failed_action(diagnostic)
        Action.new(ok: false, restarted: false, diagnostics: [ diagnostic ])
      end

      def query_available?
        resolved(@query_available)
      end

      def manager_available_state
        value = @manager_available.respond_to?(:call) ? @manager_available.call : @manager_available
        return :available if value == true
        return :conclusively_absent if value == false || value.nil?

        state = value.to_sym
        return state if AVAILABILITIES.include?(state)

        :indeterminate
      end

      def resolved(value)
        value.respond_to?(:call) ? !!value.call : !!value
      end

      def run(argv)
        !!@runner.call(argv)
      rescue SystemCallError
        false
      end

      def run_action(argv)
        Timeout.timeout(manager_action_timeout_sec) { !!@runner.call(argv) }
      rescue SystemCallError, Timeout::Error
        false
      end

      def manager_action_timeout_sec
        return DEFAULT_ACTION_TIMEOUT_SEC unless @definition.platform == :linux

        line = @definition.content.to_s.each_line.find { |candidate| candidate.start_with?("TimeoutStopSec=") }
        return DEFAULT_ACTION_TIMEOUT_SEC unless line

        parse_systemd_seconds(line.split("=", 2).last.strip) + ACTION_TIMEOUT_MARGIN_SEC
      rescue ArgumentError
        DEFAULT_ACTION_TIMEOUT_SEC
      end

      def parse_systemd_seconds(value)
        match = value.match(/\A(?<number>\d+(?:\.\d+)?)(?<unit>ms|s|min|h)?\z/)
        raise ArgumentError, "invalid TimeoutStopSec" unless match

        multiplier = { nil => 1, "ms" => 0.001, "s" => 1, "min" => 60, "h" => 3600 }.fetch(match[:unit])
        Float(match[:number]) * multiplier
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
