require "digest"
require "socket"
require "hive/errors"
require "hive/modules/migration/qualification_provider_protocol"

module Hive
  module Modules
    module Migration
      # Candidate-side endpoint for one host-owned provider capability. Only a
      # generation-specific session token and fixed virtual socket are visible;
      # provider identity, endpoint, model, and credentials remain host-side.
      class QualificationProviderClient
        SOCKET_ENV =
          "HIVE_QUALIFICATION_PROVIDER_SOCKET".freeze
        SESSION_ENV =
          "HIVE_QUALIFICATION_PROVIDER_SESSION".freeze
        CASE_ENV =
          "HIVE_QUALIFICATION_CASE_ID".freeze
        GENERATION_ENV =
          "HIVE_QUALIFICATION_GENERATION".freeze
        REQUEST_SHA_ENV =
          "HIVE_QUALIFICATION_REQUEST_SHA256".freeze
        SOCKET =
          "/qualification/provider/broker.sock".freeze

        Result = Data.define(
          :output_ref, :output_sha256, :receipt_sha256
        )

        def self.from_environment(environment = ENV)
          names = [
            SOCKET_ENV, SESSION_ENV, CASE_ENV,
            GENERATION_ENV, REQUEST_SHA_ENV
          ]
          values = names.to_h do |name|
            [ name, environment[name].to_s ]
          end
          return nil if values.values.all?(&:empty?)
          unavailable! if values.values.any?(&:empty?)

          new(
            socket_path: values.fetch(SOCKET_ENV),
            session: values.fetch(SESSION_ENV),
            case_id: values.fetch(CASE_ENV),
            generation: values.fetch(GENERATION_ENV),
            scenario_request_sha256:
              values.fetch(REQUEST_SHA_ENV)
          )
        end

        def self.unavailable!
          raise Hive::ConfigError,
                "patrol qualification provider broker is unavailable"
        end
        private_class_method :unavailable!

        def initialize(
          socket_path:, session:, case_id:, generation:,
          scenario_request_sha256:
        )
          @socket_path = socket_path.to_s
          @session = session.to_s
          @case_id = case_id.to_s
          @generation = Integer(generation)
          @scenario_request_sha256 =
            scenario_request_sha256.to_s
          unless
            @socket_path == SOCKET &&
              QualificationProviderProtocol::SESSION.match?(
                @session
              ) &&
              QualificationProviderProtocol::CASE_ID.match?(
                @case_id
              ) &&
              @generation.between?(1, 3) &&
              QualificationProviderProtocol::DIGEST.match?(
                @scenario_request_sha256
              )
            unavailable!
          end
        rescue ArgumentError, TypeError
          unavailable!
        end

        def call(kind:, prompt:, context_refs:, output_ref:)
          output_ref = relative_output_ref(output_ref)
          request =
            QualificationProviderProtocol.build_request(
              session: @session,
              case_id: @case_id,
              generation: @generation,
              scenario_request_sha256:
                @scenario_request_sha256,
              kind: kind,
              prompt: prompt,
              context_refs: context_refs,
              output_ref: output_ref
            )
          socket = UNIXSocket.new(@socket_path)
          QualificationProviderProtocol.write_frame(
            socket,
            QualificationProviderProtocol.canonical(
              request.to_h
            )
          )
          socket.shutdown(Socket::SHUT_WR)
          response =
            QualificationProviderProtocol.load_response(
              QualificationProviderProtocol.read_frame(socket),
              expected_request_id: request.request_id
            )
          unavailable! unless response.ok?
          verify_output!(response)
          Result.new(
            output_ref: response.output_ref,
            output_sha256: response.output_sha256,
            receipt_sha256: response.sha256
          ).freeze
        rescue Hive::ConfigError
          raise
        rescue IOError, SystemCallError
          unavailable!
        ensure
          socket&.close unless socket&.closed?
        end

        private

        def relative_output_ref(value)
          text = value.to_s
          prefix =
            "/qualification/cases/#{@case_id}/"
          return text.delete_prefix(prefix) if
            text.start_with?(prefix)

          text
        end

        def verify_output!(response)
          path = File.join(
            "/qualification/cases",
            @case_id,
            response.output_ref
          )
          stat = File.lstat(path)
          unless
            stat.file? &&
              !stat.symlink? &&
              stat.nlink == 1 &&
              stat.uid == Process.euid &&
              (stat.mode & 0o777) == 0o600 &&
              File.realpath(path) == path &&
              Digest::SHA256.file(path).hexdigest ==
                response.output_sha256
            unavailable!
          end
        rescue SystemCallError
          unavailable!
        end

        def unavailable!
          raise Hive::ConfigError,
                "patrol qualification provider broker is unavailable"
        end
      end
    end
  end
end
