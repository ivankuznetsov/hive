require "fileutils"
require "json"
require "securerandom"
require "socket"
require "tempfile"
require "timeout"
require "uri"

module Hive
  module Artifacts
    # A narrow controller-owned command boundary in front of agent-browser.
    # Producers never receive the browser daemon socket. The gateway admits
    # browser interaction commands, constrains navigation to the issued
    # origin, and publishes screenshot/video output into the attempt root
    # without letting the daemon resolve producer-supplied filesystem paths.
    class BrowserGateway
      MAX_REQUEST_BYTES = 64 * 1024
      MAX_OUTPUT_BYTES = 256 * 1024
      COMMAND_TIMEOUT_SECONDS = 60
      MAX_ARGUMENTS = 64
      MAX_ARGUMENT_BYTES = 8 * 1024
      MEDIA_NAME = /\A[a-z][a-z0-9_-]{0,63}\.(?:png|webm)\z/
      INTERACTION_COMMANDS = %w[
        snapshot click dblclick fill type press keydown keyup hover focus check
        uncheck select scroll scrollintoview wait get is find
      ].freeze
      SAFE_OPTIONS = %w[
        -i --interactive -c --compact --json --full --annotate --exact --name
      ].freeze
      GET_COMMANDS = %w[text html value attr title url count box styles].freeze

      attr_reader :socket_path, :socket_root

      class GatewayError < Hive::Error; end

      def initialize(environment:, argv_prefix:, writable_root:, origin:,
                     runner: nil)
        @environment = environment.to_h
        @argv_prefix = Array(argv_prefix).map(&:to_s).freeze
        @writable_root = File.realpath(writable_root)
        @origin = URI.parse(origin.to_s)
        @runner = runner || method(:run_command)
        @mutex = Mutex.new
        @closed = false
        @pending_record = nil
      end

      def start!
        @socket_root = Dir.mktmpdir("hive-browser-gateway-")
        @private_root = Dir.mktmpdir("hive-browser-output-")
        File.chmod(0o700, @socket_root)
        File.chmod(0o700, @private_root)
        @socket_path = File.join(@socket_root, "gateway.sock")
        @server = UNIXServer.new(@socket_path)
        File.chmod(0o600, @socket_path)
        @thread = Thread.new { accept_requests }
        @thread.report_on_exception = false
        self
      rescue SystemCallError => e
        close
        raise GatewayError, "browser gateway is unavailable: #{e.message}"
      end

      def close
        @mutex.synchronize do
          @closed = true
          @server&.close unless @server&.closed?
        end
        @thread&.join(1)
        remove_owned_root(@private_root)
        remove_owned_root(@socket_root)
        true
      rescue IOError, SystemCallError
        false
      ensure
        @server = nil
        @thread = nil
        @socket_path = nil
        @socket_root = nil
        @private_root = nil
      end

      private

      def accept_requests
        loop do
          client = @server.accept
          begin
            handle(client)
          ensure
            client.close
          end
        end
      rescue IOError, Errno::EBADF
        nil
      rescue SystemCallError
        retry unless @closed
      end

      def handle(client)
        line = client.gets(MAX_REQUEST_BYTES + 1)
        raise GatewayError, "browser request is missing" unless line
        if line.bytesize > MAX_REQUEST_BYTES || !line.end_with?("\n")
          raise GatewayError, "browser request is oversized"
        end

        request = JSON.parse(line)
        argv = validate_argv!(request.fetch("argv"))
        stdout, stderr, status = execute(argv)
        respond(client,
          "ok" => status.zero?, "status" => status,
          "stdout" => bounded(stdout), "stderr" => bounded(stderr)
        )
      rescue JSON::ParserError, KeyError, TypeError, GatewayError => e
        respond(client,
          "ok" => false, "status" => 64, "stdout" => "", "stderr" => e.message
        )
      rescue StandardError
        respond(client,
          "ok" => false, "status" => 70, "stdout" => "",
          "stderr" => "browser gateway command failed"
        )
      end

      def respond(client, payload)
        client.write(JSON.generate(payload) << "\n")
      rescue IOError, SystemCallError
        nil
      end

      def validate_argv!(value)
        argv = Array(value)
        unless value.is_a?(Array) && argv.any? && argv.length <= MAX_ARGUMENTS
          raise GatewayError, "browser command has an invalid argument count"
        end
        argv = argv.map do |argument|
          text = argument.to_s
          if text.empty? || text.bytesize > MAX_ARGUMENT_BYTES || text.include?("\0") ||
             text.match?(/[\r\n]/)
            raise GatewayError, "browser command contains an invalid argument"
          end
          text
        end
        command = argv.first
        return validate_open!(argv) if command == "open"
        return validate_screenshot!(argv) if command == "screenshot"
        return validate_record!(argv) if command == "record"
        unless INTERACTION_COMMANDS.include?(command)
          raise GatewayError, "browser command #{command.inspect} is not admitted"
        end
        if command == "get" && !GET_COMMANDS.include?(argv[1])
          raise GatewayError, "browser get command is not admitted"
        end
        unknown_options = argv.grep(/\A-/) - SAFE_OPTIONS
        unless unknown_options.empty?
          raise GatewayError,
                "browser command options are not admitted: #{unknown_options.join(', ')}"
        end
        argv
      end

      def validate_open!(argv)
        raise GatewayError, "browser open requires one issued-origin URL" unless argv.length == 2

        validate_url!(argv.last)
        argv
      end

      def validate_screenshot!(argv)
        options = argv.drop(2)
        unless argv.length.between?(2, 4) &&
               options.uniq.length == options.length &&
               options.all? { |item| %w[--full --annotate].include?(item) }
          raise GatewayError,
                "browser screenshot requires NAME.png and optional --full/--annotate"
        end
        name = safe_media_name!(argv.fetch(1), extension: ".png")
        [ "screenshot", private_media_path(name), *argv.drop(2) ]
      end

      def validate_record!(argv)
        action = argv[1]
        if action == "stop"
          raise GatewayError, "browser record stop takes no arguments" unless argv.length == 2
          raise GatewayError, "browser recording is not active" unless @pending_record
          return argv
        end
        unless action == "start" && argv.length.between?(3, 4)
          raise GatewayError, "browser record requires start NAME.webm [URL] or stop"
        end
        raise GatewayError, "browser recording is already active" if @pending_record

        name = safe_media_name!(argv.fetch(2), extension: ".webm")
        validate_url!(argv.fetch(3)) if argv[3]
        @pending_record = {
          private: private_media_path(name), public: public_media_path(name)
        }
        [ "record", "start", @pending_record.fetch(:private), *argv.drop(3) ]
      end

      def validate_url!(source)
        uri = URI.parse(source.to_s)
        valid = uri.scheme == @origin.scheme && uri.host == @origin.host &&
          uri.port == @origin.port && uri.userinfo.nil?
        raise GatewayError, "browser navigation must stay on the issued origin" unless valid
      rescue URI::InvalidURIError
        raise GatewayError, "browser navigation URL is invalid"
      end

      def safe_media_name!(source, extension:)
        name = source.to_s
        unless name.match?(MEDIA_NAME) && name.end_with?(extension)
          raise GatewayError, "browser media name is invalid"
        end
        name
      end

      def private_media_path(name)
        File.join(@private_root, "#{SecureRandom.hex(12)}-#{name}")
      end

      def public_media_path(name)
        File.join(@writable_root, name)
      end

      def execute(argv)
        media = if argv.first == "screenshot"
          { private: argv.fetch(1), public: public_media_path(File.basename(argv.fetch(1)).sub(/\A[0-9a-f]{24}-/, "")) }
        elsif argv == %w[record stop]
          @pending_record
        end
        stdout, stderr, status = @runner.call(@environment, @argv_prefix + argv)
        if status.zero? && media
          publish_media!(media.fetch(:private), media.fetch(:public))
          stdout = stdout.to_s.gsub(media.fetch(:private), media.fetch(:public))
          @pending_record = nil if argv == %w[record stop]
        elsif argv.first == "record" && argv[1] == "start" && !status.zero?
          @pending_record = nil
        end
        [ stdout.to_s, stderr.to_s, Integer(status) ]
      end

      def publish_media!(source, destination)
        stat = File.lstat(source)
        unless stat.file? && !stat.symlink? && stat.uid == Process.uid
          raise GatewayError, "browser did not produce owned regular media"
        end
        flags = File::WRONLY | File::CREAT | File::EXCL
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(destination, flags, 0o600) do |output|
          File.open(source, File::RDONLY | File::NOFOLLOW) do |input|
            IO.copy_stream(input, output)
          end
          output.flush
          output.fsync
        end
      rescue Errno::EEXIST, Errno::ELOOP
        raise GatewayError, "browser media destination already exists"
      rescue Errno::ENOENT
        raise GatewayError, "browser did not produce media"
      ensure
        begin
          File.unlink(source) if source && File.file?(source) && !File.symlink?(source)
        rescue Errno::ENOENT
          nil
        end
      end

      def run_command(environment, argv)
        stdout = Tempfile.new([ "browser-stdout", ".log" ], @private_root)
        stderr = Tempfile.new([ "browser-stderr", ".log" ], @private_root)
        pid = Process.spawn(
          environment, *argv, chdir: @private_root, pgroup: true,
          in: File::NULL, out: stdout, err: stderr, unsetenv_others: true
        )
        status = Timeout.timeout(COMMAND_TIMEOUT_SECONDS) { Process.wait2(pid).last }
        [ read_output(stdout), read_output(stderr), status.exitstatus || 1 ]
      rescue Timeout::Error
        terminate_process_group(pid)
        [ "", "browser command timed out", 124 ]
      rescue Errno::ENOENT => e
        [ "", "browser command failed: #{e.message}", 127 ]
      ensure
        begin
          Process.wait(pid, Process::WNOHANG) if pid
        rescue Errno::ECHILD
          nil
        end
        stdout&.close!
        stderr&.close!
      end

      def read_output(file)
        file.flush
        file.rewind
        bounded(file.read(MAX_OUTPUT_BYTES + 1))
      end

      def bounded(source)
        text = source.to_s.b
        suffix = text.bytesize > MAX_OUTPUT_BYTES ? "\n[hive: output truncated]\n" : ""
        text.byteslice(0, MAX_OUTPUT_BYTES).to_s.force_encoding(Encoding::UTF_8).scrub + suffix
      end

      def terminate_process_group(pid)
        Process.kill("TERM", -pid)
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end

      def remove_owned_root(path)
        return unless path && File.directory?(path) && !File.symlink?(path)

        stat = File.lstat(path)
        FileUtils.remove_entry_secure(path) if stat.uid == Process.uid
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
