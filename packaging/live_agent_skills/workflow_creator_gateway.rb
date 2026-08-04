# frozen_string_literal: true

require "digest"
require "json"
require "rbconfig"
require "securerandom"
require "socket"
require_relative "workflow_creator_process_supervisor"

module HiveLiveAgentProof
  class WorkflowCreatorGateway
    class Error < StandardError; end

    MAX_IPC_BYTES = 32 * 1024
    WRAPPER_NAME = "workflow-creator-gateway"
    SOCKET_NAME = ".workflow-creator-gateway.sock"
    TASK_SLUG = /\A[a-z][a-z0-9-]{0,62}[a-z0-9]\z/
    CREDENTIAL = /
      (?:^|_)
      (?:TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?|API_?KEY|PRIVATE_?KEY|AUTH(?:ORIZATION)?|COOKIE|SESSION)
      (?:_|$)
    /ix
    REFUSAL = "workflow-creator gateway refused request\n"

    def initialize(root:, candidate_executable:, candidate_identity:, environment:, cwd:, supervisor:,
                   socket_root: root)
      @root, @socket_root, @candidate, @cwd =
        [ root, socket_root, candidate_executable, cwd ].map { |path| File.expand_path(path) }
      @identity = WorkflowCreator::Values.capture(candidate_identity).value
      @environment = WorkflowCreator::Values.capture(environment).value
      @supervisor = supervisor
      @wrapper_path = File.join(@root, WRAPPER_NAME)
      @socket_path = File.join(@socket_root, SOCKET_NAME)
      @token = SecureRandom.hex(32).freeze
      @receipts, @position, @mutex = [], 1, Mutex.new
      @poisoned = @started = @stopping = false
      validate_inputs!
    rescue WorkflowCreator::Values::Error
      raise Error, "workflow-creator gateway inputs are invalid"
    end

    def start!
      @mutex.synchronize do
        raise Error, "workflow-creator gateway cannot be started" if @started || @poisoned
        verify_base!
        [ @socket_path, @wrapper_path ].each { |path| refuse_existing!(path) }
        @server = UNIXServer.new(@socket_path)
        File.chmod(0o600, @socket_path)
        @socket_identity = node_identity(File.lstat(@socket_path))
        install_wrapper!
        @started = true
        @thread = Thread.new { serve }
      end
      @wrapper_path.dup.freeze
    rescue StandardError => error
      stop_server
      raise error if error.instance_of?(Error)
      raise Error, "workflow-creator gateway cannot be started", cause: nil
    end

    def finish!
      complete = @mutex.synchronize do
        valid = @started && !@poisoned && @receipts.length == 9 && @position == 10
        @stopping = true
        @poisoned = true unless valid
        valid
      end
      stop_server
      raise Error, "workflow-creator gateway is incomplete" unless complete
      WorkflowCreator::Values.capture(@receipts).value
    rescue WorkflowCreator::Values::Error
      raise Error, "workflow-creator gateway is incomplete"
    end

    def close
      stop_server
      nil
    end

    private

    def validate_inputs!
      @root_identity = directory_identity(@root, private: true)
      @socket_root_identity = directory_identity(@socket_root, private: true)
      @cwd_identity = directory_identity(@cwd, private: false)
      environment_valid = @environment.instance_of?(Hash) && @environment.all? do |key, value|
        [ key, value ].all? { |item| item.instance_of?(String) && !item.empty? && !item.include?("\0") } &&
          !CREDENTIAL.match?(key)
      end
      supervisor_valid = @supervisor.instance_of?(WorkflowCreator::ProcessSupervisor)
      labels_valid = WorkflowCreator::Vocabulary.fetch("command_labels") ==
        WorkflowCreator::ProcessSupervisor::COMMAND_LABELS
      raise Error unless environment_valid && supervisor_valid && labels_valid
      admit_candidate!
    rescue KeyError, SystemCallError, Error
      raise Error, "workflow-creator gateway inputs are invalid"
    end

    def admit_candidate!
      stat = File.lstat(@candidate)
      path, digest, size = @identity.values_at("path", "sha256", "size") if @identity.instance_of?(Hash)
      relative = path.instance_of?(String) && WorkflowCreator::TextSafety.safe_relative_path?(path)
      valid = @identity.instance_of?(Hash) && @identity.keys.sort == %w[path sha256 size]
      valid &&= path == @candidate || (relative && @candidate.end_with?("/#{path}"))
      valid &&= /\A[0-9a-f]{64}\z/.match?(digest) && size.instance_of?(Integer) && size.positive?
      valid &&= stat.file? && !stat.symlink? && stat.uid == Process.uid && File.executable?(@candidate)
      valid &&= (stat.mode & 0o022).zero? && stat.size == size && Digest::SHA256.file(@candidate).hexdigest == digest
      raise Error unless valid
      @candidate_identity, @candidate_digest = file_identity(stat).freeze, digest
    rescue WorkflowCreator::TextSafety::Error, SystemCallError
      raise Error, "workflow-creator candidate identity is invalid"
    end

    def install_wrapper!
      File.open(@wrapper_path, File::WRONLY | File::CREAT | File::EXCL, 0o700) do |file|
        file.write(wrapper_source)
        file.flush
        file.fsync
      end
      File.chmod(0o700, @wrapper_path)
      @wrapper_identity = file_identity(File.lstat(@wrapper_path)).freeze
      @wrapper_digest = Digest::SHA256.file(@wrapper_path).hexdigest
    rescue SystemCallError
      raise Error, "workflow-creator gateway wrapper could not be installed"
    end

    def wrapper_source
      <<~RUBY
        #!#{RbConfig.ruby}
        require "json"
        require "socket"
        TOKEN = #{@token.dump}
        SOCKET_PATH = #{@socket_path.dump}
        LIMIT = #{MAX_IPC_BYTES}
        CREDENTIAL = #{CREDENTIAL.inspect}
        begin
          unsafe = ENV.keys.any? { |key| CREDENTIAL.match?(key) }
          request = JSON.generate("token" => TOKEN, "argv" => ARGV, "credential_env" => unsafe)
          raise if request.bytesize > LIMIT
          socket = UNIXSocket.new(SOCKET_PATH)
          socket.write(request)
          socket.close_write
          raw = socket.read(LIMIT + 1)
          raise if raw.bytesize > LIMIT
          response = JSON.parse(raw)
          raise unless response.instance_of?(Hash) && response.keys.sort == %w[exit_code signal stderr stdout]
          stdout, stderr = response.values_at("stdout", "stderr")
          raise unless stdout.instance_of?(String) && stderr.instance_of?(String)
          STDOUT.binmode.write(stdout)
          STDERR.binmode.write(stderr)
          if (signal = response.fetch("signal"))
            Signal.trap(signal, "DEFAULT")
            Process.kill(signal, Process.pid)
          end
          exit Integer(response.fetch("exit_code"))
        rescue StandardError
          STDERR.write(#{REFUSAL.dump})
          exit 125
        end
      RUBY
    end

    def serve
      loop do
        client = @server.accept
        raw = client.read(MAX_IPC_BYTES + 1)
        raise Error if raw.bytesize > MAX_IPC_BYTES
        response = @mutex.synchronize { dispatch(JSON.parse(raw)) }
        payload = JSON.generate(response)
        raise Error if payload.bytesize > MAX_IPC_BYTES
        client.write(payload)
      rescue IOError, Errno::EBADF
        break if @stopping
        poison_server!
        break
      rescue StandardError
        poison_server!
        client&.write(JSON.generate(refusal)) rescue nil
      ensure
        client&.close rescue nil
      end
    end

    def dispatch(request)
      valid = @started && !@stopping && !@poisoned && request.instance_of?(Hash) &&
        request.keys.sort == %w[argv credential_env token]
      valid &&= request.values_at("token", "credential_env") == [ @token, false ]
      expected = expected_command
      unless valid && request["argv"].instance_of?(Array) && request["argv"] == expected
        poison!
        return refusal
      end
      verify_runtime!
      receipt = @supervisor.run_command(
        position: @position, executable: @candidate, argv: expected,
        environment: @environment, cwd: @cwd
      )
      streams = receipt.fetch("capture").fetch("tails").slice("stdout", "stderr")
      unless passing?(receipt) && semantic_result?(receipt, streams.fetch("stdout"))
        poison!
        return process_response(receipt, streams, passing: false)
      end
      @receipts << command_receipt(receipt, expected)
      @position += 1
      process_response(receipt, streams, passing: true)
    rescue StandardError
      poison!
      refusal
    end

    def expected_command
      commands = @task_slug ? WorkflowCreator.commands_for(task_slug: @task_slug).value :
        WorkflowCreator::Vocabulary.fetch("commands")
      commands.fetch(@position - 1)
    rescue IndexError
      nil
    end

    def semantic_result?(receipt, stdout)
      return true unless [ 6, 8 ].include?(@position)
      return false unless receipt.dig("capture", "stdout_bytes") == stdout.b.bytesize
      payload = JSON.parse(stdout)
      valid = payload.instance_of?(Hash) && payload.values_at("schema", "ok", "created") ==
        [ "hive-new", true, @position == 6 ]
      valid &&= @position == 6 ? TASK_SLUG.match?(payload["slug"]) : payload["slug"] == @task_slug
      @task_slug = payload["slug"].dup.freeze if valid && @position == 6
      valid
    rescue JSON::ParserError, TypeError
      false
    end

    def passing?(receipt)
      capture, teardown = receipt.values_at("capture", "teardown")
      scan = capture.fetch("secret_scan")
      receipt.values_at("exit_code", "signal", "completed", "timed_out") == [ 0, nil, true, false ] &&
        %w[stdout stderr].none? { |stream| capture.fetch("#{stream}_truncated") } &&
        scan.values_at("status", "findings") == [ "passed", [] ] && teardown.fetch("status") == "passed"
    end

    def process_response(receipt, streams, passing:)
      code = receipt.fetch("exit_code")
      { "stdout" => streams.fetch("stdout"), "stderr" => streams.fetch("stderr"),
        "exit_code" => passing || (code && !code.zero?) ? code : 125, "signal" => receipt.fetch("signal") }
    end

    def command_receipt(receipt, argv)
      capture = receipt.fetch("capture").except("tails")
      capture["secret_scan"] = capture.fetch("secret_scan").except("findings")
      WorkflowCreator::Values.capture(
        "position" => @position,
        "attempt_label" => WorkflowCreator::Vocabulary.fetch("command_labels").fetch(@position - 1),
        "argv" => argv, "exit_code" => receipt.fetch("exit_code"), "signal" => receipt.fetch("signal"),
        "completed" => receipt.fetch("completed"), "capture" => capture, "teardown" => receipt.fetch("teardown")
      ).value
    end

    def verify_base!
      raise Error unless directory_identity(@root, private: true) == @root_identity
      raise Error unless directory_identity(@socket_root, private: true) == @socket_root_identity
      raise Error unless directory_identity(@cwd, private: false) == @cwd_identity
      stat = File.lstat(@candidate)
      valid = file_identity(stat) == @candidate_identity && Digest::SHA256.file(@candidate).hexdigest == @candidate_digest
      raise Error unless valid
    end

    def verify_runtime!
      verify_base!
      socket = File.lstat(@socket_path)
      wrapper = File.lstat(@wrapper_path)
      valid = socket.socket? && node_identity(socket) == @socket_identity
      valid &&= wrapper.file? && (wrapper.mode & 0o777) == 0o700 && file_identity(wrapper) == @wrapper_identity
      valid &&= Digest::SHA256.file(@wrapper_path).hexdigest == @wrapper_digest
      raise Error unless valid
    rescue StandardError
      raise Error, "workflow-creator gateway runtime identity changed"
    end

    def directory_identity(path, private:)
      stat = File.lstat(path)
      valid = File.realpath(path) == path && stat.directory? && !stat.symlink? && stat.uid == Process.uid
      valid &&= (stat.mode & 0o077).zero? if private
      raise Error unless valid
      node_identity(stat)
    end

    def poison! = @poisoned = true
    def poison_server! = @mutex.synchronize { poison! }
    def refusal = { "stdout" => "", "stderr" => REFUSAL, "exit_code" => 125, "signal" => nil }
    def node_identity(stat) = [ stat.dev, stat.ino, stat.uid, stat.mode ]
    def file_identity(stat) = [ *node_identity(stat), stat.size, stat.mtime, stat.ctime ]
    def refuse_existing!(path)
      File.lstat(path)
      raise Error, "workflow-creator gateway member already exists"
    rescue Errno::ENOENT
      nil
    end
    def stop_server
      @mutex.synchronize { @stopping = true }
      @server&.close rescue nil
      @thread&.join(2)
      stat = File.lstat(@socket_path)
      File.unlink(@socket_path) if @socket_identity && node_identity(stat) == @socket_identity
    rescue Errno::ENOENT
      nil
    end
  end
end
