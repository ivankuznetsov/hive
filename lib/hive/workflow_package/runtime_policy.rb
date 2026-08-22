require "fileutils"
require "forwardable"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "hive/atomic_file"
require "hive/agent_profiles"
require "hive/agent_support"
require "hive/permission_scope"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/input_name"

module Hive
  module WorkflowPackage
    class RuntimePolicy
      REQUIRED_CAPABILITIES = %i[
        tools directories commands domains settings_isolation mcp_isolation environment_isolation
      ].freeze
      SUPPORTED_TOOLS = %w[
        Read LS Grep Glob Write Edit MultiEdit NotebookEdit Bash WebFetch
      ].freeze
      ALWAYS_DENIED_TOOLS = %w[WebSearch Task Skill EnterPlanMode ExitPlanMode AskUserQuestion].freeze
      SAFE_ENV_KEYS = %w[HOME LANG LC_ALL TMPDIR].freeze
      COMMAND_META = /[|<>&`\n\r]|\$\(|\$\{|\*\*(?!\z)/
      DOMAIN = /\A(?:\*\.)?[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/i
      PORTABLE_FILE_TOOLS = Hive::PermissionScope::READ_ONLY_ALLOWED
      PORTABLE_NETWORK_TOOLS = %w[WebFetch WebSearch].freeze
      PORTABLE_HOST_OUTPUT_TOOLS = Hive::PermissionScope::FILE_EDIT_TOOLS
      PORTABLE_SUPPORTED_TOOLS = (
        PORTABLE_FILE_TOOLS + PORTABLE_NETWORK_TOOLS + PORTABLE_HOST_OUTPUT_TOOLS
      ).freeze

      Policy = Data.define(
        :permission_mode, :allowed_tools, :disallowed_tools, :directories,
        :commands, :domains, :executables, :environment,
        :settings_path, :mcp_config_path, :policy_path, :cli_flags,
        :permission_flags, :agent_add_dirs, :command_prefix, :executable,
        :task_root, :output_paths, :cleanup_paths
      ) do
        def host_outputs?
          !output_paths.empty?
        end

        def decorate_prompt(prompt)
          return prompt unless host_outputs?

          names = output_paths.keys.map { |name| "- `#{name}`" }.join("\n")
          <<~PROMPT
            #{prompt}

            ## Hive managed output contract

            This runner is read-only. Do not create or edit task files with tools.
            Return one JSON object matching the supplied output schema. Its `files`
            object must contain the complete final contents for exactly these paths:

            #{names}

            Preserve every format and terminal-marker requirement from the stage
            instructions inside each file value. Do not wrap the JSON in Markdown.
          PROMPT
        end

        def materialize_outputs!(result)
          return result unless host_outputs?
          if result[:final_message_truncated]
            raise Hive::ConfigError, "managed runner output was truncated before validation"
          end

          payload = parse_structured_output(result[:final_message].to_s)
          files = payload.is_a?(Hash) ? payload["files"] : nil
          unless files.is_a?(Hash) && files.keys.sort == output_paths.keys.sort
            raise Hive::ConfigError, "managed runner returned the wrong output file set"
          end

          contents = output_paths.map do |relative, target|
            content = files.fetch(relative)
            unless content.is_a?(String) && !content.empty?
              raise Hive::ConfigError, "managed runner returned an empty or non-string output"
            end
            self.class.ensure_confined_output!(task_root, target)
            [ target, content ]
          end

          snapshots = contents.to_h { |target, _content| [ target, output_snapshot(target) ] }
          published = []
          begin
            contents.each do |target, content|
              Hive::AtomicFile.write(target, content, mode: snapshots.fetch(target).fetch(:mode))
              published << target
            end
          rescue StandardError => error
            rollback_errors = rollback_outputs(published, snapshots)
            message = "managed output publication failed: #{error.class}: #{error.message}"
            unless rollback_errors.empty?
              message = "#{message}; rollback failed: #{rollback_errors.join('; ')}"
            end
            raise Hive::ConfigError, message
          end
          result
        rescue JSON::ParserError
          raise Hive::ConfigError, "managed runner returned invalid structured output"
        end

        def cleanup!
          cleanup_paths.each do |path|
            FileUtils.remove_entry_secure(path)
          rescue Errno::ENOENT
            nil
          end
        end

        private

        def parse_structured_output(message)
          JSON.parse(message)
        rescue JSON::ParserError => raw_error
          payloads = message.scan(/^```json[ \t]*\r?\n(.*?)^```[ \t]*$/m).filter_map do |body|
            JSON.parse(body.first)
          rescue JSON::ParserError
            nil
          end
          payloads.concat(trailing_json_payloads(message))
          raise raw_error unless payloads.one?

          payloads.first
        end

        def trailing_json_payloads(message)
          offset = 0
          message.each_line.filter_map do |line|
            stripped = line.lstrip
            candidate = if stripped.start_with?("{")
              start = offset + line.bytesize - stripped.bytesize
              JSON.parse(message.byteslice(start..))
            end
            offset += line.bytesize
            candidate
          rescue JSON::ParserError
            offset += line.bytesize
            nil
          end
        end

        def output_snapshot(target)
          stat = File.lstat(target)
          if stat.symlink?
            raise Hive::ConfigError, "managed output target cannot be a symlink"
          end

          {
            existed: true,
            content: File.binread(target),
            mode: stat.mode & 0o777
          }
        rescue Errno::ENOENT
          { existed: false, content: nil, mode: 0o644 }
        rescue SystemCallError => e
          raise Hive::ConfigError,
                "managed output target could not be snapshotted: #{e.class}: #{e.message}"
        end

        def rollback_outputs(published, snapshots)
          published.reverse_each.filter_map do |target|
            snapshot = snapshots.fetch(target)
            if snapshot.fetch(:existed)
              Hive::AtomicFile.write(
                target, snapshot.fetch(:content), mode: snapshot.fetch(:mode)
              )
            else
              FileUtils.rm_f(target)
              Hive::AtomicFile.fsync_directory(File.dirname(target))
            end
            nil
          rescue StandardError => e
            "#{target}: #{e.class}: #{e.message}"
          end
        end

        def self.ensure_confined_output!(root, target)
          expanded = File.expand_path(target)
          unless expanded.start_with?(root + File::SEPARATOR)
            raise Hive::ConfigError, "managed output escapes the task folder"
          end

          cursor = File.dirname(expanded)
          resolved = loop do
            break File.realpath(cursor)
          rescue Errno::ENOENT
            parent = File.dirname(cursor)
            raise if parent == cursor

            cursor = parent
          end
          unless resolved == root || resolved.start_with?(root + File::SEPARATOR)
            raise Hive::ConfigError, "managed output parent escapes the task folder"
          end
        rescue Errno::ENOENT, Errno::EACCES
          raise Hive::ConfigError, "managed output parent is unavailable"
        end
      end

      module ProviderHost
        extend SingleForwardable

        PORTABLE_NETWORK_TOOLS = RuntimePolicy::PORTABLE_NETWORK_TOOLS
        PORTABLE_HOST_OUTPUT_TOOLS = RuntimePolicy::PORTABLE_HOST_OUTPUT_TOOLS
        def_delegators RuntimePolicy, *%i[
          actor_environment capture3_bounded direct_policy find_executable output_schema
          policy portable_admission_policy portable_policy resolve_profile_executable
          sandbox_parent_dirs write_output_schema
        ]

        def self.compile_managed_actor(host:, scope:, task_root:, directories:,
                                       environment:, outputs:, prepare:, **)
          return portable_admission_policy(scope, task_root:, directories:, environment:) unless prepare

          portable_policy(
            scope, task_root:, directories:, environment:, outputs:,
            runtime_root: nil, cli_flags: [], executable: nil
          )
        end
      end

      def self.compile(permissions, task_folder:, profile:, policy_dir:)
        new(permissions, task_folder: task_folder, profile: profile, policy_dir: policy_dir).compile
      end

      # Builds an isolated child environment around one descriptor actor's
      # exact permission block. Unlike #compile, this does not reconstruct a
      # policy from the package-wide catalog disclosure.
      def self.compile_actor(permission_spec, task_folder:, profile:, package_root:, environment: {},
                             base_add_dirs: [], managed_outputs: [], prepare: true)
        task_root = File.realpath(task_folder)
        package_root = File.realpath(package_root)
        support = Hive::AgentSupport.for(profile)
        runtime = support::Runtime if support&.const_defined?(:Runtime, false)
        scope, parsed = if runtime&.respond_to?(:resolve_scope)
          runtime.resolve_scope(permission_spec, task_root:, profile:)
        else
          Hive::PermissionScope.resolve_managed_spec(
            permission_spec, task_folder: task_root, stage: "managed-workflow"
          )
        end
        directories = ([ task_root, package_root ] + scope.add_dirs_extra).uniq
        # Yolo is already the explicit unbounded trust preset. Preserve the
        # caller's declared project/worktree roots as runner context so agents
        # such as Codex do not mistake an authorized target for an out-of-scope
        # workspace. Bounded actors receive only roots declared by their own
        # permission spec through scope.add_dirs_extra.
        if scope.yolo?
          directories = (directories + trusted_actor_read_roots(base_add_dirs)).uniq
        end
        child_environment = actor_environment(environment)
        if runtime&.respond_to?(:compile_direct_actor)
          return runtime.compile_direct_actor(
            host: ProviderHost, scope:, task_root:, directories:, profile:,
            environment: child_environment, managed_outputs:, prepare:
          )
        end
        unless scope.yolo?
          return compile_portable_actor(
            parsed, scope: scope, task_root: task_root,
            directories: directories, profile: profile, environment: child_environment,
            managed_outputs: managed_outputs, prepare: prepare
          )
        end
        direct_policy(scope, task_root:, directories:, environment: child_environment)
      rescue Errno::ENOENT, Errno::EACCES => e
        raise Hive::ConfigError, "managed runtime package context is unavailable (#{e.class.name.split('::').last})"
      end

      def self.direct_policy(scope, task_root:, directories:, environment:)
        Policy.new(
          permission_mode: scope.permission_mode,
          allowed_tools: scope.allowed_tools,
          disallowed_tools: scope.disallowed_tools,
          directories: directories.freeze,
          commands: [].freeze,
          domains: [].freeze,
          executables: {}.freeze,
          environment: environment.freeze,
          settings_path: nil,
          mcp_config_path: nil,
          policy_path: nil,
          cli_flags: [].freeze,
          permission_flags: nil,
          agent_add_dirs: directories.freeze,
          command_prefix: [].freeze,
          executable: nil,
          task_root: task_root.freeze,
          output_paths: {}.freeze,
          cleanup_paths: [].freeze
        ).freeze
      end

      def self.actor_environment(environment)
        child_environment = SAFE_ENV_KEYS.each_with_object({}) do |key, out|
          value = ENV[key]
          out[key] = value if value && !value.empty?
        end
        child_environment["PATH"] = ENV.fetch("PATH", "/usr/local/bin:/usr/bin:/bin")
        child_environment["HIVE_MANAGED_POLICY"] = "1"
        environment.each do |key, value|
          name = key.to_s
          unless InputName.valid?(name) && value.is_a?(String)
            raise Hive::ConfigError, "managed workflow input environment is malformed"
          end
          child_environment[name] = value
        end
        child_environment.freeze
      end

      def self.trusted_actor_read_roots(base_add_dirs)
        unless base_add_dirs.is_a?(Array)
          raise Hive::ConfigError, "managed actor trusted read roots must be an array"
        end

        base_add_dirs.map do |entry|
          unless entry.is_a?(String) && !entry.empty? && !entry.include?("\0")
            raise Hive::ConfigError, "managed actor trusted read root is malformed"
          end

          resolved = File.realpath(entry)
          unless File.directory?(resolved)
            raise Hive::ConfigError, "managed actor trusted read root is not a directory"
          end
          resolved
        rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR
          raise Hive::ConfigError, "managed actor trusted read root is unavailable"
        end
      end

      def self.compile_portable_actor(parsed_spec, scope:, task_root:, directories:,
                                      profile:, environment:, managed_outputs:, prepare:)
        support = Hive::AgentSupport.for(profile)
        runtime = support::Runtime if support&.const_defined?(:Runtime, false)
        compiler = runtime
        compiler ||= ProviderHost if support&.const_defined?(:PORTABLE_MANAGED_RUNTIME, false)
        unless compiler
          raise Hive::ConfigError,
                "runner #{profile.name.inspect} cannot enforce managed workflow policy"
        end

        tool_names = Array(scope.allowed_tools).flat_map do |rule|
          Hive::PermissionScope.granted_tool_names(rule)
        end.uniq
        unsupported = tool_names - PORTABLE_SUPPORTED_TOOLS
        unless unsupported.empty?
          raise Hive::ConfigError,
                "runner #{profile.name.inspect} cannot enforce managed tools #{unsupported.sort.inspect}"
        end
        path_read_rules = Array(parsed_spec["tools"]).filter_map do |rule|
          match = Hive::PermissionScope::TOOL_RULE_PATTERN.match(rule.to_s.strip)
          rule if match && match[:tool] == "Read" && match[:specifier]
        end
        supports_qualified_reads = runtime&.const_defined?(:PATH_QUALIFIED_READS, false)
        if path_read_rules.any? && !supports_qualified_reads
          raise Hive::ConfigError,
                "runner #{profile.name.inspect} cannot enforce path-qualified Read rules " \
                "#{path_read_rules.inspect}"
        end

        outputs = portable_outputs(
          parsed_spec, task_root: task_root, requested: managed_outputs
        )
        runtime_root = prepare && !outputs.empty? ? Dir.mktmpdir("hive-managed-actor-") : nil
        compiler.compile_managed_actor(
          host: ProviderHost, scope:, task_root:, directories:, profile:, environment:,
          outputs:, runtime_root:, tool_names:, prepare:
        )
      rescue StandardError
        begin
          FileUtils.remove_entry_secure(runtime_root) if runtime_root
        rescue Errno::ENOENT
          nil
        end
        raise
      end

      def self.portable_admission_policy(scope, task_root:, directories:, environment:)
        portable_policy(
          scope, task_root: task_root, directories: directories, environment: environment,
          outputs: {}, runtime_root: nil, cli_flags: [], executable: nil
        )
      end

      def self.write_output_schema(path, names)
        Hive::AtomicFile.write(path, CanonicalJSON.generate(output_schema(names)), mode: 0o600)
      end

      def self.portable_policy(scope, task_root:, directories:, environment:, outputs:, runtime_root:,
                               cli_flags:, executable:, command_prefix: [])
        Policy.new(
          permission_mode: nil,
          allowed_tools: scope.allowed_tools,
          disallowed_tools: scope.disallowed_tools,
          directories: directories.freeze,
          commands: [].freeze,
          domains: [].freeze,
          executables: {}.freeze,
          environment: environment,
          settings_path: nil,
          mcp_config_path: nil,
          policy_path: nil,
          cli_flags: cli_flags.freeze,
          permission_flags: [].freeze,
          agent_add_dirs: [].freeze,
          command_prefix: command_prefix.freeze,
          executable: executable.freeze,
          task_root: task_root.freeze,
          output_paths: outputs.freeze,
          cleanup_paths: Array(runtime_root).compact.freeze
        ).freeze
      end

      def self.policy(**attributes) = Policy.new(**attributes).freeze

      def self.portable_outputs(parsed_spec, task_root:, requested:)
        patterns = Array(parsed_spec["tools"]).filter_map do |rule|
          match = Hive::PermissionScope::TOOL_RULE_PATTERN.match(rule.to_s.strip)
          next unless match && PORTABLE_HOST_OUTPUT_TOOLS.include?(match[:tool])
          unless match[:tool] == "Edit" && match[:specifier]
            raise Hive::ConfigError,
                  "portable managed output requires path-qualified Edit rules"
          end

          raw = match[:specifier]
          File.absolute_path?(raw) ? File.expand_path(raw) : File.expand_path(raw, task_root)
        end
        exact = patterns.reject { |path| path.include?("*") }
        commit_targets = Array(requested).map { |path| File.expand_path(path, task_root) }.uniq
        candidates = (exact + commit_targets).uniq
        candidates.each do |target|
          Policy.ensure_confined_output!(task_root, target)
          unless patterns.any? { |pattern| portable_path_match?(pattern, target) }
            raise Hive::ConfigError,
                  "managed output #{target.inspect} is not authorized by an Edit rule"
          end
        end
        candidates.sort_by { |target| [ commit_targets.include?(target) ? 1 : 0, target ] }.to_h do |target|
          [ target.delete_prefix(task_root + File::SEPARATOR), target ]
        end
      end

      def self.portable_path_match?(pattern, target)
        if pattern.end_with?("/**")
          root = pattern.delete_suffix("/**")
          target.start_with?(root + File::SEPARATOR)
        else
          File.fnmatch?(pattern, target, File::FNM_PATHNAME | File::FNM_EXTGLOB)
        end
      end

      def self.output_schema(paths)
        properties = paths.sort.to_h { |path| [ path, { "type" => "string" } ] }
        {
          "type" => "object",
          "properties" => {
            "files" => {
              "type" => "object",
              "properties" => properties,
              "required" => paths.sort,
              "additionalProperties" => false
            }
          },
          "required" => [ "files" ],
          "additionalProperties" => false
        }
      end

      def self.resolve_profile_executable(profile)
        find_executable(profile.bin) ||
          raise(Hive::ConfigError, "runner #{profile.name.inspect} executable is unavailable")
      end

      def self.capture3_bounded(*argv, timeout_sec:, environment: {})
        stdin, stdout, stderr, waiter = Open3.popen3(environment, *argv, pgroup: true)
        stdin.close
        out_reader = Thread.new { stdout.read }
        err_reader = Thread.new { stderr.read }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_sec
        completed = waiter.join(timeout_sec)
        completed &&= [ out_reader, err_reader ].all? do |reader|
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          remaining.positive? && reader.join(remaining)
        end
        unless completed
          terminate_capture_process_group(waiter)
          raise Timeout::Error
        end
        [ out_reader.value, err_reader.value, waiter.value ]
      ensure
        [ stdin, stdout, stderr ].each do |io|
          io.close if io && !io.closed?
        rescue IOError
          nil
        end
        [ out_reader, err_reader ].each do |reader|
          reader&.join(0.2)
        rescue IOError
          # A bounded timeout closes the capture streams while their reader
          # threads unwind. Preserve the primary Timeout::Error.
          nil
        end
      end

      def self.terminate_capture_process_group(waiter)
        Process.kill("TERM", -waiter.pid)
        return if waiter.join(0.2)

        Process.kill("KILL", -waiter.pid)
        waiter.join(0.2)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def self.find_executable(name)
        return File.realpath(name) if name.include?(File::SEPARATOR) &&
                                      File.file?(name) && File.executable?(name)

        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
          next if directory.empty?

          candidate = File.join(directory, name)
          return File.realpath(candidate) if File.file?(candidate) && File.executable?(candidate)
        rescue Errno::ENOENT, Errno::EACCES
          next
        end
        nil
      end

      def self.grok_bwrap_prefix(executable:, auth_path:, runtime_home:, directories:, cwd:)
        paths = directories + [ cwd ]
        parent_dirs = paths.flat_map do |path|
          parents = []
          cursor = File.dirname(path)
          while cursor != File.dirname(cursor)
            parents << cursor
            cursor = File.dirname(cursor)
          end
          parents
        end.uniq.reject do |path|
          %w[/tmp /usr /usr/local /usr/local/bin /etc /proc /dev /auth /runtime-home].include?(path)
        end.sort_by { |path| [ path.count(File::SEPARATOR), path ] }

        prefix = [
          GROK_SANDBOX_PATH,
          "--die-with-parent", "--new-session", "--unshare-all", "--share-net",
          "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
          "--dir", "/usr", "--dir", "/usr/local", "--dir", "/usr/local/bin",
          "--ro-bind", executable, "/usr/local/bin/grok",
          "--dir", "/etc", "--ro-bind", "/etc/ssl", "/etc/ssl",
          "--ro-bind", "/etc/resolv.conf", "/etc/resolv.conf",
          "--ro-bind", "/etc/hosts", "/etc/hosts",
          "--dir", "/auth", "--ro-bind", auth_path, "/auth/auth.json",
          "--bind", runtime_home, "/runtime-home"
        ]
        parent_dirs.each { |path| prefix.concat([ "--dir", path ]) }
        directories.uniq.each { |path| prefix.concat([ "--ro-bind", path, path ]) }
        prefix.concat([
          "--setenv", "HOME", "/runtime-home",
          "--setenv", "GROK_HOME", "/runtime-home/.grok",
          "--setenv", "GROK_AUTH_PATH", "/auth/auth.json",
          "--setenv", "PATH", "/usr/local/bin",
          "--chdir", cwd,
          "--"
        ])
      end

      def self.pi_bwrap_prefix(executable:, auth_path:, runtime_home:, directories:, cwd:,
                               readonly_mounts: {}, writable_directories: [])
        parent_dirs = sandbox_parent_dirs(
          directories + [ cwd ] + writable_directories + readonly_mounts.values
        )
        runtime_mount = PI_RUNTIME_MOUNT
        prefix = [
          PI_SANDBOX_PATH,
          "--die-with-parent", "--new-session", "--unshare-all", "--share-net",
          "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
          "--ro-bind", "/usr", "/usr",
          "--symlink", "usr/bin", "/bin", "--symlink", "usr/bin", "/sbin",
          "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib", "/lib64",
          "--ro-bind", File.dirname(executable), runtime_mount,
          "--dir", "/etc", "--ro-bind", "/etc/ssl", "/etc/ssl",
          "--ro-bind", "/etc/resolv.conf", "/etc/resolv.conf",
          "--ro-bind", "/etc/hosts", "/etc/hosts",
          "--bind", runtime_home, "/runtime-home",
          "--ro-bind", auth_path, "/runtime-home/.pi/agent/auth.json"
        ]
        models_path = File.join(File.dirname(auth_path), "models.json")
        if File.file?(models_path)
          prefix.concat(
            [ "--ro-bind", File.realpath(models_path), "/runtime-home/.pi/agent/models.json" ]
          )
        end
        parent_dirs.each { |path| prefix.concat([ "--dir", path ]) }
        directories.uniq.each { |path| prefix.concat([ "--ro-bind", path, path ]) }
        readonly_mounts.each do |host, guest|
          prefix.concat([ "--dir", guest, "--ro-bind", host, guest ])
        end
        writable_directories.uniq.each do |path|
          prefix.concat([ "--bind", path, path ])
        end
        prefix.concat([
          "--setenv", "HOME", "/runtime-home",
          "--setenv", "PI_CODING_AGENT_DIR", "/runtime-home/.pi/agent",
          "--setenv", "PATH", "#{runtime_mount}:/usr/bin",
          "--chdir", cwd,
          "--"
        ])
      end

      def self.pi_evidence_extension(source_root:, task_root:, writable_root:,
                                     task_relative_write_root:, hive_executable:, browser:)
        browser_tool = if browser
          <<~TYPESCRIPT
            pi.registerTool(defineTool({
              name: "evidence_browser",
              label: "Capture browser evidence",
              description: "Run one controller-admitted browser capture action. Pass the complete action argv, beginning with open, snapshot, click, fill, wait, screenshot, or record.",
              parameters: Type.Object({
                argv: Type.Array(Type.String({ minLength: 1, maxLength: 4096 }), {
                  minItems: 1, maxItems: 64
                })
              }),
              async execute(_id, params, signal) {
                return runHive(["evidence", "browser", ...params.argv], signal);
              }
            }));

            pi.registerTool(defineTool({
              name: "evidence_server",
              label: "Start project evidence server",
              description: "Start one repository application command on the controller-issued evidence port and keep it under Hive custody for this attempt.",
              parameters: Type.Object({
                argv: Type.Array(Type.String({ minLength: 1, maxLength: 4096 }), {
                  minItems: 1, maxItems: 64
                })
              }),
              async execute(_id, params, signal) {
                const [executable, ...argv] = params.argv;
                return runHive(["evidence", "server", executable, "--json", "--", ...argv], signal);
              }
            }));
          TYPESCRIPT
        else
          ""
        end

        <<~TYPESCRIPT
          import { Type } from "@earendil-works/pi-ai";
          import {
            createFindTool, createGrepTool, createLsTool, createReadTool,
            defineTool, type ExtensionAPI
          } from "@earendil-works/pi-coding-agent";
          import { realpathSync, writeFileSync } from "node:fs";
          import { isAbsolute, relative, resolve, sep } from "node:path";

          const roots = #{JSON.generate([ source_root, task_root ])};
          const writeRoot = #{JSON.generate(writable_root)};
          const taskRelativeWriteRoot = #{JSON.generate(task_relative_write_root)};
          const hiveExecutable = #{JSON.generate(hive_executable)};

          function confinedPath(raw: unknown): string {
            const candidate = realpathSync(resolve(process.cwd(), typeof raw === "string" ? raw : "."));
            if (!roots.some((root) => candidate === root || candidate.startsWith(root + sep))) {
              throw new Error("read path escapes the frozen source and task roots");
            }
            return candidate;
          }

          function scopedReadTool(tool: any) {
            return {
              ...tool,
              async execute(id: string, params: any, signal: AbortSignal, onUpdate: any, ctx: any) {
                confinedPath(params.path);
                return tool.execute(id, params, signal, onUpdate, ctx);
              }
            };
          }

          function toolText(text: string, details: any = {}) {
            return { content: [{ type: "text" as const, text }], details };
          }

          export default function (pi: ExtensionAPI) {
            const cwd = process.cwd();
            pi.registerTool(scopedReadTool(createReadTool(cwd)));
            pi.registerTool(scopedReadTool(createLsTool(cwd)));
            pi.registerTool(scopedReadTool(createGrepTool(cwd)));
            pi.registerTool(scopedReadTool(createFindTool(cwd)));

            async function runHive(argv: string[], signal: AbortSignal) {
              const result = await pi.exec("/usr/bin/ruby", [hiveExecutable, ...argv], {
                signal, timeout: 70000
              });
              const text = [result.stdout, result.stderr].filter(Boolean).join("\\n").slice(0, 524288);
              if (result.code !== 0) throw new Error(text || `Hive evidence command failed (${result.code})`);
              return toolText(text, { status: result.code });
            }

            pi.registerTool(defineTool({
              name: "evidence_write",
              label: "Write evidence document",
              description: "Write one text, Markdown, or JSON representation under the controller-owned evidence root.",
              parameters: Type.Object({
                name: Type.String({ pattern: "^[a-z][a-z0-9_-]{0,63}\\\\.(txt|md|json)$" }),
                content: Type.String({ minLength: 1, maxLength: 4194304 })
              }),
              async execute(_id, params) {
                if (!/^[a-z][a-z0-9_-]{0,63}\\.(txt|md|json)$/.test(params.name)) {
                  throw new Error("evidence filename is invalid");
                }
                const destination = resolve(writeRoot, params.name);
                if (relative(writeRoot, destination).startsWith("..") || isAbsolute(relative(writeRoot, destination))) {
                  throw new Error("evidence filename escapes the attempt root");
                }
                if (Buffer.byteLength(params.content, "utf8") > 4194304) {
                  throw new Error("evidence document is oversized");
                }
                writeFileSync(destination, params.content, { encoding: "utf8", flag: "wx", mode: 0o600 });
                const mediaType = params.name.endsWith(".md") ? "text/markdown" :
                  (params.name.endsWith(".json") ? "application/json" : "text/plain");
                return toolText(JSON.stringify({
                  path: `${taskRelativeWriteRoot}/${params.name}`, media_type: mediaType
                }), { path: `${taskRelativeWriteRoot}/${params.name}`, media_type: mediaType });
              }
            }));

            pi.registerTool(defineTool({
              name: "evidence_terminal",
              label: "Capture terminal evidence",
              description: "Record one exact target command through Hive's controller-owned PTY capture boundary. Pass only the target command argv; this tool adds the Hive evidence-terminal prefix.",
              parameters: Type.Object({
                name: Type.String({ pattern: "^[a-z][a-z0-9_-]{0,63}$" }),
                argv: Type.Array(Type.String({ minLength: 1, maxLength: 4096 }), {
                  minItems: 1, maxItems: 64
                })
              }),
              async execute(_id, params, signal) {
                return runHive(["evidence", "terminal", params.name, "--json", "--", ...params.argv], signal);
              }
            }));

            #{browser_tool}
          }
        TYPESCRIPT
      end

      def self.sandbox_parent_dirs(paths, excluded: [])
        paths.flat_map do |path|
          parents = []
          cursor = File.dirname(path)
          until cursor == File.dirname(cursor)
            parents << cursor
            cursor = File.dirname(cursor)
          end
          parents
        end.uniq.reject { |path| excluded.include?(path) }
          .sort_by { |path| [ path.count(File::SEPARATOR), path ] }
      end


      def self.workflow_escalation_reasons(workflow)
        workflow.executable_slots.flat_map do |slot|
          actor = slot.actor
          spec = actor.respond_to?(:permissions) ? actor.permissions : nil
          spec.nil? ? [] : permission_escalation_reasons(spec)
        end.uniq.sort
      end

      def self.permission_escalation_reasons(permission_spec)
        spec = Hive::PermissionScope.parse_spec(permission_spec, stage: "managed-workflow")
        return [ "actor_yolo" ] if spec.fetch("preset") == Hive::PermissionScope::YOLO
        return [] unless spec.fetch("preset") == "scoped"
        return [ "actor_unbounded_shell" ] if spec["bash"] == true

        Array(spec["tools"]).each_with_object([]) do |rule, reasons|
          match = Hive::PermissionScope::TOOL_RULE_PATTERN.match(rule.to_s.strip)
          next unless match

          tool = match[:tool]
          reasons << "actor_unbounded_shell" if tool == "Bash"
          if match[:specifier].nil? && Hive::PermissionScope::FILE_EDIT_TOOLS.include?(tool)
            reasons << "actor_unbounded_write"
          end
        end.uniq.sort
      end

      # Admission mirrors every descriptor-selected runner, not just the
      # default stage profile. This catches a council reviewer or revise actor
      # that selects a runner unable to enforce the package policy before the
      # generation is activated (and the same compile runs again at spawn).
      def self.admit_workflow!(workflow, permissions = nil, task_folder:, policy_dir:, package_root: task_folder)
        workflow.executable_slots.each_with_index do |slot, index|
          actor = slot.actor
          name = actor.respond_to?(:agent) && actor.agent || :claude
          spec = actor.respond_to?(:permissions) ? actor.permissions : permissions
          raise Hive::ConfigError, "managed executable actor is missing permissions" if spec.nil?
          if spec.is_a?(Hash) && !(spec.key?("preset") || spec.key?(:preset))
            compile(
              spec, task_folder: task_folder, profile: Hive::AgentProfiles.lookup(name),
              policy_dir: File.join(policy_dir, "actor-#{index}-#{name}")
            )
          else
            compile_actor(
              spec, task_folder: task_folder, package_root: package_root,
              profile: Hive::AgentProfiles.lookup(name), environment: {}, prepare: false
            )
          end
        end
        true
      end

      def initialize(permissions, task_folder:, profile:, policy_dir:)
        @permissions = normalize_registry_permissions(stringify_hash(permissions))
        @task_folder = File.realpath(task_folder)
        @profile = profile
        @policy_dir = File.expand_path(policy_dir)
      rescue Errno::ENOENT, Errno::EACCES => e
        raise Hive::ConfigError, "managed runtime task folder is unavailable (#{e.class.name.split('::').last})"
      end

      def compile
        validate_profile!
        tools = normalize_array("tools")
        denied = normalize_array("deny")
        validate_tools!(tools, denied)
        commands = normalize_array("commands")
        domains = normalize_array("domains").map(&:downcase)
        validate_commands!(tools, commands)
        validate_domains!(tools, domains)
        validate_credentials!
        directories = resolve_directories
        executables = resolve_executables(commands)
        environment = sanitized_environment(executables)
        disallowed = ((SUPPORTED_TOOLS - tools) + ALWAYS_DENIED_TOOLS + denied).uniq.sort

        FileUtils.mkdir_p(@policy_dir, mode: 0o700)
        policy_path = File.join(@policy_dir, "policy.json")
        settings_path = File.join(@policy_dir, "settings.json")
        mcp_path = File.join(@policy_dir, "mcp.json")
        write_json(policy_path, {
          "allowed_tools" => tools,
          "directories" => directories,
          "commands" => commands,
          "domains" => domains,
          "executables" => executables
        })
        hook_file = File.expand_path("../scripts/workflow_policy_hook.rb", __dir__)
        hook_command = Shellwords.join(
          [ RbConfig.ruby, "-r#{hook_file}", "-e", "Hive::Scripts::WorkflowPolicyHook.run(ARGV.fetch(0))", policy_path ]
        )
        settings = {
          "permissions" => {
            "defaultMode" => "dontAsk",
            "allow" => tools,
            "deny" => disallowed,
            "additionalDirectories" => directories.drop(1)
          },
          "hooks" => {
            "PreToolUse" => [ { "hooks" => [ { "type" => "command", "command" => hook_command } ] } ]
          }
        }
        if tools.include?("Bash")
          settings["sandbox"] = {
            "enabled" => true,
            "failIfUnavailable" => true,
            "autoAllowBashIfSandboxed" => true,
            "excludedCommands" => [],
            "allowUnsandboxedCommands" => false,
            "filesystem" => { "allowWrite" => directories },
            "network" => { "allowedDomains" => domains, "deniedDomains" => [] }
          }
        end
        write_json(settings_path, settings)
        write_json(mcp_path, { "mcpServers" => {} })

        Policy.new(
          permission_mode: "dontAsk",
          allowed_tools: tools.freeze,
          disallowed_tools: disallowed.freeze,
          directories: directories.freeze,
          commands: commands.freeze,
          domains: domains.freeze,
          executables: executables.freeze,
          environment: environment.freeze,
          settings_path: settings_path.freeze,
          mcp_config_path: mcp_path.freeze,
          policy_path: policy_path.freeze,
          cli_flags: [ "--settings", settings_path, "--setting-sources", "",
                       "--mcp-config", mcp_path, "--strict-mcp-config" ].freeze,
          permission_flags: nil,
          agent_add_dirs: directories.freeze,
          command_prefix: [].freeze,
          executable: nil,
          task_root: @task_folder.freeze,
          output_paths: {}.freeze,
          cleanup_paths: [].freeze
        ).freeze
      end

      private

      # honeycomb-manifest/v1 publishes a deliberately coarse disclosure, not
      # the legacy command/tool policy. Only the one lossless subset supported
      # by the current runtime is admitted here. Anything broader stays closed
      # until Hive has an equally precise v2 enforcement path.
      def normalize_registry_permissions(permissions)
        return permissions unless permissions.key?("risk")

        keys = %w[risk capabilities network_hosts filesystem_read filesystem_write secrets]
        safe_read_only = permissions.keys.sort == keys.sort &&
                         permissions["risk"] == "low" &&
                         permissions["capabilities"] == [ "filesystem-read" ] &&
                         permissions["network_hosts"] == [] &&
                         permissions["filesystem_read"] == [ "task" ] &&
                         permissions["filesystem_write"] == [] &&
                         permissions["secrets"] == []
        unless safe_read_only
          raise Hive::ConfigError,
                "Honeycomb v2 summarized permissions cannot be safely admitted by this Hive runtime"
        end

        {
          "tools" => %w[Read LS Grep Glob],
          "deny" => %w[Write Edit MultiEdit NotebookEdit Bash WebFetch WebSearch],
          "directories" => [], "commands" => [], "domains" => [], "credentials" => []
        }
      end

      def validate_profile!
        capabilities = @profile.respond_to?(:policy_capabilities) ? @profile.policy_capabilities : []
        missing = REQUIRED_CAPABILITIES - capabilities
        support = Hive::AgentSupport.for(@profile)
        runtime = support::Runtime if support&.const_defined?(:Runtime, false)
        return if runtime&.respond_to?(:legacy_policy?) && runtime.legacy_policy? && missing.empty?

        raise Hive::ConfigError,
              "runner #{@profile.name.inspect} cannot enforce managed workflow policy" \
              "#{missing.empty? ? '' : " (missing: #{missing.join(', ')})"}"
      end

      def validate_tools!(tools, denied)
        unknown = (tools + denied) - (SUPPORTED_TOOLS + ALWAYS_DENIED_TOOLS)
        raise Hive::ConfigError, "managed policy declares unsupported tools" unless unknown.empty?

        overlap = tools & denied
        raise Hive::ConfigError, "managed policy tools and deny lists overlap" unless overlap.empty?
        raise Hive::ConfigError, "managed policy must allow at least one tool" if tools.empty?
        forbidden = tools & ALWAYS_DENIED_TOOLS
        raise Hive::ConfigError, "managed policy cannot allow inherited or interactive tools" unless forbidden.empty?
      end

      def validate_commands!(tools, commands)
        if tools.include?("Bash") && commands.empty?
          raise Hive::ConfigError, "managed Bash access requires declared commands"
        end
        if commands.any? && !tools.include?("Bash")
          raise Hive::ConfigError, "managed command declarations require the Bash tool"
        end
        commands.each do |command|
          if command.match?(COMMAND_META) || command.strip.empty?
            raise Hive::ConfigError, "managed command declarations must be exact or end in a single * wildcard"
          end
          tokens = Shellwords.shellsplit(command)
          wildcard = tokens.last == "*"
          tokens.pop if wildcard
          if tokens.empty? || tokens.any? { |token| token.include?("*") }
            raise Hive::ConfigError, "managed command declarations must use a literal executable and arguments"
          end
        rescue ArgumentError
          raise Hive::ConfigError, "managed command declaration has invalid shell quoting"
        end
      end

      def validate_domains!(tools, domains)
        raise Hive::ConfigError, "managed domains require WebFetch or declared Bash commands" if domains.any? && !(tools.include?("WebFetch") || tools.include?("Bash"))
        raise Hive::ConfigError, "managed WebFetch access requires declared domains" if tools.include?("WebFetch") && domains.empty?
        raise Hive::ConfigError, "managed policy contains an invalid domain" unless domains.all? { |domain| DOMAIN.match?(domain) }
      end

      def validate_credentials!
        credentials = normalize_array("credentials")
        return if credentials.empty?

        raise Hive::ConfigError, "managed credential injection is not supported by this Hive runtime"
      end

      def resolve_directories
        [ @task_folder ] + normalize_array("directories").map do |entry|
          if entry.start_with?("/") || entry.split(/[\\\/]/).include?("..") || entry.include?("\0")
            raise Hive::ConfigError, "managed directory declarations must be relative task paths"
          end
          resolved = File.expand_path(entry, @task_folder)
          effective = begin
            File.realpath(resolved)
          rescue Errno::ENOENT, Errno::EACCES
            resolved
          end
          unless effective == @task_folder || effective.start_with?(@task_folder + File::SEPARATOR)
            raise Hive::ConfigError, "managed directory declaration escapes the task folder"
          end
          effective
        end.uniq
      end

      def resolve_executables(commands)
        commands.each_with_object({}) do |command, out|
          executable = Shellwords.shellsplit(command).first
          next if out.key?(executable)

          resolved = find_executable(executable)
          raise Hive::ConfigError, "declared executable #{executable.inspect} is unavailable" unless resolved
          if resolved == @task_folder || resolved.start_with?(@task_folder + File::SEPARATOR)
            raise Hive::ConfigError, "declared executable resolves inside the task-controlled directory"
          end
          out[executable] = resolved
        end.sort.to_h
      end

      def find_executable(name)
        self.class.find_executable(name)
      end

      def sanitized_environment(executables)
        values = SAFE_ENV_KEYS.each_with_object({}) do |key, out|
          value = ENV[key]
          out[key] = value if value && !value.empty?
        end
        roots = executables.values.map { |path| File.dirname(path) }
        roots.concat(%w[/usr/local/bin /usr/bin /bin].select { |path| File.directory?(path) })
        values["PATH"] = roots.uniq.join(File::PATH_SEPARATOR)
        values["HIVE_MANAGED_POLICY"] = "1"
        values
      end

      def normalize_array(key)
        value = @permissions.fetch(key, [])
        unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.strip.empty? }
          raise Hive::ConfigError, "managed permissions.#{key} must be an array of non-empty strings"
        end
        value.map(&:strip).uniq.sort
      end

      def stringify_hash(value)
        raise Hive::ConfigError, "managed permissions must be a map" unless value.is_a?(Hash)

        value.to_h { |key, child| [ key.to_s, child ] }
      end

      def write_json(path, data)
        Hive::AtomicFile.write(path, Hive::WorkflowPackage::CanonicalJSON.generate(data), mode: 0o600)
      end
    end
  end
end
