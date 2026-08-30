# frozen_string_literal: true

require "erb"
require "fileutils"
require "json"
require "tmpdir"
require "hive/brainstorm_suggestions/validator"

module Hive
  module BrainstormSuggestions
    # Launches a suggestion worker only through a profile that can prove a
    # tool-less, settings-isolated route inside a Bubblewrap filesystem view.
    class Runner
      MAX_OUTPUT_BYTES = 512 * 1024
      DEFAULT_TIMEOUT_SEC = 120
      KILL_GRACE_SEC = 1
      REQUIRED_CAPABILITY = :brainstorm_suggestion_data_only
      RUNTIME_PREFIX = "hive-brainstorm-suggestion-"

      Execution = Struct.new(:stdout, :exit_code, :timed_out, keyword_init: true)
      Launch = Struct.new(
        :argv, :environment, :stdin, :runtime_root, :bundle_root,
        keyword_init: true
      )

      # Thread-safe cooperative cancellation. The scheduler uses one token per
      # bound request; the process loop observes it and terminates the complete
      # provider process group before returning.
      class Cancellation
        def initialize
          @mutex = Mutex.new
          @cancelled = false
        end

        def cancel!
          @mutex.synchronize { @cancelled = true }
        end

        def cancelled?
          @mutex.synchronize { @cancelled }
        end
      end

      OUTPUT_SCHEMA = {
        "type" => "object",
        "additionalProperties" => false,
        "required" => [ "disposition" ],
        "properties" => {
          "disposition" => { "enum" => %w[suggestion no_safe_suggestion] },
          "text" => { "type" => "string" },
          "rationale" => { "type" => "string" },
          "provenance" => { "type" => "array", "items" => { "type" => "string" } },
          "reason_code" => {
            "enum" => %w[insufficient_evidence conflicting_evidence sensitive_context unsafe_output]
          }
        }
      }.freeze

      def self.profile_supported?(profile)
        profile.respond_to?(:policy_capabilities) &&
          profile.policy_capabilities.include?(REQUIRED_CAPABILITY) &&
          profile.respond_to?(:tool_scope_flags) &&
          profile.tool_scope_flags.key?(:allowed) &&
          profile.tool_scope_flags.key?(:disallowed)
      end

      def self.sweep_inactive!(runtime_parent = Dir.tmpdir)
        return 0 unless File.directory?(runtime_parent)

        Dir.children(runtime_parent).count do |name|
          next false unless name.start_with?(RUNTIME_PREFIX)

          path = File.join(runtime_parent, name)
          status = File.lstat(path)
          next false unless status.directory? && !status.symlink? && status.uid == Process.uid

          FileUtils.remove_entry_secure(path)
          true
        rescue SystemCallError, IOError
          false
        end
      end

      def initialize(profile:, model_arguments: [], timeout_sec: DEFAULT_TIMEOUT_SEC,
                     executor: nil, bwrap_path: "/usr/bin/bwrap",
                     executable_resolver: nil, runtime_parent: Dir.tmpdir)
        @profile = profile
        @model_arguments = Array(model_arguments).map(&:to_s).freeze
        @timeout_sec = Float(timeout_sec)
        @executor = executor || method(:execute)
        @bwrap_path = bwrap_path
        @executable_resolver = executable_resolver || method(:resolve_executable)
        @runtime_parent = runtime_parent
      end

      def call(bundle:, cancellation: nil)
        executable = available_executable
        return unavailable_result unless executable
        return failed_result("cancelled") if cancellation&.cancelled?

        runtime_root = Dir.mktmpdir(RUNTIME_PREFIX, @runtime_parent)
        File.chmod(0o700, runtime_root)
        bundle_root = bundle.materialize(runtime_root)
        auth_root = prepare_auth(runtime_root)
        launch = build_launch(
          runtime_root: runtime_root,
          bundle_root: bundle_root,
          auth_root: auth_root,
          executable: executable,
          bundle: bundle
        )
        execution = invoke_executor(launch, cancellation)
        return failed_result("cancelled") if cancellation&.cancelled?
        return failed_result("timeout") if execution.timed_out
        return failed_result("provider_exit") unless execution.exit_code == 0

        Validator.call(extract_structured_output(execution.stdout), manifest: bundle.manifest)
      rescue Validator::InvalidOutput, JSON::ParserError
        failed_result("malformed_result")
      rescue SystemCallError, IOError, ArgumentError
        failed_result("spawn_error")
      ensure
        FileUtils.remove_entry_secure(runtime_root) if runtime_root && File.exist?(runtime_root)
      end

      private

      def invoke_executor(launch, cancellation)
        if @executor.respond_to?(:parameters) && @executor.parameters.length >= 2
          @executor.call(launch, cancellation)
        else
          @executor.call(launch)
        end
      end

      def available_executable
        return unless self.class.profile_supported?(@profile)
        return unless File.file?(@bwrap_path) && File.executable?(@bwrap_path)

        executable = @executable_resolver.call(@profile)
        executable if executable && File.file?(executable) && File.executable?(executable)
      rescue SystemCallError, IOError
        nil
      end

      def prepare_auth(runtime_root)
        auth_root = File.join(runtime_root, "auth")
        Dir.mkdir(auth_root, 0o700)
        source_root = @profile.configuration_directory(environment: ENV)
        source = File.join(source_root, ".credentials.json")
        return auth_root unless File.file?(source) && !File.symlink?(source)

        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        bytes = File.open(source, flags, &:read)
        target = File.join(auth_root, ".credentials.json")
        File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o400) { |file| file.write(bytes) }
        File.chmod(0o400, target)
        auth_root
      rescue SystemCallError, IOError, ArgumentError
        auth_root
      end

      def build_launch(runtime_root:, bundle_root:, auth_root:, executable:, bundle:)
        argv = [ @bwrap_path, "--die-with-parent", "--new-session",
                 "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--unshare-cgroup-try" ]
        argv.concat([ "--ro-bind", "/usr", "/usr" ])
        append_compatibility_mounts(argv)
        argv.concat([ "--ro-bind", "/etc", "/etc" ])
        if File.directory?("/run/systemd/resolve")
          argv.concat([ "--dir", "/run", "--dir", "/run/systemd",
                        "--ro-bind", "/run/systemd/resolve", "/run/systemd/resolve" ])
        end
        argv.concat([
          "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
          "--dir", "/agent", "--dir", "/home", "--dir", "/home/hive-worker",
          "--dir", "/bundle", "--dir", "/auth",
          "--ro-bind", executable, "/agent/worker",
          "--ro-bind", bundle_root, "/bundle",
          "--ro-bind", auth_root, "/auth",
          "--setenv", "HOME", "/home/hive-worker",
          "--setenv", "CLAUDE_CONFIG_DIR", "/auth",
          "--setenv", "TMPDIR", "/tmp",
          "--chdir", "/bundle",
          "/agent/worker", "-p",
          "--safe-mode", "--disable-slash-commands",
          "--setting-sources", "", "--settings", "{}",
          "--strict-mcp-config", "--mcp-config", "{}",
          "--tools", "", "--allowedTools", "", "--disallowedTools", "default",
          "--permission-mode", "dontAsk", "--no-session-persistence",
          "--output-format", "json", "--json-schema", JSON.generate(OUTPUT_SCHEMA),
          *@model_arguments
        ])
        Launch.new(
          argv: argv.freeze,
          environment: sanitized_environment.freeze,
          stdin: render_prompt(bundle).freeze,
          runtime_root: runtime_root,
          bundle_root: bundle_root
        )
      end

      def append_compatibility_mounts(argv)
        %w[/bin /lib /lib64 /sbin].each do |path|
          next unless File.exist?(path) || File.symlink?(path)

          if File.symlink?(path)
            argv.concat([ "--symlink", File.readlink(path), path ])
          else
            argv.concat([ "--ro-bind", path, path ])
          end
        end
      end

      def sanitized_environment
        keys = %w[LANG LC_ALL LC_CTYPE TZ HTTPS_PROXY HTTP_PROXY NO_PROXY SSL_CERT_FILE]
        keys.concat(@profile.credential_environment_keys) if @profile.respond_to?(:credential_environment_keys)
        keys.filter_map do |key|
          value = ENV[key]
          [ key, value ] unless value.to_s.empty?
        end.to_h
      end

      def render_prompt(bundle)
        question_text = bundle.question.fetch("text")
        bound_context = bundle.render_context
        source = File.read(
          File.expand_path("../../../templates/brainstorm_suggestion_prompt.md.erb", __dir__)
        )
        ERB.new(source, trim_mode: "-").result(binding)
      end

      def extract_structured_output(stdout)
        outer = JSON.parse(stdout.to_s)
        return outer.fetch("structured_output") if outer.is_a?(Hash) && outer["structured_output"].is_a?(Hash)
        return JSON.parse(outer.fetch("result")) if outer.is_a?(Hash) && outer["result"].is_a?(String)

        outer
      end

      def execute(launch, cancellation = nil)
        output_r, output_w = IO.pipe
        input_r, input_w = IO.pipe
        pid = Process.spawn(
          launch.environment, *launch.argv,
          unsetenv_others: true, pgroup: true,
          in: input_r, out: output_w, err: output_w
        )
        input_r.close
        output_w.close
        input_w.write(launch.stdin)
        input_w.close
        output = +"".b
        reader = Thread.new do
          while (chunk = output_r.read(65_536))
            output << chunk if output.bytesize < MAX_OUTPUT_BYTES
          end
        end
        status = wait_for(pid, @timeout_sec, cancellation: cancellation)
        unless status
          terminate(pid)
          reader.join(KILL_GRACE_SEC)
          reader.kill if reader.alive?
          return Execution.new(stdout: output.byteslice(0, MAX_OUTPUT_BYTES), exit_code: nil, timed_out: true)
        end

        reader.join
        Execution.new(
          stdout: output.byteslice(0, MAX_OUTPUT_BYTES).to_s.force_encoding(Encoding::UTF_8).scrub,
          exit_code: status.exitstatus,
          timed_out: false
        )
      ensure
        input_r&.close unless input_r&.closed?
        input_w&.close unless input_w&.closed?
        output_r&.close unless output_r&.closed?
        output_w&.close unless output_w&.closed?
      end

      def wait_for(pid, timeout, cancellation: nil)
        deadline = monotonic_now + timeout
        loop do
          waited = Process.waitpid2(pid, Process::WNOHANG)
          return waited.last if waited
          return if cancellation&.cancelled?
          return if monotonic_now >= deadline

          IO.select(nil, nil, nil, 0.05)
        end
      end

      def terminate(pid)
        Process.kill("TERM", -pid)
        deadline = monotonic_now + KILL_GRACE_SEC
        loop do
          waited = Process.waitpid2(pid, Process::WNOHANG)
          return waited.last if waited
          break if monotonic_now >= deadline

          IO.select(nil, nil, nil, 0.05)
        end
        Process.kill("KILL", -pid)
        Process.waitpid2(pid).last
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def resolve_executable(profile)
        command = profile.bin.to_s
        return File.realpath(command) if command.include?(File::SEPARATOR)

        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
          candidate = File.join(directory, command)
          return File.realpath(candidate) if File.file?(candidate) && File.executable?(candidate)
        end
        nil
      end

      def unavailable_result
        {
          "state" => "unavailable", "text" => nil, "rationale" => nil,
          "provenance" => [],
          "safe_reason" => "The configured suggestion route cannot enforce Hive's data-only sandbox.",
          "retryable" => true, "dismissed" => false, "error_code" => "isolation_unavailable"
        }
      end

      def failed_result(code)
        {
          "state" => "failed", "text" => nil, "rationale" => nil,
          "provenance" => [],
          "safe_reason" => "Suggestion generation failed; manual answering remains available.",
          "retryable" => true, "dismissed" => false, "error_code" => code
        }
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
