require "json"
require "fileutils"
require "rbconfig"
require "securerandom"
require "timeout"
require "uri"

module HiveDemo
  # Recorder-side lifecycle handle for `hive web capture-server`. Closing the
  # control writer is the normal teardown signal; abnormal exits terminate the
  # supervisor process group and wait for it to disappear.
  class CaptureServer
    START_TIMEOUT_SEC = 180
    STOP_TIMEOUT_SEC = 15
    SAFE_KEYS = %w[PATH LANG LC_ALL LC_CTYPE TZ SSL_CERT_FILE SSL_CERT_DIR].freeze

    attr_reader :receipt

    def self.start(source_root:, runtime_root:, log_path:, environment: ENV)
      session = new(
        source_root: source_root,
        runtime_root: runtime_root,
        log_path: log_path,
        environment: environment
      )
      session.start
      session
    end

    def initialize(source_root:, runtime_root:, log_path:, environment:)
      @source_root = File.expand_path(source_root)
      @runtime_root = File.expand_path(runtime_root)
      @log_path = File.expand_path(log_path)
      @environment = environment.to_h
      @token = "recorder-#{SecureRandom.hex(12)}"
    end

    def start
      FileUtils.mkdir_p(@runtime_root, mode: 0o700)
      @control_reader, @control_writer = IO.pipe
      @readiness_reader, readiness_writer = IO.pipe
      log = File.open(@log_path, "ab", 0o600)
      argv = [
        RbConfig.ruby,
        "-I#{File.join(@source_root, 'lib')}",
        File.join(@source_root, "bin", "hive"),
        "web", "capture-server",
        "--source-root", @source_root,
        "--runtime-root", @runtime_root,
        "--lifecycle-token", @token,
        "--control-fd", @control_reader.fileno.to_s,
        "--port", "0",
        "--json"
      ]
      @pid = Process.spawn(
        safe_environment,
        *argv,
        @control_reader.fileno => @control_reader,
        pgroup: true,
        in: File::NULL,
        out: readiness_writer,
        err: log,
        unsetenv_others: true
      )
      readiness_writer.close
      log.close
      line = Timeout.timeout(START_TIMEOUT_SEC) { @readiness_reader.gets }
      raise "capture supervisor exited without a readiness receipt; see #{@log_path}" unless line

      @receipt = JSON.parse(line)
      unless @receipt["schema"] == "hive-web-capture-runtime" &&
             @receipt["schema_version"] == 1 &&
             @receipt["lifecycle_id"] == @token &&
             @receipt["readiness_url"].to_s.start_with?("http://127.0.0.1:")
        raise "capture supervisor returned an invalid ownership receipt"
      end
      self
    rescue StandardError
      stop
      raise
    ensure
      @control_reader&.close
      @readiness_reader&.close
    end

    def base_url
      URI(@receipt.fetch("readiness_url")).then do |uri|
        "http://127.0.0.1:#{uri.port}"
      end
    end

    def stop
      @control_writer&.close
      return unless @pid

      Timeout.timeout(STOP_TIMEOUT_SEC) { Process.wait(@pid) }
      @pid = nil
    rescue Timeout::Error
      Process.kill("TERM", -@pid) rescue nil
      sleep 0.2
      Process.kill("KILL", -@pid) rescue nil
      Process.wait(@pid) rescue nil
      @pid = nil
      raise "capture supervisor did not stop cleanly; see #{@log_path}"
    rescue Errno::ECHILD
      @pid = nil
    ensure
      @control_reader&.close
      @control_writer&.close
      @readiness_reader&.close
    end

    private

    def safe_environment
      env = SAFE_KEYS.each_with_object({}) do |key, allowed|
        value = @environment[key]
        allowed[key] = value if value && !value.empty?
      end
      env["HOME"] = File.join(@runtime_root, "supervisor-home")
      env["XDG_CONFIG_HOME"] = File.join(@runtime_root, "supervisor-xdg", "config")
      env["XDG_CACHE_HOME"] = File.join(@runtime_root, "supervisor-xdg", "cache")
      env["XDG_DATA_HOME"] = File.join(@runtime_root, "supervisor-xdg", "data")
      env["XDG_STATE_HOME"] = File.join(@runtime_root, "supervisor-xdg", "state")
      env["HIVE_HOME"] = File.join(@runtime_root, "hive-home")
      env["HIVE_WEB_CAPTURE_CACHE_ROOT"] =
        @environment["HIVE_WEB_CAPTURE_CACHE_ROOT"] ||
        File.join(
          @environment["XDG_DATA_HOME"] ||
            File.join(@environment.fetch("HOME", @runtime_root), ".local", "share"),
          "hive", "web-capture-bundles"
        )
      env
    end
  end

  module BrowserTools
    module_function

    def playwright_cli!(web_root)
      explicit = ENV["HIVE_PLAYWRIGHT_CLI"].to_s
      candidate = explicit.empty? ?
        File.join(web_root, "node_modules", ".bin", "playwright") :
        File.expand_path(explicit)
      unless File.file?(candidate) && File.executable?(candidate)
        raise "pinned Playwright 1.60.0 is missing; run `npm ci` in #{web_root} and install Chromium"
      end
      candidate
    end

    def media_tools!
      %w[ffmpeg ffprobe].to_h do |name|
        path = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
                  .map { |dir| File.join(dir, name) }
                  .find { |candidate| File.file?(candidate) && File.executable?(candidate) }
        raise "#{name} is required for demo capture" unless path

        [ name, path ]
      end
    end
  end
end
