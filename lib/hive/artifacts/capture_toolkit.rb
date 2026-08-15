require "fileutils"
require "digest"
require "json"
require "pathname"
require "rbconfig"
require "securerandom"
require "tmpdir"
require "timeout"
require "hive/artifacts/browser_gateway"
require "hive/artifacts/capture_mailbox"
require "hive/artifacts/capture_proxy"
require "hive/artifacts/managed_web_server"
require "hive/artifacts/outcome_evidence/proof"
require "hive/artifacts/terminal_recorder"
require "hive/config"
require "hive/invoked_binary"
require "hive/web/browser_bundle"
require "hive/workflow_package/runtime_policy"

module Hive
  module Artifacts
    # Resolves capture capabilities once, before evidence production, and
    # gives the producer one controller-owned interface instead of a tool hunt.
    class CaptureToolkit
      VISUAL_KINDS = %w[screenshot video].freeze
      MEDIA_TOOLS = %w[ffmpeg ffprobe tesseract].freeze
      BROWSER_SESSION = "evidence".freeze
      CODEX_PERMISSION_PROFILE = "hive-evidence".freeze
      MIN_CODEX_PERMISSION_VERSION = "0.147.0".freeze
      BROWSER_CLOSE_TIMEOUT_SECONDS = 10
      CAPTURE_KINDS = %w[screenshot terminal video].freeze
      CAPTURE_NAME = /\A[a-z][a-z0-9_-]{0,63}\z/

      attr_reader :launch_environment, :producer_add_dirs,
                  :producer_permission_arguments

      def initialize(browser_bundle: nil, tool_resolver: nil, hive_executable: nil,
                     web_server_factory: nil, browser_command_runner: nil,
                     codex_runtime_resolver: nil)
        @browser_bundle = browser_bundle || Hive::Web::BrowserBundle.new
        @tool_resolver = tool_resolver || ->(name) { Hive::InvokedBinary.which(name) }
        @hive_executable = File.expand_path(
          hive_executable || File.join(__dir__, "..", "..", "..", "bin", "hive")
        )
        @web_server_factory = web_server_factory
        @browser_command_runner = browser_command_runner || method(:run_browser_command)
        @codex_runtime_resolver = codex_runtime_resolver || method(:resolve_codex_runtime)
        @launch_environment = {}
        @producer_add_dirs = []
        @producer_permission_arguments = nil
        @browser_close = nil
        @browser_daemon = nil
        @browser_socket_root = nil
        @browser_state_root = nil
        @capture_receipts = {}
      end

      def prepare!(kinds:, task_root:, source_root:, source_sha:, writable_root:,
                   producer_profile: nil)
        close
        required = Array(kinds).map(&:to_s).uniq.sort
        unknown = required - Hive::Artifacts::OutcomeEvidence::Proof::KINDS
        raise Hive::ConfigError, "unsupported capture proof kinds: #{unknown.join(', ')}" if unknown.any?

        task_root = File.expand_path(task_root)
        source_root = File.expand_path(source_root)
        writable_root = File.expand_path(writable_root)
        FileUtils.mkdir_p(writable_root, mode: 0o700)
        @task_root = task_root
        @source_root = source_root
        @source_sha = source_sha.to_s
        @writable_root = writable_root
        @capture_receipts = {}
        @launch_environment = {
          "HIVE_EVIDENCE_WRITE_ROOT" => writable_root,
          "HIVE_EVIDENCE_TASK_ROOT" => task_root,
          "HIVE_EVIDENCE_SOURCE_ROOT" => source_root,
          "HIVE_EVIDENCE_SOURCE_SHA" => source_sha.to_s
        }
        receipt = {
          "schema" => "hive-capture-toolkit",
          "schema_version" => 1,
          "required_kinds" => required,
          "web" => nil,
          "terminal" => required.include?("terminal") ? {
            "driver" => "hive-native-pty",
            "argv_prefix" => [
              RbConfig.ruby, @hive_executable, "evidence", "terminal", "<name>",
              "--json", "--"
            ],
            "outputs" => [ "<name>.cast", "<name>.txt" ]
          } : nil,
          "media" => {}
        }
        managed = required & CAPTURE_KINDS
        return receipt if managed.empty?

        producer_profile ||= Hive::AgentProfiles.lookup(:codex)
        codex_runtime_roots = Array(@codex_runtime_resolver.call(producer_profile))
        extra_read_paths = []

        if (required & VISUAL_KINDS).any?
          media = MEDIA_TOOLS.to_h { |name| [ name, @tool_resolver.call(name) ] }
          missing = media.filter_map { |name, path| name unless path }
          unless missing.empty?
            raise Hive::ConfigError,
                  "outcome-evidence visual capture requires #{missing.join(', ')}"
          end
          entry = resolve_browser_bundle
          extra_read_paths << entry.cache_root
          server = start_managed_web_server(
            source_root: source_root, source_sha: source_sha,
            writable_root: writable_root
          )
          @capture_proxy = Hive::Artifacts::CaptureProxy.new(
            app_port: server&.fetch("app_port", nil)
          )
          @launch_environment.merge!(
            "HIVE_EVIDENCE_APP_PORT" => @capture_proxy.app_port.to_s,
            "HIVE_EVIDENCE_BROWSER_ORIGIN" => @capture_proxy.origin
          )
          if server
            @launch_environment["HIVE_EVIDENCE_WEB_HIVE_HOME"] =
              server.fetch("hive_home")
          end
          @browser_state_root = Dir.mktmpdir("hive-browser-state-")
          File.chmod(0o700, @browser_state_root)
          browser_home = File.join(@browser_state_root, "home")
          browser_config = File.join(browser_home, ".config")
          browser_cache = File.join(browser_home, ".cache")
          browser_downloads = File.join(@browser_state_root, "downloads")
          socket_root = Dir.mktmpdir("hive-ab-")
          File.chmod(0o700, socket_root)
          @browser_socket_root = socket_root
          FileUtils.mkdir_p(
            [ browser_home, browser_config, browser_cache, browser_downloads ], mode: 0o700
          )
          namespace = "n-#{SecureRandom.hex(4)}"
          browser_environment = browser_environment(
            entry: entry, writable_root: @browser_state_root, browser_home: browser_home,
            browser_config: browser_config, browser_cache: browser_cache,
            browser_downloads: browser_downloads, socket_root: socket_root,
            namespace: namespace
          )
          browser_argv = [
            entry.agent_browser_cli, "--session", BROWSER_SESSION,
            "--namespace", namespace, "--executable-path", entry.browser_executable,
            "--allowed-domains", @capture_proxy.hostname
          ]
          @browser_close = [ browser_environment, browser_argv + [ "close" ] ]
          @browser_daemon = {
            pid_path: File.join(
              socket_root, "namespaces", namespace, "run", "#{BROWSER_SESSION}.pid"
            ),
            executable: entry.agent_browser_cli,
            socket_root: socket_root,
            namespace: namespace
          }
          @browser_gateway = Hive::Artifacts::BrowserGateway.new(
            environment: browser_environment, argv_prefix: browser_argv,
            writable_root: writable_root, origin: @capture_proxy.origin,
            on_publish: method(:record_capture!)
          ).start!
          @browser_command_runner.call(
            browser_environment, browser_argv + [ "open", @capture_proxy.origin ]
          )
          receipt["web"] = browser_receipt(entry, server, writable_root)
          receipt["media"] = media
        end

        @capture_mailbox = Hive::Artifacts::CaptureMailbox.new(
          handler: method(:handle_capture_request)
        ).start!
        @launch_environment["HIVE_EVIDENCE_CAPTURE_MAILBOX"] = @capture_mailbox.root
        @producer_add_dirs = [ @capture_mailbox.root ]
        @producer_permission_arguments = codex_permission_arguments(
          task_root: task_root, source_root: source_root,
          writable_root: writable_root, mailbox_root: @capture_mailbox.root,
          extra_read_paths: extra_read_paths,
          codex_runtime_roots: codex_runtime_roots,
          hive_runtime_paths: hive_runtime_paths
        )
        receipt
      rescue Hive::Artifacts::CaptureProxy::ProxyError => e
        close_after_prepare_error
        raise Hive::ConfigError, "managed browser capture origin is unavailable: #{e.message}"
      rescue Hive::Artifacts::BrowserGateway::GatewayError,
             Hive::Artifacts::CaptureMailbox::MailboxError => e
        close_after_prepare_error
        raise Hive::ConfigError, "managed capture gateway is unavailable: #{e.message}"
      rescue Hive::ConfigError
        close_after_prepare_error
        raise
      rescue SystemCallError => e
        close_after_prepare_error
        raise Hive::ConfigError, "managed browser capture could not start: #{e.message}"
      end

      def verify_captures!(evidence)
        Array(evidence).each do |entry|
          kind = entry.fetch("kind").to_s
          next unless CAPTURE_KINDS.include?(kind)
          if entry.dig("source", "type").to_s == "project_provider"
            verify_project_provider!(entry)
            next
          end

          Array(entry.fetch("representations")).each do |representation|
            path = Hive::Artifacts::OutcomeEvidence::Identity.validate_changed_path!(
              representation.fetch("path")
            )
            receipt = @capture_receipts[path]
            media_type = representation.fetch("media_type").to_s
            unless receipt && receipt.fetch("media_type") == media_type &&
                   capture_file_matches?(path, receipt)
              raise Hive::Artifacts::OutcomeEvidence::StoreError,
                    "#{kind} evidence #{path.inspect} has no matching controller capture receipt"
            end
          end
        end
        true
      rescue KeyError => e
        raise Hive::Artifacts::OutcomeEvidence::StoreError,
              "producer evidence is missing #{e.key}"
      end

      def close
        begin
          begin
            if @browser_close
              environment, argv = @browser_close
              @browser_command_runner.call(environment, argv)
            end
          ensure
            begin
              stop_browser_daemon
            ensure
              remove_browser_socket_root
            end
          end
        ensure
          begin
            @browser_gateway&.close
          ensure
            begin
              @capture_mailbox&.close
            ensure
              begin
                @managed_web_server&.close
              ensure
                @capture_proxy&.close
                remove_browser_state_root
                @capture_proxy = nil
                @managed_web_server = nil
                @browser_gateway = nil
                @capture_mailbox = nil
                @browser_close = nil
                @browser_daemon = nil
                @browser_socket_root = nil
                @producer_add_dirs = []
                @producer_permission_arguments = nil
              end
            end
          end
        end
      end

      private

      def start_managed_web_server(source_root:, source_sha:, writable_root:)
        return nil unless hive_web_source?(source_root)

        lifecycle_token = "outcome-evidence-#{SecureRandom.hex(12)}"
        @managed_web_server = if @web_server_factory
          @web_server_factory.call(
            source_root: source_root, source_sha: source_sha,
            writable_root: writable_root, lifecycle_token: lifecycle_token
          )
        else
          Hive::Artifacts::ManagedWebServer.new(
            source_root: source_root, source_sha: source_sha,
            writable_root: writable_root, lifecycle_token: lifecycle_token
          )
        end
        @managed_web_server.start!
      rescue Hive::Artifacts::ManagedWebServer::ServerError => e
        raise Hive::ConfigError, "managed Hive Web capture is unavailable: #{e.message}"
      end

      def hive_web_source?(source_root)
        %w[bin/hive web/Gemfile web/bin/rails].all? do |relative|
          File.file?(File.join(source_root, relative))
        end
      end

      def resolve_browser_bundle
        bundle = @browser_bundle.respond_to?(:ensure!) ? @browser_bundle : @browser_bundle.call
        bundle.ensure!
      rescue Hive::Web::BrowserBundle::BootstrapError => e
        raise Hive::ConfigError, "managed agent-browser capture is unavailable: #{e.message}"
      end

      def browser_environment(entry:, writable_root:, browser_home:, browser_config:,
                              browser_cache:, browser_downloads:, socket_root:, namespace:)
        {
          "HOME" => browser_home,
          "XDG_CONFIG_HOME" => browser_config,
          "XDG_CACHE_HOME" => browser_cache,
          "AGENT_BROWSER_SOCKET_DIR" => socket_root,
          "AGENT_BROWSER_EXECUTABLE_PATH" => entry.browser_executable,
          "AGENT_BROWSER_NAMESPACE" => namespace,
          "AGENT_BROWSER_ALLOWED_DOMAINS" => @capture_proxy.hostname,
          "AGENT_BROWSER_PROXY" => @capture_proxy.proxy_url,
          "AGENT_BROWSER_CONTENT_BOUNDARIES" => "true",
          "AGENT_BROWSER_MAX_OUTPUT" => "50000",
          "AGENT_BROWSER_DEFAULT_TIMEOUT" => "25000",
          "AGENT_BROWSER_IDLE_TIMEOUT_MS" => "1800000",
          "AGENT_BROWSER_SCREENSHOT_DIR" => writable_root,
          "AGENT_BROWSER_DOWNLOAD_PATH" => browser_downloads
        }
      end

      def browser_receipt(entry, server, writable_root)
        {
          "driver" => "agent-browser",
          "interface" => "cli",
          "status" => "ready",
          "version" => entry.agent_browser_version,
          "cache_key" => entry.cache_key,
          "session" => BROWSER_SESSION,
          "output_root" => writable_root,
          "argv_prefix" => [ RbConfig.ruby, @hive_executable, "evidence", "browser" ],
          "commands" => [
            "open <issued-origin-url>", "snapshot [-i|-c]",
            "click/fill/type/select/wait/get/is/find",
            "screenshot <name>.png [--full|--annotate]",
            "record start <name>.webm", "record stop"
          ],
          "media_names" => [ "<name>.png", "<name>.webm" ],
          "origin" => @capture_proxy.origin,
          "app_endpoint" => "http://127.0.0.1:#{@capture_proxy.app_port}",
          "server" => server,
          "sandbox" => {
            "driver" => "producer-workspace",
            "filesystem" => "controller-receipted evidence output root",
            "network" => "managed limited proxy with local bind only"
          }
        }
      end

      def handle_capture_request(request)
        case request.fetch("operation")
        when "browser"
          raise Hive::ConfigError, "browser capture is unavailable" unless @browser_gateway

          @browser_gateway.call(request.fetch("argv"))
        when "terminal"
          capture_terminal(request.fetch("name"), request.fetch("argv"))
        else
          { "ok" => false, "status" => 64, "error" => "capture operation is not admitted" }
        end
      rescue KeyError, TypeError => e
        { "ok" => false, "status" => 64, "error" => "capture request is invalid: #{e.message}" }
      rescue Hive::Artifacts::TerminalRecorder::CaptureError, Hive::ConfigError => e
        { "ok" => false, "status" => 64, "error" => e.message }
      end

      def capture_terminal(name, argv)
        name = name.to_s
        argv = Array(argv).map(&:to_s)
        unless name.match?(CAPTURE_NAME) && argv.any? && argv.none?(&:empty?)
          raise Hive::ConfigError, "terminal capture request is invalid"
        end
        cast = File.join(@writable_root, "#{name}.cast")
        review = File.join(@writable_root, "#{name}.txt")
        ambient = %w[PATH LANG LC_ALL LC_CTYPE TERM COLORTERM TZ].to_h do |key|
          [ key, ENV[key] ]
        end.compact
        result = Hive::Artifacts::TerminalRecorder.new(
          argv: argv, cwd: @source_root, cast_path: cast, review_path: review,
          environment: ambient
        ).record!
        result.fetch("representations").each { |representation| record_capture!(representation) }
        result.fetch("representations").each do |representation|
          representation["path"] = task_relative_path(representation.fetch("path"))
        end
        {
          "ok" => true, "status" => 0,
          "payload" => { "status" => "captured" }.merge(result)
        }
      end

      def verify_project_provider!(entry)
        canonical = Hive::Artifacts::OutcomeEvidence::Proof.admit!(
          entry, task_folder: @task_root, expected_head: @source_sha
        )
        manifest = canonical.dig("source", "manifest_path").to_s
        paths = canonical.fetch("representations").map { |row| row.fetch("path") }
        unless canonical == entry && manifest.start_with?("media/") &&
               paths.all? { |path| path.start_with?("media/") }
          raise Hive::Artifacts::OutcomeEvidence::StoreError,
                "project-provider evidence must use canonical controller-owned media"
        end
      end

      def record_capture!(representation)
        path = File.realpath(representation.fetch("path"))
        relative = task_relative_path(path)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink? && stat.size.positive? &&
               stat.size <= Hive::Artifacts::OutcomeEvidence::Proof::MAX_ORIGINAL_BYTES
          raise Hive::Artifacts::OutcomeEvidence::StoreError,
                "controller capture is not a bounded regular file"
        end
        digest = representation["sha256"].to_s
        observed_digest = bounded_digest(path, stat.size)
        unless digest.empty? || digest == observed_digest
          raise Hive::Artifacts::OutcomeEvidence::StoreError,
                "controller capture digest does not match its published bytes"
        end
        @capture_receipts[relative] = {
          "path" => relative,
          "media_type" => representation.fetch("media_type").to_s,
          "bytes" => stat.size,
          "sha256" => observed_digest
        }
      rescue Errno::ENOENT, Errno::ELOOP
        raise Hive::Artifacts::OutcomeEvidence::StoreError,
              "controller capture is unavailable"
      end

      def capture_file_matches?(relative, receipt)
        path = File.join(@task_root, relative)
        stat = File.lstat(path)
        stat.file? && !stat.symlink? && stat.size == receipt.fetch("bytes") &&
          bounded_digest(path, stat.size) == receipt.fetch("sha256")
      rescue Errno::ENOENT, Errno::ELOOP
        false
      end

      def bounded_digest(path, expected_bytes)
        digest = Digest::SHA256.new
        total = 0
        File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
          while (chunk = file.read(1024 * 1024))
            total += chunk.bytesize
            raise Hive::Artifacts::OutcomeEvidence::StoreError,
                  "controller capture changed after publication" if total > expected_bytes
            digest << chunk
          end
        end
        unless total == expected_bytes
          raise Hive::Artifacts::OutcomeEvidence::StoreError,
                "controller capture changed after publication"
        end
        digest.hexdigest
      end

      def task_relative_path(path)
        relative = Pathname.new(File.expand_path(path))
          .relative_path_from(Pathname.new(@task_root)).to_s
        Hive::Artifacts::OutcomeEvidence::Identity.validate_changed_path!(relative)
      rescue ArgumentError
        raise Hive::Artifacts::OutcomeEvidence::StoreError,
              "controller capture escapes the task folder"
      end

      def codex_permission_arguments(task_root:, source_root:, writable_root:,
                                     mailbox_root:, extra_read_paths:,
                                     codex_runtime_roots:, hive_runtime_paths:)
        filesystem = {
          ":minimal" => "read",
          task_root => "read",
          source_root => "read",
          writable_root => "write",
          mailbox_root => "write"
        }
        extra_read_paths.each { |path| filesystem[path] = "read" }
        codex_runtime_roots.each { |path| filesystem[path] = "read" }
        hive_runtime_paths.each { |path| filesystem[path] = "read" }
        filesystem = filesystem.map do |path, access|
          "#{JSON.generate(path)}=#{JSON.generate(access)}"
        end.join(",")
        [
          "--ephemeral", "--ignore-user-config", "--ignore-rules",
          "--enable", "network_proxy",
          "-c", 'approval_policy="never"',
          "-c", "default_permissions=#{JSON.generate(CODEX_PERMISSION_PROFILE)}",
          "-c", "permissions.#{CODEX_PERMISSION_PROFILE}.filesystem={#{filesystem}}",
          "-c", "permissions.#{CODEX_PERMISSION_PROFILE}.network.enabled=true",
          "-c", "permissions.#{CODEX_PERMISSION_PROFILE}.network.mode=\"limited\"",
          "-c", "permissions.#{CODEX_PERMISSION_PROFILE}.network.allow_local_binding=true",
          "-c", "permissions.#{CODEX_PERMISSION_PROFILE}.network.domains={}",
          "-c", 'web_search="disabled"',
          "-c", "mcp_servers={}",
          "-c", "apps._default.enabled=false",
          "-c", "features.apps=false",
          "-c", "features.remote_plugin=false",
          "-c", "features.tool_search=false",
          "-c", "features.multi_agent=false",
          "-c", "features.memories=false",
          "-c", "features.hooks=false",
          "-c", "features.plugins=false"
        ].freeze
      end

      def hive_runtime_paths
        root = File.dirname(File.dirname(@hive_executable))
        [
          @hive_executable,
          File.join(root, "lib"),
          *Gem.path.select { |path| File.directory?(path) }
        ].map { |path| File.expand_path(path) }.uniq
      end

      def resolve_codex_runtime(profile)
        unless profile&.name == :codex
          raise Hive::ConfigError,
                "managed capture evidence requires the Codex producer"
        end

        compatible = profile.with_overrides(
          "min_version" => MIN_CODEX_PERMISSION_VERSION
        )
        compatible.check_version!
        candidates = if compatible.bin.include?(File::SEPARATOR)
          [ File.expand_path(compatible.bin) ]
        else
          ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |directory|
            next if directory.empty?

            File.join(directory, compatible.bin)
          end
        end
        executables = candidates.filter_map do |candidate|
          next unless File.file?(candidate) && File.executable?(candidate)

          File.realpath(candidate)
        rescue Errno::ENOENT, Errno::EACCES
          nil
        end.uniq
        native = executables.reject { |path| File.binread(path, 2) == "#!" }
          .select do |path|
            root = File.dirname(File.dirname(path))
            File.basename(path) == "codex" ||
              File.directory?(File.join(root, "codex-resources"))
          end
        if native.empty?
          raise Hive::ConfigError,
                "managed capture evidence could not resolve the Codex native runtime"
        end
        native.map do |executable|
          Hive::WorkflowPackage::RuntimePolicy.codex_runtime_root(executable)
        end.uniq
      rescue Hive::AgentError => e
        raise Hive::ConfigError,
              "managed capture evidence requires Codex " \
              "#{MIN_CODEX_PERMISSION_VERSION}+: #{e.message}"
      end

      def run_browser_command(environment, argv)
        pid = nil
        pid = Process.spawn(
          environment, *argv, unsetenv_others: true, pgroup: true,
          in: File::NULL, out: File::NULL, err: File::NULL
        )
        status = Timeout.timeout(BROWSER_CLOSE_TIMEOUT_SECONDS) do
          _, value = Process.wait2(pid)
          value
        end
        return if status.success?

        raise Hive::ConfigError, "managed agent-browser command failed: #{argv.last}"
      rescue Timeout::Error
        terminate_process_group(pid)
        raise Hive::ConfigError, "managed agent-browser command timed out: #{argv.last}"
      rescue Errno::ENOENT => e
        raise Hive::ConfigError, "managed agent-browser command failed: #{e.message}"
      ensure
        begin
          Process.wait(pid, Process::WNOHANG) if pid
        rescue Errno::ECHILD
          nil
        end
      end

      def terminate_process_group(pid)
        Process.kill("TERM", -pid)
        sleep 0.1
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end

      def stop_browser_daemon
        return unless @browser_daemon

        pid = browser_daemon_pid
        return unless pid

        Process.kill("TERM", -pid)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        while process_alive?(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          sleep 0.05
        end
        Process.kill("KILL", -pid) if process_alive?(pid)
      rescue Errno::ESRCH
        nil
      end

      def browser_daemon_pid
        source = File.open(
          @browser_daemon.fetch(:pid_path), File::RDONLY | File::NOFOLLOW
        ) do |file|
          raise Hive::ConfigError, "managed agent-browser PID receipt is invalid" unless file.stat.file?

          file.read(33)
        end
        unless source.match?(/\A[1-9][0-9]{0,30}\n?\z/)
          raise Hive::ConfigError, "managed agent-browser PID receipt is invalid"
        end
        pid = Integer(source, 10)
        executable = File.realpath("/proc/#{pid}/exe")
        environment = File.binread("/proc/#{pid}/environ").split("\0")
        expected = [
          "AGENT_BROWSER_SOCKET_DIR=#{@browser_daemon.fetch(:socket_root)}",
          "AGENT_BROWSER_NAMESPACE=#{@browser_daemon.fetch(:namespace)}"
        ]
        unless executable == File.realpath(@browser_daemon.fetch(:executable)) &&
               Process.getpgid(pid) == pid && (expected - environment).empty?
          raise Hive::ConfigError, "managed agent-browser PID receipt is not owned by this attempt"
        end
        pid
      rescue Errno::ENOENT
        nil
      rescue Errno::ELOOP, Errno::EACCES, ArgumentError
        raise Hive::ConfigError, "managed agent-browser PID receipt is invalid"
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      end

      def remove_browser_socket_root
        return unless @browser_socket_root

        stat = File.lstat(@browser_socket_root)
        if stat.symlink? || !stat.directory?
          File.unlink(@browser_socket_root)
        else
          FileUtils.remove_entry_secure(@browser_socket_root)
        end
      rescue Errno::ENOENT
        nil
      end

      def remove_browser_state_root
        return unless @browser_state_root

        stat = File.lstat(@browser_state_root)
        if stat.symlink? || !stat.directory?
          File.unlink(@browser_state_root)
        else
          FileUtils.remove_entry_secure(@browser_state_root)
        end
      rescue Errno::ENOENT
        nil
      ensure
        @browser_state_root = nil
      end

      def close_after_prepare_error
        close
      rescue Hive::ConfigError, Hive::Artifacts::BrowserGateway::GatewayError,
             Hive::Artifacts::CaptureMailbox::MailboxError,
             Hive::Artifacts::ManagedWebServer::ServerError, SystemCallError
        nil
      end
    end
  end
end
