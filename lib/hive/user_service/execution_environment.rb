require "open3"
require "rexml/document"
require "shellwords"
require "time"
require "hive/user_service/definition"
require "hive/user_service/status"
require "hive/secret_patterns"
require "hive/agent_cli_identity"

module Hive
  class UserService
    # Read installed configuration without rendering templates or changing service
    # lifecycle. #call includes absent contexts so callers can distinguish absence
    # from an unreadable installation. environments contain only resolution keys.
    class ExecutionEnvironment
      MANAGER_CALL_SECONDS = 5.0
      MANAGER_PASS_SECONDS = 10.0
      CLEANUP_SECONDS = 0.2
      MAX_CAPTURE_BYTES = 65_536
      MAX_SOURCE_BYTES = 262_144
      PRECHECK = '[ -x "$0" ] || exit 0; exec "$0" "$@"'.freeze

      Context = Data.define(
        :label, :environment, :cwd, :cwd_provenance, :installation,
        :reasons, :sources, :running_currency
      ) do
        def installed? = installation == :installed
        def absent? = installation == :absent
        def complete? = installed? && reasons.empty?
        def probe_allowed? = complete? && %i[current stopped].include?(running_currency)
        def to_h
          members.to_h do |member|
            value = public_send(member)
            value = value.transform_values { |setting| Hive::SecretPatterns.redact(setting) } if member == :environment
            value = Hive::SecretPatterns.redact(value) if value.is_a?(String)
            [ member, value ]
          end
        end
        def inspect = "#<#{self.class} #{to_h.inspect}>"
      end

      # definitions is an optional label => UserService::Definition map. status_reader
      # receives a definition and returns UserService::Status. manager_runner receives
      # read-only argv and timeout: (cleanup included), returning ok/output/failure.
      def initialize(project_root:, profiles:, platform: nil, home: Dir.home,
                     definitions: nil, status_reader: nil, manager_runner: nil,
                     manager_environment: nil, excluded_executables: [],
                     systemd_roots: nil, monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     wall_clock: -> { Time.now })
        @profiles = profiles
        @excluded_executables = excluded_executables
        @explicit_manager_environment = manager_environment
        @home = File.expand_path(home)
        @project_root = File.expand_path(project_root)
        @platform = (platform || (RUBY_PLATFORM.include?("darwin") ? :macos : :linux)).to_sym
        @keys = ([ "PATH", "HOME" ] + profiles.flat_map do |profile|
          runtime = profile.respond_to?(:runtime_profile) ? profile.runtime_profile : profile
          Array(runtime.env_bin_override_keys)
        end).map(&:to_s).uniq.freeze
        @definitions = definitions
        @status_reader = status_reader
        @manager_runner = manager_runner
        @systemd_roots = systemd_roots || [
          "/usr/lib/systemd/user", "/usr/local/lib/systemd/user", "/etc/systemd/user",
          "/run/systemd/user", File.join(@home, ".config/systemd/user")
        ]
        @monotonic = monotonic
        @wall_clock = wall_clock
      end

      def call
        @manager_deadline = @monotonic.call + MANAGER_PASS_SECONDS
        @excluded_identities = profile_executable_identities
        @inherited_environment = inherited_environment
        definitions.map { |label, definition| read_context(label, definition) }.freeze
      end

      private

      def definitions
        @definitions ||= begin
          require "hive/commands/daemon/service_installer"
          require "hive/commands/babysit/service_installer"
          host_os = @platform == :macos ? "darwin" : @platform.to_s
          {
            "daemon" => Hive::Commands::Daemon::ServiceInstaller,
            "babysitter" => Hive::Commands::Babysit::ServiceInstaller
          }.transform_values do |klass|
            klass.new(home: @home, host_os: host_os, environment: {}).service_definition(include_content: false)
          end
        end
      end

      def read_context(label, definition)
        state = { environment: { "HOME" => @home }.merge(@inherited_environment.fetch(:environment)), cwd: @project_root,
                  cwd_provenance: :inherited, reasons: [], sources: [] }
        if definition.platform == :unsupported
          reason(state, :unsupported_platform)
          return context(label, state, :indeterminate, :unknown)
        end
        metadata = manager_metadata(definition)
        status = @status_reader ? @status_reader.call(definition) : metadata[:status]
        path = metadata[:fragment_path] || (definition.platform == :linux && status&.fragment_path) || offline_fragment(definition)
        Array(metadata[:reasons]).each { |code| reason(state, code, path: definition.target_path) }
        Array(@inherited_environment[:reasons]).each { |code| reason(state, code, path: definition.target_path) }
        content, installation = read_source(path, state)
        return context(label, state, installation, :unknown) unless content

        if definition.platform == :linux
          read_systemd(content, path, state, definition, metadata)
        else
          read_launchd(content, path, state)
        end
        reason(state, :path_unresolved, path: path) if state[:environment]["PATH"].to_s.empty?
        currency = running_currency(status, state, definition)
        context(label, state, :installed, currency)
      rescue StandardError
        reason(state, :service_evidence_unavailable, path: definition.target_path)
        context(label, state, :indeterminate, :unknown)
      end

      def context(label, state, installation, currency)
        Context.new(
          label: redact(label).freeze,
          environment: state[:environment].to_h { |key, value| [ key.freeze, value.dup.freeze ] }.freeze,
          cwd: state[:cwd].dup.freeze, cwd_provenance: state[:cwd_provenance],
          installation: installation, reasons: state[:reasons].uniq.freeze,
          sources: state[:sources].uniq.freeze, running_currency: currency
        )
      end

      def read_source(path, state, optional: false)
        content = File.open(path, File::RDONLY | File::NONBLOCK) do |file|
          unless file.stat.file?
            reason(state, :source_not_regular, path: path)
            return [ nil, :indeterminate ]
          end
          bytes = file.read(MAX_SOURCE_BYTES + 1).to_s
          if bytes.bytesize > MAX_SOURCE_BYTES
            reason(state, :source_too_large, path: path)
            return [ nil, :indeterminate ]
          end
          bytes.force_encoding(Encoding::UTF_8)
        end
        unless content.valid_encoding?
          reason(state, :source_encoding_invalid, path: path)
          return [ nil, :indeterminate ]
        end
        state[:sources] << { path: redact(path).freeze, mtime: File.mtime(path).to_f }.freeze
        [ content, :installed ]
      rescue Errno::ENOENT, Errno::ENOTDIR
        reason(state, :required_source_missing, path: path) unless optional
        [ nil, :absent ]
      rescue SystemCallError, IOError
        reason(state, :source_unreadable, path: path)
        [ nil, :indeterminate ]
      end

      def read_systemd(content, path, state, definition, metadata)
        entries = service_entries(content, path, state)
        dropins = systemd_dropins(definition, metadata)
        dropins.each do |dropin|
          text, = read_source(dropin, state)
          entries.concat(service_entries(text, dropin, state)) if text
        end
        environment_files = []
        unset = []
        execs = []
        entries.each do |key, value, source, line|
          case key
          when "Environment"
            if value.empty?
              state[:environment] = { "HOME" => @home }.merge(@inherited_environment.to_h.fetch(:environment, {}))
            else
              words(value, state, source, line).each do |assignment|
                name, separator, setting = assignment.partition("=")
                next unless @keys.include?(name)
                if separator.empty?
                  reason(state, :invalid_environment_assignment, path: source, line: line)
                else
                  expanded = specifiers(setting, state, source, line)
                  expanded ? state[:environment][name] = expanded : state[:environment].delete(name)
                end
              end
            end
          when "EnvironmentFile"
            value.empty? ? environment_files.clear : environment_files.concat(
              words(value, state, source, line).map { |file| [ file, source, line ] }
            )
          when "WorkingDirectory"
            state[:cwd] = @project_root
            state[:cwd_provenance] = :inherited
            unless value.empty?
              directory = words(value, state, source, line).first
              directory = specifiers(directory, state, source, line) if directory
              if directory&.start_with?("/")
                state[:cwd] = directory
                state[:cwd_provenance] = :declared
              else
                reason(state, :working_directory_unresolved, path: source, line: line)
              end
            end
          when "PassEnvironment"
            passed = words(value, state, source, line)
            if !(passed & @keys).empty?
              reason(state, :inherited_environment_unresolved, path: source, line: line)
            end
          when "UnsetEnvironment"
            value.empty? ? unset.clear : unset.concat(words(value, state, source, line))
          when "ExecStart"
            value.empty? ? execs.clear : execs << [ value, source, line ]
          when "RootDirectory", "RootImage", "PAMName"
            reason(state, :unsupported_service_directive, path: source, line: line) unless value.empty?
          end
        end
        # systemd applies EnvironmentFile after all Environment assignments,
        # including Environment assignments in later drop-ins.
        environment_files.each { |file, source, line| read_environment_file(file, state, source, line) }
        unset.each do |assignment|
          name, separator, value = assignment.partition("=")
          state[:environment].delete(name) if separator.empty? || state[:environment][name] == value
        end
        if execs.length == 1
          value, source, line = execs.first
          inspect_launcher(words(value, state, source, line), state, source, line)
        else
          reason(state, :service_launcher_unresolved, path: path)
        end
      end

      def service_entries(content, path, state)
        entries = []
        section = nil
        continued = +""
        start = nil
        content.each_line.with_index(1) do |raw, number|
          line = raw.strip
          next if line.empty? || line.start_with?("#", ";")
          start ||= number
          if line.end_with?("\\")
            continued << line[0...-1] << " "
            next
          end
          line = continued + line
          continued = +""
          if line.match?(/\A\[[^\]]+\]\z/)
            section = line
          elsif section == "[Service]"
            key, separator, value = line.partition("=")
            separator.empty? ? reason(state, :malformed_service_directive, path: path, line: start) :
              entries << [ key.strip, value.strip, path, start ]
          end
          start = nil
        end
        reason(state, :malformed_service_directive, path: path, line: start) unless continued.empty?
        entries
      end

      def systemd_dropins(definition, metadata)
        # Same filename in a higher precedence directory masks the lower one.
        selected = {}
        prefixes = definition.service_name.enum_for(:scan, /-/).map { Regexp.last_match.end(0) }
        directories = [ "service.d" ] + prefixes.map { |length| "#{definition.service_name[0, length]}.service.d" } +
          [ "#{definition.service_name}.service.d" ]
        directories.each do |directory|
          @systemd_roots.each do |root|
            Dir.glob(File.join(root, directory, "*.conf")).each { |path| selected[File.basename(path)] = path }
          end
        end
        Array(metadata[:dropins]).each { |path| selected[File.basename(path)] = path }
        selected.sort.map(&:last)
      end

      def read_environment_file(file, state, source, line)
        optional = file.start_with?("-")
        file = file.delete_prefix("-")
        path = specifiers(file, state, source, line)
        unless path&.start_with?("/")
          reason(state, :environment_file_unresolved, path: source, line: line)
          return
        end
        paths = Dir.glob(path).sort
        paths = [ path ] if paths.empty?
        paths.each do |candidate|
          content, = read_source(candidate, state, optional: optional)
          next unless content
          environment_assignments(content, state, candidate).each do |name, value|
            state[:environment][name] = value if @keys.include?(name)
          end
        end
      end

      def environment_assignments(content, state, path)
        result = {}
        lines = content.lines
        index = 0
        while index < lines.length
          number = index + 1
          raw = lines[index].strip
          index += 1
          next if raw.empty? || raw.start_with?("#", ";")
          name, separator, value = raw.partition("=")
          next if separator.empty? || !@keys.include?(name.strip)
          value = value.lstrip
          quote = value.start_with?("'", '"') ? value[0] : nil
          complete = -> { quote ? value.match?(quote == "'" ? /\A'[^']*'\s*\z/m : /\A"(?:\\.|[^"\\])*"\s*\z/m) : !value.end_with?("\\") }
          until complete.call || index >= lines.length
            value << "\n" << lines[index].chomp
            index += 1
          end
          unless complete.call
            reason(state, :malformed_environment_file, path: path, line: number)
            next
          end
          parsed = if quote == "'"
            value.strip[1...-1]
          elsif quote == '"'
            value.strip[1...-1].gsub(/\\\n/, "").gsub(/\\([\\"$`])/, '\\1')
          else
            value.gsub(/\\\n/, "").gsub(/\\(.)/m, '\\1').strip
          end
          result[name.strip] = parsed
        end
        result
      end

      def read_launchd(content, path, state)
        document = REXML::Document.new(content)
        root = document.elements["plist/dict"]
        raise REXML::ParseException, "missing root dictionary" unless root
        fields = plist_dictionary(root)
        if (environment = fields["EnvironmentVariables"])
          unless environment.name == "dict"
            reason(state, :malformed_plist_environment, path: path)
            return
          end
          plist_dictionary(environment).each do |name, value|
            next unless @keys.include?(name)
            if value.name == "string"
              state[:environment][name] = value.text.to_s
            else
              reason(state, :malformed_plist_environment, path: path)
            end
          end
        end
        if (directory = fields["WorkingDirectory"])
          if directory.name == "string" && directory.text.to_s.start_with?("/")
            state[:cwd] = directory.text.to_s
            state[:cwd_provenance] = :declared
          else
            reason(state, :working_directory_unresolved, path: path)
          end
        end
        args = fields["ProgramArguments"]
        if args&.name == "array" && args.elements.to_a.all? { |element| element.name == "string" }
          inspect_launcher(args.elements.to_a.map { |element| element.text.to_s }, state, path, nil)
        elsif fields["Program"]&.name == "string"
          inspect_launcher([ fields["Program"].text.to_s ], state, path, nil)
        else
          reason(state, :service_launcher_unresolved, path: path)
        end
      rescue REXML::ParseException, ArgumentError
        reason(state, :malformed_plist, path: path)
      end

      def plist_dictionary(element)
        children = element.elements.to_a
        raise ArgumentError, "invalid plist dictionary" unless children.length.even?
        children.each_slice(2).to_h do |key, value|
          raise ArgumentError, "invalid plist key" unless key.name == "key"
          [ key.text.to_s, value ]
        end
      end

      def inspect_launcher(args, state, path, line)
        if args.first == "/bin/sh" && args[1] == "-c" && args[2] == PRECHECK && args[3]
          args = args.drop(3)
        end
        executable = args.first.to_s.sub(/\A[-+!:@]+/, "")
        if executable.empty? || %w[sh bash zsh fish env].include?(File.basename(executable))
          reason(state, :opaque_service_wrapper, path: path, line: line)
          return
        end
        executable = specifiers(executable, state, path, line)
        return unless executable && File.file?(executable)
        prefix = File.read(executable, 8192)
        return unless prefix.match?(/\A#![^\n]*\b(?:sh|bash|zsh|fish)\b/)
        # The packaged Hive launcher changes GEM_HOME/GEM_PATH only. Arbitrary
        # shell launchers may activate managers or rewrite PATH and stay opaque.
        managed = prefix.lines.drop(1).reject { |entry| entry.strip.empty? || entry.start_with?("#") }.all? do |entry|
          entry.match?(/\Aexport (?:GEM_HOME|GEM_PATH|HIVE_INVOKED_BIN)=/) ||
            entry.match?(/\Aexec "[^"$`]+" "\$@"\s*\z/)
        end
        reason(state, :opaque_service_wrapper, path: executable, line: 1) unless managed
      rescue SystemCallError, IOError, ArgumentError
        reason(state, :service_launcher_unreadable, path: executable, line: line)
      end

      def words(value, state, path, line)
        Shellwords.split(value)
      rescue ArgumentError
        reason(state, :malformed_quoted_value, path: path, line: line)
        []
      end

      def specifiers(value, state, path, line)
        return if value.nil?
        if value.gsub(/%%|%h/, "").include?("%")
          reason(state, :unsupported_specifier, path: path, line: line)
          return
        end
        value.gsub(/%%|%h/) { |match| match == "%h" ? @home : "%" }
      end

      def running_currency(status, state, definition)
        return :unknown unless status&.manager_available?
        return :stopped if status.stopped?
        return :unknown unless status.running?
        if definition.platform == :linux
          return :stale if status.need_daemon_reload == true
          return :unknown unless status.fragment_path && !status.need_daemon_reload.nil?
          return :stale unless status.loaded_definition_current?
        end
        return :unknown unless status.process_identity
        return :unknown if status.process_start == "0"
        started = process_start_wall(status.process_start, definition.platform)
        return :unknown unless started && !state[:sources].empty?
        state[:sources].any? { |source| source.fetch(:mtime) > started } ? :stale : :current
      end

      def process_start_wall(value, platform)
        if platform == :linux && value.to_s.match?(/\A\d+\z/)
          @wall_clock.call.to_f - @monotonic.call + value.to_i / 1_000_000.0
        else
          Time.parse(value.to_s).to_f
        end
      rescue ArgumentError
        nil
      end

      def offline_fragment(definition)
        return definition.target_path unless definition.platform == :linux
        return definition.target_path if File.exist?(definition.target_path) || File.symlink?(definition.target_path)
        @systemd_roots.reverse_each do |root|
          candidate = File.join(root, "#{definition.service_name}.service")
          return candidate if File.exist?(candidate) || File.symlink?(candidate)
        end
        definition.target_path
      end

      def profile_executable_identities
        environments = [ ENV.to_h ]
        # Inspect installed selection inputs before any manager helper can launch:
        # a profile's override may itself name systemctl or launchctl.
        definitions.each_value do |definition|
          next if definition.platform == :unsupported
          state = { environment: { "HOME" => @home }, cwd: @project_root,
                    cwd_provenance: :inherited, reasons: [], sources: [] }
          path = offline_fragment(definition)
          content, = read_source(path, state)
          next unless content
          if definition.platform == :linux
            read_systemd(content, path, state, definition, {})
          else
            read_launchd(content, path, state)
          end
          environments << state[:environment]
        end
        paths = @excluded_executables + environments.flat_map do |environment|
          @profiles.filter_map do |profile|
            runtime = profile.respond_to?(:runtime_profile) ? profile.runtime_profile : profile
            next unless runtime.respond_to?(:bin)
            AgentCliIdentity.resolve(runtime.bin(env: environment), environment: environment, cwd: @project_root)
          end
        end
        paths.filter_map { |path| file_identity(path) }.uniq
      end

      def file_identity(path)
        stat = File.stat(path)
        [ stat.dev, stat.ino ]
      rescue SystemCallError
        nil
      end

      def inherited_environment
        return { environment: {} } unless %i[linux macos].include?(@platform)
        explicit = @explicit_manager_environment
        return { environment: explicit.slice(*@keys) } if explicit
        return { environment: {} } if @status_reader
        argv = @platform == :linux ? %w[systemctl --user show-environment] :
          [ "launchctl", "print", "gui/#{Process.uid}" ]
        result = manager_query(argv)
        return { environment: {}, reasons: [ result[:failure] || :manager_environment_unavailable ] } unless result[:ok]
        if @platform == :linux
          environment = result[:output].to_s.each_line.each_with_object({}) do |line, found|
            next unless @keys.include?(line.split("=", 2).first)
            assignments = Shellwords.split(line)
            raise ArgumentError unless assignments.length == 1
            key, value = assignments.first.split("=", 2)
            found[key] = value.to_s
          end
        else
          block = result[:output].to_s[/^\s*environment = \{\n(.*?)^\s*\}/m, 1]
          return { environment: {}, reasons: [ :manager_environment_unresolved ] } unless block
          environment = block.each_line.each_with_object({}) do |line, found|
            key, separator, value = line.strip.partition(" => ")
            next unless @keys.include?(key)
            raise ArgumentError if separator.empty? || value.start_with?('"', "'")
            found[key] = value
          end
        end
        { environment: environment }
      rescue ArgumentError
        { environment: {}, reasons: [ :manager_environment_unresolved ] }
      end

      def manager_metadata(definition)
        # Injected Status already supplies currency; avoid unrelated host queries.
        return {} if @status_reader
        argv = if definition.platform == :linux
          [ "systemctl", "--user", "show", "--no-pager",
            "--property=LoadState,FragmentPath,DropInPaths,NeedDaemonReload,ActiveState,MainPID,ExecMainStartTimestampMonotonic",
            definition.service_name ]
        else
          [ "launchctl", "print", "gui/#{Process.uid}/#{definition.launchd_label}" ]
        end
        result = manager_query(argv)
        return { reasons: [ result[:failure] || :manager_unavailable ] } unless result[:ok]
        if definition.platform == :linux
          properties = result[:output].each_line.to_h { |line| line.chomp.split("=", 2).values_at(0, 1) }
          fragment = properties["FragmentPath"]
          fragment = nil if fragment.to_s.empty?
          running = properties["ActiveState"] == "active"
          status = build_status(definition, running: running, fragment_path: fragment,
            load_state: properties["LoadState"], need_daemon_reload: boolean(properties["NeedDaemonReload"]),
            main_pid: properties["MainPID"], process_start: properties["ExecMainStartTimestampMonotonic"])
          { fragment_path: fragment, dropins: Shellwords.split(properties["DropInPaths"].to_s), status: status }
        else
          running = result[:output].match?(/\bstate\s*=\s*running\b/)
          pid = result[:output][/\bpid\s*=\s*(\d+)/, 1]
          { status: build_status(definition, running: running, main_pid: pid) }
        end
      rescue ArgumentError
        {}
      end

      def build_status(definition, **values)
        Status.new(platform: definition.platform, unit_path: definition.target_path,
          content_state: File.exist?(definition.target_path) ? :matching : :absent,
          file_identity: nil, manager_availability: :available, enabled: false, **values)
      end

      def boolean(value)
        return true if value == "yes"
        return false if value == "no"
        nil
      end

      def manager_query(argv)
        timeout = [ MANAGER_CALL_SECONDS, @manager_deadline - @monotonic.call ].min
        return { ok: false, failure: :manager_budget_exhausted } if timeout <= CLEANUP_SECONDS
        helper = AgentCliIdentity.resolve(argv.first, environment: ENV.to_h, cwd: @project_root)
        if helper && @excluded_identities.include?(file_identity(helper))
          return { ok: false, failure: :manager_agent_identity_collision }
        end
        return @manager_runner.call(argv, timeout: timeout).transform_keys(&:to_sym) if @manager_runner
        capture_manager(argv, timeout)
      rescue StandardError
        { ok: false, failure: :manager_unavailable }
      end

      def capture_manager(argv, timeout)
        reader, writer = IO.pipe
        pid = Process.spawn(*argv, in: File::NULL, out: writer, err: writer, pgroup: true)
        writer.close
        output = +""
        deadline = @monotonic.call + timeout - CLEANUP_SECONDS
        loop do
          return { ok: false, failure: :manager_output_limit } unless drain_manager(reader, output)
          if (waited = Process.wait2(pid, Process::WNOHANG))
            return { ok: false, failure: :manager_output_limit } unless drain_manager(reader, output)
            return { ok: waited.last.success?, output: output }
          end
          return { ok: false, failure: :manager_timeout } if @monotonic.call >= deadline
          IO.select([ reader ], nil, nil, 0.01)
        end
      ensure
        writer&.close unless writer&.closed?
        reader&.close unless reader&.closed?
        if pid
          begin
            Process.kill("KILL", -pid)
          rescue Errno::ESRCH
            nil
          end
          begin
            Process.waitpid(pid)
          rescue Errno::ECHILD
            nil
          end
        end
      end

      def drain_manager(reader, output)
        (MAX_CAPTURE_BYTES / 4096 + 1).times do
          chunk = reader.read_nonblock(4096, exception: false)
          break if chunk.nil? || chunk == :wait_readable
          return false if output.bytesize + chunk.bytesize > MAX_CAPTURE_BYTES
          output << chunk
        end
        true
      end

      def reason(state, code, path: nil, line: nil)
        state[:reasons] << { code: code, path: path && redact(path).freeze, line: line }.compact.freeze
      end

      def redact(value) = Hive::SecretPatterns.redact(value)
    end
  end
end
