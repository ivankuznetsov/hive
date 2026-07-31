require "digest"
require "fileutils"
require "securerandom"
require "socket"
require "thread"
require "hive/attempts/process_identity"
require "hive/errors"
require "hive/managed_directory"
require "hive/modules/migration/qualification_open_router_transport"
require "hive/modules/migration/qualification_provider_protocol"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # One generation-scoped host capability. The socket is mounted read-only
      # into a networkless candidate. Peer process-group custody, a one-call
      # budget, PID-reuse-safe process-tree custody, descriptor-bound context,
      # canonical output, and teardown are all enforced before its transcript
      # can enter a generation receipt.
      class QualificationProviderBroker
        SOCKET_NAME = "broker.sock".freeze
        VIRTUAL_SOCKET =
          "/qualification/provider/#{SOCKET_NAME}".freeze
        TRANSCRIPT_SCHEMA =
          "hive-patrol-qualification-provider-transcript".freeze
        SCHEMA_VERSION = 1
        MAX_CALLS = 1
        MAX_SOCKET_WAIT_SECONDS = 1.0
        MAX_JOIN_SECONDS = 1.0
        IO_POLL_SECONDS = 0.02
        PEER_CREDENTIAL_BYTES = 12
        MAX_ANCESTOR_DEPTH = 32
        CALL_KEYS = %w[
          content_sha256 context_refs_sha256 input_tokens kind output_ref
          output_sha256 output_tokens prompt_sha256 request_id request_sha256
          response_sha256
        ].freeze
        FAILURE_KEYS = %w[
          phase reason request_id request_sha256 retryable
        ].freeze
        FAILURE_PHASES = %w[
          custody provider request response server
        ].freeze
        PROCESS_ROOT_KEYS = %w[
          pid process_group_id session_id start_fingerprint
        ].freeze

        class Failure < Hive::ConfigError
          attr_reader :reason, :retryable

          def initialize(reason:, retryable:)
            @reason = reason.to_s.freeze
            @retryable = retryable == true
            super("patrol qualification provider broker failed")
          end
        end

        Binding = Data.define(
          :host_root, :virtual_socket, :session, :case_id,
          :generation, :scenario_request_sha256, :broker
        )

        attr_reader :model

        def initialize(
          workspace:, run_id:, lane:, case_id:, generation:,
          scenario_request_sha256:, deadline:, api_key:,
          model: QualificationOpenRouterTransport::MODEL,
          transport: nil,
          process_identity:
            Hive::Attempts::ProcessIdentity.new,
          monotonic: lambda {
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          }
        )
          @workspace = File.expand_path(workspace.to_s)
          @run_id = run_id.to_s
          @lane = lane.to_s
          @case_id = case_id.to_s
          @generation = Integer(generation)
          @scenario_request_sha256 =
            scenario_request_sha256.to_s
          @deadline = Float(deadline)
          @model = model.to_s.freeze
          @monotonic = monotonic
          @process_identity = process_identity
          @transport =
            transport ||
              QualificationOpenRouterTransport.new(
                api_key: api_key,
                model: @model
              )
          @mutex = Mutex.new
          @armed = ConditionVariable.new
          @clients = []
          @calls = []
          @failure = nil
          @sealed = false
          @process_root = nil
          validate_context!
          @session = "session-#{SecureRandom.hex(32)}".freeze
          @session_sha256 =
            Digest::SHA256.hexdigest(@session).freeze
          @root = prepare_root
          @socket_path = File.join(@root, SOCKET_NAME).freeze
          @server = UNIXServer.new(@socket_path)
          File.chmod(0o600, @socket_path)
          @thread = Thread.new { serve }
          @thread.name =
            "hive-qualification-provider-#{@case_id}-#{@generation}" if
              @thread.respond_to?(:name=)
        rescue Hive::ConfigError
          cleanup_root
          raise
        rescue SystemCallError, ArgumentError, TypeError
          cleanup_root
          malformed!
        end

        def binding
          Binding.new(
            host_root: @root,
            virtual_socket: VIRTUAL_SOCKET,
            session: @session,
            case_id: @case_id,
            generation: @generation,
            scenario_request_sha256:
              @scenario_request_sha256,
            broker: self
          ).freeze
        end

        def arm!(process_root)
          identity =
            process_root.respond_to?(:to_h) ?
              process_root.to_h : process_root
          unless
            identity.is_a?(Hash) &&
              identity.keys.sort == PROCESS_ROOT_KEYS &&
              identity.fetch("pid").is_a?(Integer) &&
              identity.fetch("pid").positive? &&
              identity.fetch("process_group_id").is_a?(Integer) &&
              identity.fetch("process_group_id").positive? &&
              identity.fetch("session_id").is_a?(Integer) &&
              identity.fetch("session_id").positive? &&
              identity.fetch("start_fingerprint").is_a?(String) &&
              !identity.fetch("start_fingerprint").empty? &&
              identity.fetch("start_fingerprint").bytesize <= 128 &&
              @process_identity.respond_to?(:status) &&
              @process_identity.respond_to?(:capture) &&
              @process_identity.status(identity) == :matching
            protocol_failure!
          end
          @mutex.synchronize do
            protocol_failure! if @sealed || @process_root
            @process_root = immutable(identity)
            @armed.broadcast
          end
          self
        rescue ArgumentError, KeyError, TypeError
          protocol_failure!
        end

        def seal!
          @mutex.synchronize do
            @sealed = true
            @armed.broadcast
            @server&.close
            @clients.each do |client|
              client.close unless client.closed?
            rescue IOError, SystemCallError
              nil
            end
          end
          joined = @thread&.join(MAX_JOIN_SECONDS)
          unless joined
            @thread&.kill
            @thread&.join(MAX_JOIN_SECONDS)
            protocol_failure!
          end
          verify_outputs!
          unlink_socket!
          transcript
        rescue Failure
          raise
        rescue IOError, SystemCallError
          protocol_failure!
        ensure
          cleanup_root
        end

        def call_count
          @mutex.synchronize { @calls.length }
        end

        def sealed?
          @mutex.synchronize { @sealed }
        end

        def failure
          @mutex.synchronize { @failure }
        end

        def transcript
          @mutex.synchronize do
            protocol_failure! unless @sealed
            body = {
              "schema" => TRANSCRIPT_SCHEMA,
              "schema_version" => SCHEMA_VERSION,
              "run_id" => @run_id,
              "lane" => @lane,
              "case_id" => @case_id,
              "generation" => @generation,
              "scenario_request_sha256" =>
                @scenario_request_sha256,
              "session_sha256" => @session_sha256,
              "model" => @model,
              "call_count" => @calls.length,
              "calls" => immutable(@calls),
              "failure" => immutable(@failure)
            }
            immutable(
              body.merge(
                "transcript_sha256" =>
                  digest("provider-transcript", body)
              )
            )
          end
        end

        def transcript_sha256
          transcript.fetch("transcript_sha256")
        end

        private

        def validate_context!
          unless
            @workspace.start_with?("/") &&
              File.directory?(@workspace) &&
              File.realpath(@workspace) == @workspace &&
              QualificationRunDescriptor::RUN_ID.match?(@run_id) &&
              @lane == "installed" &&
              QualificationRunDescriptor::SAFE_ID.match?(@case_id) &&
              @generation.between?(1, 3) &&
              QualificationRunDescriptor::DIGEST.match?(
                @scenario_request_sha256
              ) &&
              @deadline.finite? &&
              @deadline > monotonic_now &&
              @model ==
                QualificationOpenRouterTransport::MODEL &&
              @transport.respond_to?(:call)
            malformed!
          end
        rescue SystemCallError
          malformed!
        end

        def prepare_root
          parent = File.join(@workspace, ".provider")
          Dir.mkdir(parent, 0o700) unless
            File.exist?(parent) || File.symlink?(parent)
          parent_stat = File.lstat(parent)
          protocol_failure! unless
            parent_stat.directory? &&
              !parent_stat.symlink? &&
              parent_stat.uid == Process.euid &&
              (parent_stat.mode & 0o777) == 0o700 &&
              File.realpath(parent) == parent
          root = File.join(
            parent,
            SecureRandom.hex(6)
          )
          Dir.mkdir(root, 0o700)
          root.freeze
        end

        def serve
          loop do
            server = @mutex.synchronize { @server }
            break unless server && !server.closed?

            ready = IO.select(
              [ server ], nil, nil, IO_POLL_SECONDS
            )
            next unless ready

            client = server.accept_nonblock
            register_client(client)
            handle(client)
          rescue IO::WaitReadable
            next
          rescue IOError, Errno::EBADF, Errno::EINVAL
            break if @mutex.synchronize { @sealed }
            record_protocol_failure
            break
          rescue StandardError
            record_protocol_failure
          ensure
            unregister_client(client) if client
            client&.close unless client&.closed?
            client = nil
          end
        end

        def register_client(client)
          @mutex.synchronize do
            if @sealed
              client.close
              protocol_failure!
            end
            @clients << client
          end
        end

        def unregister_client(client)
          @mutex.synchronize { @clients.delete(client) }
        end

        def handle(client)
          phase = "custody"
          process_root = await_process_root
          verify_peer!(client, process_root)
          phase = "request"
          request =
            QualificationProviderProtocol.load_request(
              read_frame(client)
            )
          validate_request!(request)
          phase = "provider"
          response = process_request(request)
          phase = "response"
          write_frame(
            client,
            QualificationProviderProtocol.canonical(
              response.to_h
            )
          )
        rescue QualificationOpenRouterTransport::Failure => error
          record_failure(
            request: request,
            phase: phase,
            reason: error.reason,
            retryable: error.retryable
          )
          write_error(client, request, error.reason)
        rescue Failure => error
          record_failure(
            request: request,
            phase: phase,
            reason: error.reason,
            retryable: error.retryable
          )
          write_error(client, request, error.reason)
        rescue Hive::ConfigError, IOError, SystemCallError,
               ArgumentError, TypeError
          record_failure(
            request: request,
            phase: phase,
            reason: "session_protocol_violation",
            retryable: false
          )
          write_error(
            client, request, "session_protocol_violation"
          )
        rescue StandardError
          record_failure(
            request: request,
            phase: phase,
            reason: "session_protocol_violation",
            retryable: false
          )
          write_error(
            client, request, "session_protocol_violation"
          )
        end

        def await_process_root
          @mutex.synchronize do
            while !@process_root && !@sealed
              remaining = @deadline - monotonic_now
              protocol_failure! unless remaining.positive?
              @armed.wait(
                @mutex,
                [ remaining, MAX_SOCKET_WAIT_SECONDS ].min
              )
            end
            protocol_failure! if @sealed || !@process_root
            @process_root
          end
        end

        def verify_peer!(client, process_root)
          credentials = client.getsockopt(
            Socket::SOL_SOCKET,
            Socket::SO_PEERCRED
          ).to_s
          protocol_failure! unless
            credentials.bytesize >= PEER_CREDENTIAL_BYTES
          pid, uid, _gid =
            credentials.unpack("i!i!i!")
          peer_identity = @process_identity.capture(pid)
          protocol_failure! unless
            uid == Process.euid &&
              pid.positive? &&
              peer_identity &&
              @process_identity.status(process_root) == :matching &&
              @process_identity.status(peer_identity.to_h) == :matching &&
              descendant_of?(
                pid,
                Integer(process_root.fetch("pid"))
              )
        rescue Errno::ESRCH, SystemCallError
          protocol_failure!
        end

        def descendant_of?(pid, root_pid)
          current = Integer(pid)
          root = Integer(root_pid)
          seen = {}
          MAX_ANCESTOR_DEPTH.times do
            return true if current == root
            return false if current <= 1 || seen[current]

            seen[current] = true
            current = parent_pid(current)
          end
          false
        rescue ArgumentError, TypeError
          false
        end

        def parent_pid(pid)
          path = "/proc/#{Integer(pid)}/status"
          bytes = File.binread(path, 64 * 1024)
          match = bytes.match(/^PPid:\s+([0-9]+)$/)
          protocol_failure! unless match
          Integer(match[1], 10)
        rescue SystemCallError, ArgumentError, TypeError
          protocol_failure!
        end

        def validate_request!(request)
          @mutex.synchronize do
            protocol_failure! unless
              request.session == @session &&
                request.case_id == @case_id &&
                request.generation == @generation &&
                request.scenario_request_sha256 ==
                  @scenario_request_sha256 &&
                @failure.nil?
            if @calls.length >= MAX_CALLS
              raise Failure.new(
                reason: "session_budget_exhausted",
                retryable: false
              )
            end
          end
        end

        def process_request(request)
          result = @transport.call(
            prompt: request.prompt,
            kind: request.kind,
            timeout_seconds: remaining_timeout
          )
          canonical =
            QualificationProviderProtocol.canonical_content(
              result.content,
              kind: request.kind
            )
          output_digest =
            Digest::SHA256.hexdigest(canonical)
          write_output!(request.output_ref, canonical, output_digest)
          response =
            QualificationProviderProtocol.build_ok_response(
              request: request,
              output_sha256: output_digest
            )
          call = {
            "request_id" => request.request_id,
            "request_sha256" => request.sha256,
            "kind" => request.kind,
            "prompt_sha256" =>
              Digest::SHA256.hexdigest(request.prompt),
            "context_refs_sha256" =>
              digest("provider-context-refs", request.context_refs),
            "output_ref" => request.output_ref,
            "content_sha256" =>
              Digest::SHA256.hexdigest(result.content),
            "output_sha256" => output_digest,
            "input_tokens" => result.input_tokens,
            "output_tokens" => result.output_tokens,
            "response_sha256" => response.sha256
          }
          protocol_failure! unless call.keys.sort == CALL_KEYS
          @mutex.synchronize { @calls << immutable(call) }
          response
        end

        def write_output!(relative, bytes, expected_digest)
          case_root = File.join(
            @workspace, "cases", @case_id
          )
          directory = Hive::ManagedDirectory.new(
            root: case_root,
            anchor: @workspace,
            label: "patrol qualification provider output"
          )
          directory.atomic_write(
            relative,
            bytes,
            mode: 0o600,
            expected_absent: true
          )
          snapshot = directory.read_with_metadata(
            relative,
            max_bytes:
              QualificationProviderProtocol::MAX_FRAME_BYTES
          )
          protocol_failure! unless
            snapshot.fetch(:mode) == 0o600 &&
              Digest::SHA256.hexdigest(
                snapshot.fetch(:bytes)
              ) == expected_digest
        rescue KeyError
          protocol_failure!
        end

        def verify_outputs!
          rows = @mutex.synchronize { @calls.dup }
          directory = Hive::ManagedDirectory.new(
            root: File.join(
              @workspace, "cases", @case_id
            ),
            anchor: @workspace,
            label: "patrol qualification provider output"
          )
          rows.each do |row|
            snapshot = directory.read_with_metadata(
              row.fetch("output_ref"),
              max_bytes:
                QualificationProviderProtocol::MAX_FRAME_BYTES
            )
            protocol_failure! unless
              snapshot.fetch(:mode) == 0o600 &&
                Digest::SHA256.hexdigest(
                  snapshot.fetch(:bytes)
                ) == row.fetch("output_sha256")
          end
          true
        rescue KeyError
          protocol_failure!
        end

        def record_failure(request:, phase:, reason:, retryable:)
          row = {
            "request_id" => request&.request_id,
            "request_sha256" => request&.sha256,
            "phase" => phase.to_s,
            "reason" => reason.to_s,
            "retryable" => retryable == true
          }
          unless
            row.keys.sort == FAILURE_KEYS &&
              FAILURE_PHASES.include?(row.fetch("phase")) &&
              QualificationProviderProtocol::ERROR_REASONS
                .include?(row.fetch("reason"))
            row = {
              "request_id" => nil,
              "request_sha256" => nil,
              "phase" => "server",
              "reason" => "session_protocol_violation",
              "retryable" => false
            }
          end
          @mutex.synchronize do
            @failure ||= immutable(row)
          end
        rescue Hive::ConfigError
          @mutex.synchronize do
            @failure ||= {
              "request_id" => nil,
              "request_sha256" => nil,
              "phase" => "server",
              "reason" => "session_protocol_violation",
              "retryable" => false
            }.freeze
          end
        end

        def record_protocol_failure
          record_failure(
            request: nil,
            phase: "server",
            reason: "session_protocol_violation",
            retryable: false
          )
        end

        def write_error(client, request, reason)
          return unless
            request &&
              QualificationProviderProtocol::ERROR_REASONS
                .include?(reason.to_s)

          response =
            QualificationProviderProtocol.build_error_response(
              request_id: request.request_id,
              reason: reason
            )
          write_frame(
            client,
            QualificationProviderProtocol.canonical(
              response.to_h
            )
          )
        rescue Hive::ConfigError, IOError, SystemCallError
          nil
        end

        def read_frame(io)
          header = read_exact(io, 4)
          length = header.unpack1("N")
          protocol_failure! unless
            length.positive? &&
              length <=
                QualificationProviderProtocol::MAX_FRAME_BYTES
          read_exact(io, length)
        end

        def read_exact(io, length)
          bytes = +"".b
          while bytes.bytesize < length
            wait_io!(io, readable: true)
            chunk = io.read_nonblock(
              length - bytes.bytesize,
              exception: false
            )
            protocol_failure! if chunk.nil?
            next if chunk == :wait_readable
            bytes << chunk
          end
          bytes.freeze
        end

        def write_frame(io, bytes)
          frame = [ bytes.bytesize ].pack("N") + bytes
          offset = 0
          while offset < frame.bytesize
            wait_io!(io, readable: false)
            written = io.write_nonblock(
              frame.byteslice(offset..),
              exception: false
            )
            next if written == :wait_writable
            protocol_failure! unless
              written.is_a?(Integer) && written.positive?
            offset += written
          end
          true
        end

        def wait_io!(io, readable:)
          loop do
            remaining = remaining_timeout
            lists = readable ?
              [ [ io ], nil ] : [ nil, [ io ] ]
            ready = IO.select(
              lists.fetch(0), lists.fetch(1), nil,
              [ remaining, IO_POLL_SECONDS ].min
            )
            return true if ready
          end
        end

        def remaining_timeout
          remaining = @deadline - monotonic_now
          if remaining <= 0
            raise QualificationOpenRouterTransport::Failure.new(
              reason: "provider_timeout",
              retryable: true
            )
          end
          [
            remaining,
            QualificationOpenRouterTransport::MAX_TIMEOUT_SECONDS
          ].min
        end

        def monotonic_now
          value = Float(@monotonic.call)
          protocol_failure! unless value.finite?
          value
        rescue ArgumentError, TypeError
          protocol_failure!
        end

        def unlink_socket!
          return unless @socket_path
          stat = File.lstat(@socket_path)
          protocol_failure! unless stat.socket? &&
                                   !stat.symlink? &&
                                   stat.uid == Process.euid
          File.unlink(@socket_path)
          begin
            File.lstat(@socket_path)
          rescue Errno::ENOENT
            return true
          end
          protocol_failure!
        rescue Errno::ENOENT
          true
        end

        def cleanup_root
          return unless
            @root &&
              @workspace &&
              @root.start_with?(
                File.join(@workspace, ".provider") +
                  File::SEPARATOR
              )
          return unless File.directory?(@root) &&
                        !File.symlink?(@root)

          FileUtils.remove_entry_secure(@root)
          parent = File.dirname(@root)
          Dir.rmdir(parent) if
            File.directory?(parent) &&
              !File.symlink?(parent) &&
              Dir.empty?(parent)
        rescue SystemCallError, ArgumentError
          nil
        end

        def protocol_failure!
          raise Failure.new(
            reason: "session_protocol_violation",
            retryable: false
          )
        end

        def malformed!
          raise Hive::ConfigError,
                "patrol qualification provider broker is malformed"
        end

        def canonical(value)
          Hive::WorkflowPackage::CanonicalJSON.generate(value)
        end

        def digest(domain, value)
          Digest::SHA256.hexdigest(
            "#{domain}\0#{canonical(value)}"
          )
        end

        def immutable(value)
          case value
          when Hash
            value.to_h do |key, child|
              [ key.to_s.freeze, immutable(child) ]
            end.freeze
          when Array
            value.map { |child| immutable(child) }.freeze
          when String
            value.dup.freeze
          when Integer, TrueClass, FalseClass, NilClass
            value
          else
            protocol_failure!
          end
        end
      end
    end
  end
end
