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
require "hive/artifacts/managed_project_server"
require "hive/artifacts/managed_web_server"
require "hive/artifacts/project_command_sandbox"
require "hive/artifacts/outcome_evidence/proof"
require "hive/artifacts/terminal_recorder"
require "hive/config"
require "hive/agent_support"
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
      BROWSER_BOOTSTRAP_TIMEOUT_SECONDS = 30
      BROWSER_CLOSE_TIMEOUT_SECONDS = 10
      CAPTURE_KINDS = %w[screenshot terminal video].freeze
      CAPTURE_NAME = /\A[a-z][a-z0-9_-]{0,63}\z/

      attr_reader :launch_environment, :producer_add_dirs,
                  :producer_permission_arguments, :producer_runtime_policy

      def initialize(browser_bundle: nil, tool_resolver: nil, hive_executable: nil,
                     web_server_factory: nil, browser_command_runner: nil,
                     runtime_resolver: nil, legacy_runtime_resolver: nil,
                     project_sandbox_factory: nil)
        @browser_bundle = browser_bundle || Hive::Web::BrowserBundle.new
        @tool_resolver = tool_resolver || ->(name) { Hive::InvokedBinary.which(name) }
        @hive_executable = File.expand_path(
          hive_executable || File.join(__dir__, "..", "..", "..", "bin", "hive")
        )
        @web_server_factory = web_server_factory
        @browser_command_runner = browser_command_runner || method(:run_browser_command)
        @runtime_resolver = runtime_resolver || legacy_runtime_resolver
        @project_sandbox_factory = project_sandbox_factory || lambda do |**attributes|
          Hive::Artifacts::ProjectCommandSandbox.new(**attributes)
        end
        @launch_environment = {}
        @producer_add_dirs = []
        @producer_permission_arguments = nil
        @producer_runtime_policy = nil
        @browser_close = nil
        @browser_daemon = nil
        @browser_socket_root = nil
        @browser_state_root = nil
        @browser_preflight = nil
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
        producer_profile ||= Hive::AgentProfiles.default_evidence_producer
        managed = required & CAPTURE_KINDS
        support = Hive::AgentSupport.for(producer_profile)
        capture_interface = support&.respond_to?(:capture_interface_required?) &&
          support.capture_interface_required?
        return receipt if managed.empty? && !capture_interface

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
          @browser_preflight = start_browser_preflight unless server
          if !server && support&.respond_to?(:requires_project_runtime_root?) &&
             support.requires_project_runtime_root?
            prepare_project_runtime_root
          end
          @capture_proxy = Hive::Artifacts::CaptureProxy.new(
            app_port: server&.fetch("app_port", nil) ||
              @browser_preflight&.fetch(:app_port)
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
            on_publish: method(:record_capture!),
            ffprobe_path: media.fetch("ffprobe")
          ).start!
          @browser_command_runner.call(
            browser_environment, browser_argv + [ "open", @capture_proxy.origin ]
          )
          close_browser_preflight
          receipt["web"] = browser_receipt(entry, server, writable_root)
          receipt["media"] = media
        end

        @capture_mailbox = Hive::Artifacts::CaptureMailbox.new(
          handler: method(:handle_capture_request)
        ).start!
        @launch_environment["HIVE_EVIDENCE_CAPTURE_MAILBOX"] = @capture_mailbox.root
        @producer_add_dirs = [ @capture_mailbox.root ]
        unless support&.respond_to?(:prepare_capture)
          raise Hive::ConfigError,
                "managed capture evidence does not support producer #{producer_profile&.name.inspect}"
        end
        browser = (required & VISUAL_KINDS).any?
        preparation = support.prepare_capture(
          host: Hive::WorkflowPackage::RuntimePolicy::ProviderHost,
          profile: producer_profile, environment: @launch_environment,
          task_root:, source_root:, task_folder: source_root, package_root: task_root,
          writable_root:, mailbox_root: @capture_mailbox.root,
          extra_read_paths:, hive_runtime_paths:, hive_executable: @hive_executable,
          runtime_resolver: @runtime_resolver, browser:
        )
        @producer_permission_arguments = preparation[:permission_arguments]
        @producer_runtime_policy = preparation[:runtime_policy]
        if support.respond_to?(:producer_interface)
          receipt["producer_interface"] = support.producer_interface(
            required_kinds: required, browser:
          )
        end
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
                begin
                  @managed_project_server&.close
                ensure
                  begin
                    close_browser_preflight
                  ensure
                    @capture_proxy&.close
                    remove_browser_state_root
                    remove_project_runtime_root
                    @capture_proxy = nil
                    @managed_web_server = nil
                    @managed_project_server = nil
                    @browser_gateway = nil
                    @capture_mailbox = nil
                    @browser_close = nil
                    @browser_daemon = nil
                    @browser_socket_root = nil
                    @producer_add_dirs = []
                    @producer_permission_arguments = nil
                    @producer_runtime_policy&.cleanup!
                    @producer_runtime_policy = nil
                  end
                end
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

      # A non-Hive web project starts its own application server inside the
      # producer sandbox. The browser session still has to be proven usable
      # before that producer is launched. Serve one controller-owned readiness
      # page on the issued application port for the preflight navigation, then
      # release the port so the producer can bind the real application.
      def start_browser_preflight
        server = TCPServer.new("127.0.0.1", 0)
        server.listen(8)
        thread = Thread.new do
          loop do
            socket = server.accept
            serve_browser_preflight(socket)
          end
        rescue IOError, Errno::EBADF
          nil
        end
        thread.report_on_exception = false
        {
          server: server, thread: thread,
          app_port: server.local_address.ip_port
        }
      rescue SystemCallError
        server&.close
        raise
      end

      def serve_browser_preflight(socket)
        request = +"".b
        until request.include?("\r\n\r\n") || request.bytesize >= 64 * 1024
          break unless IO.select([ socket ], nil, nil, 1)

          chunk = socket.read_nonblock(8192, exception: false)
          break if chunk.nil?
          next if chunk == :wait_readable

          request << chunk
        end
        socket.write(
          "HTTP/1.1 200 OK\r\n" \
          "Content-Type: text/html; charset=utf-8\r\n" \
          "Content-Length: 15\r\n" \
          "Connection: close\r\n\r\n" \
          "<!doctype html>"
        )
      rescue IOError, SystemCallError
        nil
      ensure
        socket.close unless socket.closed?
      end

      def close_browser_preflight
        return unless @browser_preflight

        @browser_preflight.fetch(:server).close
        @browser_preflight.fetch(:thread).join(1)
      rescue IOError, SystemCallError
        nil
      ensure
        @browser_preflight = nil
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
            "record start <name>.webm", "record stop within 30 seconds"
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
        when "server"
          start_project_server(request.fetch("argv"))
        else
          { "ok" => false, "status" => 64, "error" => "capture operation is not admitted" }
        end
      rescue KeyError, TypeError => e
        { "ok" => false, "status" => 64, "error" => "capture request is invalid: #{e.message}" }
      rescue Hive::Artifacts::ManagedProjectServer::ServerError,
             Hive::Artifacts::ProjectCommandSandbox::SandboxError,
             Hive::Artifacts::TerminalRecorder::CaptureError, Hive::ConfigError => e
        { "ok" => false, "status" => 64, "error" => e.message }
      end

      def start_project_server(argv)
        raise Hive::ConfigError, "project evidence server is unavailable" unless
          @capture_proxy && !@managed_web_server

        @managed_project_server ||= Hive::Artifacts::ManagedProjectServer.new(
          source_root: @source_root, port: @capture_proxy.app_port,
          runtime_overlay_root: @project_runtime_root
        )
        receipt = @managed_project_server.start!(argv)
        { "ok" => true, "status" => 0, "payload" => receipt }
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
        sandbox = @project_sandbox_factory.call(
          source_root: @source_root, environment: ambient,
          runtime_overlay_root: @project_runtime_root
        )
        result = Hive::Artifacts::TerminalRecorder.new(
          argv: sandbox.command_argv(argv), display_argv: argv,
          cwd: @source_root, cast_path: cast, review_path: review,
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
      ensure
        sandbox&.close
      end

      def prepare_project_runtime_root
        @project_runtime_root = Dir.mktmpdir("hive-project-runtime-")
        File.chmod(0o700, @project_runtime_root)
      end

      def remove_project_runtime_root
        return unless @project_runtime_root

        stat = File.lstat(@project_runtime_root)
        unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
          raise Hive::ConfigError, "managed project runtime ownership changed"
        end

        FileUtils.remove_entry_secure(@project_runtime_root)
      rescue Errno::ENOENT
        nil
      ensure
        @project_runtime_root = nil
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

      def hive_runtime_paths
        root = File.dirname(File.dirname(@hive_executable))
        [
          @hive_executable,
          File.join(root, "lib"),
          *ruby_runtime_paths,
          *Gem.path.select { |path| File.directory?(path) }
        ].map { |path| File.expand_path(path) }.uniq
      end

      # RbConfig.ruby is part of every controller-issued browser/terminal
      # prefix, and a conventional project commonly reaches the same runtime
      # through an env shebang. Codex's closed filesystem policy must therefore
      # admit the selected Ruby executable, its sibling binstubs (for example
      # bundle), and the runtime libraries needed to load it. Gem.path alone is
      # insufficient: a hidden mise/asdf runtime makes env fall through to a
      # different system Ruby whose dependency set does not match the project.
      def ruby_runtime_paths
        config = RbConfig::CONFIG
        paths = [
          RbConfig.ruby,
          *%w[bindir libdir rubylibdir rubyarchdir sitelibdir sitearchdir
              vendorlibdir vendorarchdir].filter_map { |key| config[key] }
        ]
        paths.select { |path| !path.to_s.empty? && File.exist?(path) }
      end

      def run_browser_command(environment, argv)
        pid = nil
        pid = Process.spawn(
          environment, *argv, unsetenv_others: true, pgroup: true,
          in: File::NULL, out: File::NULL, err: File::NULL
        )
        timeout_seconds = argv.last == "close" ?
          BROWSER_CLOSE_TIMEOUT_SECONDS : BROWSER_BOOTSTRAP_TIMEOUT_SECONDS
        status = Timeout.timeout(timeout_seconds) do
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
