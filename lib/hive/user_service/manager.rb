require "open3"

module Hive
  class UserService
    class Manager
      AVAILABILITIES = %i[available conclusively_absent indeterminate].freeze
      DEFAULT_ACTION_TIMEOUT_SEC = 35
      DEFAULT_QUERY_TIMEOUT_SEC = 10
      ACTION_TIMEOUT_MARGIN_SEC = 5
      TERMINATION_GRACE_SEC = 1
      MAX_CAPTURE_BYTES = 65_536
      SYSTEMD_ENABLED_STATES = %w[enabled enabled-runtime linked linked-runtime alias].freeze
      SYSTEMD_SHOW_PROPERTIES = %w[
        LoadState FragmentPath NeedDaemonReload UnitFileState ActiveState MainPID
        ExecMainStartTimestampMonotonic
      ].freeze

      Inspection = Data.define(
        :availability,
        :enabled,
        :running,
        :active_state,
        :load_state,
        :fragment_path,
        :need_daemon_reload,
        :main_pid,
        :process_start,
        :evidence_source,
        :diagnostics
      ) do
        def initialize(availability:, enabled:, running:, active_state: nil,
                       load_state: nil, fragment_path: nil,
                       need_daemon_reload: nil, main_pid: nil, process_start: nil,
                       evidence_source: :observed, diagnostics: [])
          availability = availability.to_sym
          unless Manager::AVAILABILITIES.include?(availability)
            raise ArgumentError, "unknown manager availability #{availability.inspect}"
          end

          load_state = load_state&.to_s&.tr("-", "_")&.to_sym
          fragment_path = fragment_path.to_s
          fragment_path = nil if fragment_path.empty?
          main_pid = Integer(main_pid, exception: false)
          main_pid = nil unless main_pid&.positive?
          process_start = process_start.to_s
          process_start = nil if process_start.empty? || process_start == "0"

          super(
            availability: availability,
            enabled: !!enabled,
            running: !!running,
            active_state: active_state&.to_s&.tr("-", "_")&.to_sym,
            load_state: load_state,
            fragment_path: fragment_path,
            need_daemon_reload: need_daemon_reload.nil? ? nil : !!need_daemon_reload,
            main_pid: main_pid,
            process_start: process_start,
            evidence_source: evidence_source.to_sym,
            diagnostics: diagnostics.map(&:to_sym).uniq.freeze
          )
        end

        def available = availability == :available

        def loaded_definition?(target_path)
          target_path &&
            load_state == :loaded &&
            fragment_path == File.expand_path(target_path) &&
            need_daemon_reload == false
        end
      end
      Action = Data.define(:ok, :restarted, :diagnostics)
      Command = Data.define(:ok, :output, :failure, :exitstatus) do
        def initialize(ok:, output: "", failure: nil, exitstatus: nil)
          super(
            ok: !!ok,
            output: output.to_s,
            failure: failure&.to_sym,
            exitstatus: exitstatus
          )
        end
      end

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
        else absent_inspection
        end
      rescue Errno::ENOENT
        absent_inspection
      rescue StandardError
        indeterminate_inspection
      end

      # Compatibility wrapper for callers which do not yet persist the reload
      # boundary separately. New transition code should call +reload+, persist
      # that evidence, and then call +activate+.
      def apply_intent(intent)
        case @definition.platform
        when :linux
          unless operation_available?
            return Action.new(ok: false, restarted: false, diagnostics: [ :autostart_unavailable ])
          end

          reloaded = reload
          unless reloaded.ok
            return Action.new(
              ok: false,
              restarted: false,
              diagnostics: ([ :systemd_apply_failed ] + reloaded.diagnostics).uniq
            )
          end

          activate(intent)
        when :macos
          apply_launchd_intent(intent)
        else
          successful_action
        end
      end

      # Reload is deliberately separate from activation so a durable caller can
      # record exactly which manager effect has completed before attempting the
      # next one.
      def reload
        return successful_action unless @definition.platform == :linux
        return failed_action(:daemon_reload_failed) unless operation_available?

        command = run_action_command(%w[systemctl --user daemon-reload])
        Action.new(
          ok: command.ok,
          restarted: false,
          diagnostics: command.ok ? [] : ([ :daemon_reload_failed ] + command_diagnostics(command)).uniq
        )
      end

      # Apply only the recorded activation intent; no implicit daemon-reload is
      # performed here. A restart first establishes enablement so a matching but
      # disabled legacy unit converges in one recorded intent.
      def activate(intent)
        case @definition.platform
        when :linux then activate_systemd_intent(intent)
        when :macos then apply_launchd_intent(intent)
        else successful_action
        end
      end

      def restore(prior_enabled:, prior_running:)
        case @definition.platform
        when :linux
          return failed_action(:manager_restore_failed) unless operation_available?

          reloaded = reload
          commands = if prior_running
            enablement = prior_enabled ? "enable" : "disable"
            [
              [ "systemctl", "--user", enablement, @definition.service_name ],
              [ "systemctl", "--user", "restart", @definition.service_name ]
            ]
          elsif prior_enabled
            [
              [ "systemctl", "--user", "enable", @definition.service_name ],
              [ "systemctl", "--user", "stop", @definition.service_name ]
            ]
          else
            [ [ "systemctl", "--user", "disable", "--now", @definition.service_name ] ]
          end
          results = reloaded.ok ? run_action_commands(commands) : []
          ok = reloaded.ok && results.all?(&:ok)
          diagnostics = if ok
            []
          else
            ([ :manager_restore_failed ] + reloaded.diagnostics + results.flat_map { |result|
              command_diagnostics(result)
            }).uniq
          end
          Action.new(ok: ok, restarted: !!prior_running, diagnostics: diagnostics)
        when :macos
          action = prior_enabled ? apply_launchd_intent(:restart) : disable
          Action.new(ok: action.ok, restarted: prior_running, diagnostics: action.diagnostics)
        else
          successful_action
        end
      end

      def start = lifecycle_action(:start)
      def stop = lifecycle_action(:stop)
      def restart = lifecycle_action(:restart)
      def takeover = lifecycle_action(:restart)

      def disable
        case @definition.platform
        when :linux
          return failed_action(:manager_disable_failed) unless operation_available?

          command = run_action_command(
            [ "systemctl", "--user", "disable", "--now", @definition.service_name ]
          )
          action_from_command(command, :manager_disable_failed)
        when :macos
          return failed_action(:manager_disable_failed) unless operation_available?

          command = run_action_command([ "launchctl", "unload", @definition.target_path ])
          action_from_command(command, :manager_disable_failed)
        else
          successful_action
        end
      end

      def reload_after_remove
        reload
      end

      private

      def inspect_systemd
        availability = operation_availability
        return inspection_for_availability(availability) unless availability == :available

        if @status_reader || @runner.nil?
          inspect_systemd_properties
        else
          inspect_systemd_with_injected_runner
        end
      end

      def inspect_systemd_properties
        command = run_query_command(systemd_show_command)
        return absent_inspection if command.failure == :missing
        return indeterminate_inspection(command) if command.failure

        properties = parse_systemd_properties(command.output)
        return indeterminate_inspection(command) unless properties
        return indeterminate_inspection(command) unless command.ok || properties.fetch("LoadState") == "not-found"

        Inspection.new(
          availability: :available,
          enabled: SYSTEMD_ENABLED_STATES.include?(properties.fetch("UnitFileState")),
          running: properties.fetch("ActiveState") == "active",
          active_state: properties.fetch("ActiveState"),
          load_state: properties.fetch("LoadState"),
          fragment_path: properties.fetch("FragmentPath"),
          need_daemon_reload: parse_systemd_boolean(properties.fetch("NeedDaemonReload")),
          main_pid: properties.fetch("MainPID"),
          process_start: properties.fetch("ExecMainStartTimestampMonotonic"),
          diagnostics: []
        )
      rescue ArgumentError, KeyError
        indeterminate_inspection(command)
      end

      def inspect_systemd_with_injected_runner
        enabled = run_injected_command(
          [ "systemctl", "--user", "is-enabled", @definition.service_name ]
        )
        return query_failure_inspection(enabled) if enabled.failure

        running = run_injected_command(
          [ "systemctl", "--user", "is-active", "--quiet", @definition.service_name ]
        )
        return query_failure_inspection(running) if running.failure

        loaded = enabled.ok || running.ok
        Inspection.new(
          availability: :available,
          enabled: enabled.ok,
          running: running.ok,
          active_state: running.ok ? :active : :inactive,
          load_state: loaded ? :loaded : :not_found,
          fragment_path: loaded ? @definition.target_path : nil,
          need_daemon_reload: false,
          main_pid: running.ok ? 1 : nil,
          process_start: running.ok ? "injected" : nil,
          evidence_source: :injected,
          diagnostics: []
        )
      end

      def inspect_launchd
        availability = operation_availability
        return inspection_for_availability(availability) unless availability == :available

        enabled = run_injected_or_production_query(
          [ "launchctl", "list", @definition.launchd_label ]
        )
        return query_failure_inspection(enabled) if enabled.failure

        running = if @launchd_running_via_list
          run_injected_or_production_query([ "launchctl", "list", @definition.launchd_label ])
        else
          status = run_launchd_status_command(
            [ "launchctl", "print", "gui/#{@uid}/#{@definition.launchd_label}" ]
          )
          return query_failure_inspection(status) if status.failure

          Command.new(ok: status.ok && status.output.match?(/\bstate\s*=\s*running\b/i))
        end
        return query_failure_inspection(running) if running.failure

        Inspection.new(
          availability: :available,
          enabled: enabled.ok,
          running: running.ok,
          active_state: running.ok ? :active : :inactive,
          diagnostics: []
        )
      end

      def activate_systemd_intent(intent)
        restarted = intent.to_sym == :restart
        unless operation_available?
          return Action.new(ok: false, restarted: restarted, diagnostics: [ :autostart_unavailable ])
        end

        commands = if restarted
          [
            [ "systemctl", "--user", "enable", @definition.service_name ],
            [ "systemctl", "--user", "restart", @definition.service_name ]
          ]
        else
          [ [ "systemctl", "--user", "enable", "--now", @definition.service_name ] ]
        end
        results = []
        commands.each_with_index do |command, index|
          @event_handler&.call(:before_restart, @definition) if restarted && index == 1
          result = run_action_command(command)
          results << result
          break unless result.ok
        end
        ok = results.length == commands.length && results.all?(&:ok)
        diagnostics = ok ? [] : ([ :systemd_apply_failed ] + results.flat_map { |result|
          command_diagnostics(result)
        }).uniq
        Action.new(ok: ok, restarted: restarted, diagnostics: diagnostics)
      end

      def apply_launchd_intent(intent)
        restarted = intent.to_sym == :restart
        diagnostics = []
        if restarted
          unloaded = run_action_command([ "launchctl", "unload", @definition.target_path ])
          diagnostics << :launchd_unload_failed unless unloaded.ok
          diagnostics.concat(command_diagnostics(unloaded)) unless unloaded.ok
        end
        loaded = run_action_command([ "launchctl", "load", @definition.target_path ])
        diagnostics << :launchd_load_failed unless loaded.ok
        diagnostics.concat(command_diagnostics(loaded)) unless loaded.ok
        Action.new(ok: loaded.ok, restarted: restarted, diagnostics: diagnostics.uniq)
      end

      def lifecycle_action(verb)
        return failed_action(:manager_action_unavailable) unless operation_available?

        case @definition.platform
        when :linux
          reloaded = if %i[start restart].include?(verb)
            reload
          else
            successful_action
          end
          command = if reloaded.ok
            run_action_command([ "systemctl", "--user", verb.to_s, @definition.service_name ])
          end
          ok = reloaded.ok && command&.ok
          diagnostics = if ok
            []
          else
            ([ :manager_action_failed ] + reloaded.diagnostics + command_diagnostics(command)).uniq
          end
        when :macos
          commands = if verb == :stop
            [ [ "launchctl", "unload", @definition.target_path ] ]
          elsif verb == :start
            [ [ "launchctl", "load", @definition.target_path ] ]
          else
            [
              [ "launchctl", "unload", @definition.target_path ],
              [ "launchctl", "load", @definition.target_path ]
            ]
          end
          results = run_action_commands(commands)
          ok = results.length == commands.length && results.all?(&:ok)
          diagnostics = ok ? [] : ([ :manager_action_failed ] + results.flat_map { |result|
            command_diagnostics(result)
          }).uniq
        else
          ok = true
          diagnostics = []
        end
        Action.new(ok: !!ok, restarted: verb == :restart, diagnostics: diagnostics)
      end

      def successful_action
        Action.new(ok: true, restarted: false, diagnostics: [])
      end

      def failed_action(diagnostic)
        Action.new(ok: false, restarted: false, diagnostics: [ diagnostic ])
      end

      def action_from_command(command, diagnostic)
        Action.new(
          ok: command.ok,
          restarted: false,
          diagnostics: command.ok ? [] : ([ diagnostic ] + command_diagnostics(command)).uniq
        )
      end

      def command_diagnostics(command)
        return [] unless command

        case command.failure
        when :timeout then [ :manager_action_timeout ]
        when :missing then [ :manager_command_missing ]
        when :failed then [ :manager_command_failed ]
        else []
        end
      end

      def query_failure_inspection(command)
        return absent_inspection if command.failure == :missing

        indeterminate_inspection(command)
      end

      def indeterminate_inspection(command = nil)
        diagnostics = [ :manager_probe_failed ]
        diagnostics << :manager_probe_timeout if command&.failure == :timeout
        Inspection.new(
          availability: :indeterminate,
          enabled: false,
          running: false,
          active_state: nil,
          diagnostics: diagnostics
        )
      end

      def absent_inspection
        Inspection.new(
          availability: :conclusively_absent,
          enabled: false,
          running: false,
          active_state: :inactive,
          diagnostics: []
        )
      end

      def inspection_for_availability(availability)
        return absent_inspection if availability == :conclusively_absent

        indeterminate_inspection
      end

      def operation_availability
        return :conclusively_absent unless query_available?

        manager_available_state
      end

      def operation_available?
        operation_availability == :available
      rescue StandardError
        false
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

      def systemd_show_command
        [
          "systemctl", "--user", "show",
          "--property=#{SYSTEMD_SHOW_PROPERTIES.join(',')}",
          "--no-pager",
          @definition.service_name
        ]
      end

      def parse_systemd_properties(output)
        properties = output.to_s.each_line.each_with_object({}) do |line, result|
          key, separator, value = line.chomp.partition("=")
          next if separator.empty? || !SYSTEMD_SHOW_PROPERTIES.include?(key)

          result[key] = value
        end
        return unless SYSTEMD_SHOW_PROPERTIES.all? { |property| properties.key?(property) }

        properties
      end

      def parse_systemd_boolean(value)
        return true if value == "yes"
        return false if value == "no"

        raise ArgumentError, "invalid systemd boolean"
      end

      def run_injected_or_production_query(argv)
        return run_injected_command(argv) if @runner

        run_production(argv, timeout: DEFAULT_QUERY_TIMEOUT_SEC)
      end

      def run_query_command(argv)
        return normalize_command { @status_reader.call(argv) } if @status_reader
        return run_injected_command(argv) if @runner

        run_production(argv, timeout: DEFAULT_QUERY_TIMEOUT_SEC)
      end

      def run_launchd_status_command(argv)
        return normalize_command { @status_reader.call(argv) } if @status_reader
        if @runner
          return normalize_command do
            output, status = Open3.capture2e(*argv)
            [ output, status.success? ]
          end
        end

        run_production(argv, timeout: DEFAULT_QUERY_TIMEOUT_SEC)
      end

      def run_action_command(argv)
        return run_injected_command(argv) if @runner

        run_production(argv, timeout: manager_action_timeout_sec)
      end

      def run_action_commands(commands)
        results = []
        commands.each do |command|
          result = run_action_command(command)
          results << result
          break unless result.ok
        end
        results
      end

      def run_injected_command(argv)
        normalize_command { @runner.call(argv) }
      end

      def normalize_command
        value = yield
        if value.is_a?(Array) && value.length >= 2
          status = value[1]
          ok = status.respond_to?(:success?) ? status.success? : status
          Command.new(ok: ok, output: value[0])
        else
          Command.new(ok: value)
        end
      rescue Errno::ENOENT
        Command.new(ok: false, failure: :missing)
      rescue StandardError
        Command.new(ok: false, failure: :failed)
      end

      # Production commands are spawned into their own process group so a
      # timeout can terminate the complete command tree and synchronously reap
      # its leader. Injected runners remain synchronous test/application seams.
      def run_production(argv, timeout:)
        reader, writer = IO.pipe
        pid = nil
        reaped = false
        output = +""
        pid = Process.spawn(*argv, in: File::NULL, out: writer, err: writer, pgroup: true)
        writer.close
        deadline = monotonic_now + Float(timeout)

        loop do
          drain_output(reader, output)
          if (waited = Process.wait2(pid, Process::WNOHANG))
            reaped = true
            drain_output(reader, output)
            status = waited.last
            return Command.new(
              ok: status.success?,
              output: output,
              exitstatus: status.exitstatus
            )
          end

          remaining = deadline - monotonic_now
          if remaining <= 0
            terminate_and_reap(pid)
            reaped = true
            drain_output(reader, output)
            return Command.new(ok: false, output: output, failure: :timeout)
          end

          IO.select([ reader ], nil, nil, [ remaining, 0.05 ].min)
        end
      rescue Errno::ENOENT
        Command.new(ok: false, output: output, failure: :missing)
      rescue StandardError
        Command.new(ok: false, output: output, failure: :failed)
      ensure
        writer&.close unless writer&.closed?
        reader&.close unless reader&.closed?
        terminate_and_reap(pid) if pid && !reaped
      end

      def drain_output(reader, output)
        loop do
          chunk = reader.read_nonblock(4096, exception: false)
          break if chunk == :wait_readable || chunk.nil?

          remaining = MAX_CAPTURE_BYTES - output.bytesize
          output << chunk.byteslice(0, remaining) if remaining.positive?
        end
      end

      def terminate_and_reap(pid)
        signal_process_group(pid, "TERM")
        deadline = monotonic_now + TERMINATION_GRACE_SEC
        loop do
          waited = Process.wait2(pid, Process::WNOHANG)
          return waited.last if waited
          break if monotonic_now >= deadline

          sleep 0.01
        end

        signal_process_group(pid, "KILL")
        Process.wait2(pid).last
      rescue Errno::ECHILD
        nil
      end

      def signal_process_group(pid, signal)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH
        begin
          Process.kill(signal, pid)
        rescue Errno::ESRCH
          nil
        end
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def manager_action_timeout_sec
        return DEFAULT_ACTION_TIMEOUT_SEC unless @definition.platform == :linux

        line = timeout_unit_content.each_line.find { |candidate| candidate.start_with?("TimeoutStopSec=") }
        return DEFAULT_ACTION_TIMEOUT_SEC unless line

        parse_systemd_seconds(line.split("=", 2).last.strip) + ACTION_TIMEOUT_MARGIN_SEC
      rescue ArgumentError
        DEFAULT_ACTION_TIMEOUT_SEC
      end

      def timeout_unit_content
        path = @definition.target_path
        return @definition.content.to_s unless path

        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags) do |file|
          stat = file.stat
          return @definition.content.to_s unless stat.file? && stat.size <= 256 * 1024

          file.read(256 * 1024 + 1).then do |content|
            content.bytesize <= 256 * 1024 ? content : @definition.content.to_s
          end
        end
      rescue Errno::ENOENT, Errno::ELOOP, Errno::EACCES, Errno::EPERM
        @definition.content.to_s
      end

      def parse_systemd_seconds(value)
        match = value.match(/\A(?<number>\d+(?:\.\d+)?)(?<unit>ms|s|min|h)?\z/)
        raise ArgumentError, "invalid TimeoutStopSec" unless match

        multiplier = { nil => 1, "ms" => 0.001, "s" => 1, "min" => 60, "h" => 3600 }.fetch(match[:unit])
        Float(match[:number]) * multiplier
      end
    end
  end
end
