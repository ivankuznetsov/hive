require "fileutils"
require "json"
require "rbconfig"
require "securerandom"
require "tmpdir"
require "timeout"
require "hive/artifacts/browser_gateway"
require "hive/artifacts/capture_proxy"
require "hive/artifacts/managed_web_server"
require "hive/artifacts/outcome_evidence/proof"
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
      MIN_CODEX_PERMISSION_VERSION = "0.138.0".freeze
      BROWSER_CLOSE_TIMEOUT_SECONDS = 10

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
          "terminal" => {
            "driver" => "hive-native-pty",
            "argv_prefix" => [
              RbConfig.ruby, @hive_executable, "evidence", "terminal", "<name>",
              "--json", "--"
            ],
            "outputs" => [ "<name>.cast", "<name>.txt" ]
          },
          "media" => {}
        }
        return receipt unless (required & VISUAL_KINDS).any?

        media = MEDIA_TOOLS.to_h { |name| [ name, @tool_resolver.call(name) ] }
        missing = media.filter_map { |name, path| name unless path }
        unless missing.empty?
          raise Hive::ConfigError,
                "outcome-evidence visual capture requires #{missing.join(', ')}"
        end
        entry = resolve_browser_bundle
        producer_profile ||= Hive::AgentProfiles.lookup(:codex)
        codex_runtime_roots = Array(@codex_runtime_resolver.call(producer_profile))
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
        browser_home = File.join(writable_root, ".agent-browser-home")
        browser_config = File.join(browser_home, ".config")
        browser_cache = File.join(browser_home, ".cache")
        browser_downloads = File.join(browser_home, "downloads")
        socket_root = Dir.mktmpdir("hive-ab-")
        File.chmod(0o700, socket_root)
        @browser_socket_root = socket_root
        FileUtils.mkdir_p(
          [ browser_home, browser_config, browser_cache, browser_downloads ], mode: 0o700
        )
        namespace = "n-#{SecureRandom.hex(4)}"
        browser_environment = browser_environment(
          entry: entry, writable_root: writable_root, browser_home: browser_home,
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
          writable_root: writable_root, origin: @capture_proxy.origin
        ).start!
        @launch_environment["HIVE_EVIDENCE_BROWSER_SOCKET"] =
          @browser_gateway.socket_path
        @producer_add_dirs = [ @browser_gateway.socket_root ]
        @producer_permission_arguments = codex_permission_arguments(
          entry: entry, task_root: task_root, source_root: source_root,
          writable_root: writable_root, socket_root: @browser_gateway.socket_root,
          socket_path: @browser_gateway.socket_path,
          codex_runtime_roots: codex_runtime_roots,
          hive_runtime_paths: hive_runtime_paths
        )
        @browser_command_runner.call(
          browser_environment, browser_argv + [ "open", @capture_proxy.origin ]
        )
        receipt["web"] = {
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
            "filesystem" => "controller-owned evidence output root",
            "network" => "agent-browser domain allowlist and one-origin proxy"
          }
        }
        receipt["media"] = media
        receipt
      rescue Hive::Artifacts::CaptureProxy::ProxyError => e
        close_after_prepare_error
        raise Hive::ConfigError, "managed browser capture origin is unavailable: #{e.message}"
      rescue Hive::ConfigError
        close_after_prepare_error
        raise
      rescue SystemCallError => e
        close_after_prepare_error
        raise Hive::ConfigError, "managed browser capture could not start: #{e.message}"
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
              @managed_web_server&.close
            ensure
              @capture_proxy&.close
              @capture_proxy = nil
              @managed_web_server = nil
              @browser_gateway = nil
              @browser_close = nil
              @browser_daemon = nil
              @browser_socket_root = nil
              @producer_add_dirs = []
              @producer_permission_arguments = nil
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

      def codex_permission_arguments(entry:, task_root:, source_root:, writable_root:,
                                     socket_root:, socket_path:, codex_runtime_roots:,
                                     hive_runtime_paths:)
        filesystem = {
          ":minimal" => "read",
          task_root => "read",
          source_root => "read",
          writable_root => "write",
          socket_root => "write",
          entry.cache_root => "read"
        }
        codex_runtime_roots.each { |path| filesystem[path] = "read" }
        hive_runtime_paths.each { |path| filesystem[path] = "read" }
        filesystem = filesystem.map do |path, access|
          "#{JSON.generate(path)}=#{JSON.generate(access)}"
        end.join(",")
        socket = "#{JSON.generate(socket_path)}=#{JSON.generate('allow')}"
        [
          "--ephemeral", "--ignore-user-config", "--ignore-rules",
          "-c", 'approval_policy="never"',
          "-c", "default_permissions=#{JSON.generate(CODEX_PERMISSION_PROFILE)}",
          "-c", "permissions.#{CODEX_PERMISSION_PROFILE}.filesystem={#{filesystem}}",
          "-c", "permissions.#{CODEX_PERMISSION_PROFILE}.network.enabled=true",
          "-c", "permissions.#{CODEX_PERMISSION_PROFILE}.network.unix_sockets={#{socket}}",
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
                "managed visual evidence requires the Codex producer"
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
                "managed visual evidence could not resolve the Codex native runtime"
        end
        native.map do |executable|
          Hive::WorkflowPackage::RuntimePolicy.codex_runtime_root(executable)
        end.uniq
      rescue Hive::AgentError => e
        raise Hive::ConfigError,
              "managed visual evidence requires Codex " \
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

      def close_after_prepare_error
        close
      rescue Hive::ConfigError, SystemCallError
        nil
      end
    end
  end
end
