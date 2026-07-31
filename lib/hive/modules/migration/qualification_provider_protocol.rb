require "digest"
require "json"
require "pathname"
require "hive/errors"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Secret-free candidate protocol for one host-owned provider session.
      # The session capability is useful only through a generation-specific
      # Unix socket; provider identity, transport, model, and credential never
      # enter the candidate process.
      class QualificationProviderProtocol
        REQUEST_SCHEMA =
          "hive-patrol-qualification-provider-request".freeze
        RESPONSE_SCHEMA =
          "hive-patrol-qualification-provider-response".freeze
        SCHEMA_VERSION = 1
        MAX_FRAME_BYTES = 192 * 1024
        MAX_PROMPT_BYTES = 128 * 1024
        MAX_CONTEXT_REFS = 8
        MAX_REF_BYTES = 1_024
        KINDS = {
          "ordinary_findings" => {
            basename: "findings.json",
            root_key: "findings"
          }.freeze,
          "architecture_theses" => {
            basename: "theses.json",
            root_key: "theses"
          }.freeze
        }.freeze
        REQUEST_KEYS = %w[
          case_id context_refs generation kind output_ref prompt request_id
          scenario_request_sha256 schema schema_version session
        ].freeze
        OK_RESPONSE_KEYS = %w[
          output_ref output_sha256 request_id response_sha256 schema
          schema_version status
        ].freeze
        ERROR_RESPONSE_KEYS = %w[
          reason request_id response_sha256 schema schema_version status
        ].freeze
        ERROR_REASONS = %w[
          provider_authentication_failed provider_credit_exhausted
          provider_rate_limited provider_response_malformed
          provider_timeout provider_transport_failed provider_unavailable
          session_budget_exhausted session_protocol_violation
        ].freeze
        REQUEST_ID = /\Aprovider-[0-9a-f]{64}\z/
        SESSION = /\Asession-[0-9a-f]{64}\z/
        DIGEST = /\A[0-9a-f]{64}\z/
        CASE_ID = /\A[a-z0-9][a-z0-9._-]{0,127}\z/

        Request = Data.define(:payload) do
          def to_h = payload
          def request_id = payload.fetch("request_id")
          def session = payload.fetch("session")
          def case_id = payload.fetch("case_id")
          def generation = payload.fetch("generation")
          def scenario_request_sha256 =
            payload.fetch("scenario_request_sha256")
          def kind = payload.fetch("kind")
          def prompt = payload.fetch("prompt")
          def context_refs = payload.fetch("context_refs")
          def output_ref = payload.fetch("output_ref")
          def sha256
            Digest::SHA256.hexdigest(
              QualificationProviderProtocol.canonical(payload)
            )
          end
        end

        Response = Data.define(:payload) do
          def to_h = payload
          def request_id = payload.fetch("request_id")
          def ok? = payload.fetch("status") == "ok"
          def reason = payload["reason"]
          def output_ref = payload["output_ref"]
          def output_sha256 = payload["output_sha256"]
          def sha256 = payload.fetch("response_sha256")
        end

        class << self
          def build_request(
            session:, case_id:, generation:,
            scenario_request_sha256:, kind:, prompt:,
            context_refs:, output_ref:
          )
            body = {
              "schema" => REQUEST_SCHEMA,
              "schema_version" => SCHEMA_VERSION,
              "session" => session.to_s,
              "case_id" => case_id.to_s,
              "generation" => generation,
              "scenario_request_sha256" =>
                scenario_request_sha256.to_s,
              "kind" => kind.to_s,
              "prompt" => prompt,
              "context_refs" => Array(context_refs),
              "output_ref" => output_ref.to_s
            }
            load_request(
              canonical(
                body.merge(
                  "request_id" =>
                    "provider-#{digest('provider-request', body)}"
                )
              )
            )
          end

          def load_request(bytes)
            value = parse_canonical(bytes)
            exact!(value, REQUEST_KEYS)
            malformed! unless
              value.fetch("schema") == REQUEST_SCHEMA &&
                value.fetch("schema_version") == SCHEMA_VERSION &&
                SESSION.match?(value.fetch("session").to_s) &&
                CASE_ID.match?(value.fetch("case_id").to_s) &&
                value.fetch("generation").is_a?(Integer) &&
                value.fetch("generation").between?(1, 3) &&
                DIGEST.match?(
                  value.fetch("scenario_request_sha256").to_s
                ) &&
                KINDS.key?(value.fetch("kind")) &&
                REQUEST_ID.match?(value.fetch("request_id").to_s)
            prompt = prompt_value(value.fetch("prompt"))
            refs = context_refs(value.fetch("context_refs"))
            output = output_ref(
              value.fetch("output_ref"),
              kind: value.fetch("kind")
            )
            body = value.merge(
              "prompt" => prompt,
              "context_refs" => refs,
              "output_ref" => output
            )
            expected =
              "provider-#{digest('provider-request', body.reject { |key, _| key == 'request_id' })}"
            malformed! unless value.fetch("request_id") == expected

            Request.new(payload: immutable(body)).freeze
          rescue KeyError, NoMethodError, TypeError
            malformed!
          end

          def build_ok_response(
            request:, output_sha256:
          )
            request = request_value(request)
            body = {
              "schema" => RESPONSE_SCHEMA,
              "schema_version" => SCHEMA_VERSION,
              "request_id" => request.request_id,
              "status" => "ok",
              "output_ref" => request.output_ref,
              "output_sha256" => output_sha256.to_s
            }
            load_response(
              canonical(
                body.merge(
                  "response_sha256" =>
                    digest("provider-response", body)
                )
              ),
              expected_request_id: request.request_id
            )
          end

          def build_error_response(request_id:, reason:)
            body = {
              "schema" => RESPONSE_SCHEMA,
              "schema_version" => SCHEMA_VERSION,
              "request_id" => request_id.to_s,
              "status" => "error",
              "reason" => reason.to_s
            }
            load_response(
              canonical(
                body.merge(
                  "response_sha256" =>
                    digest("provider-response", body)
                )
              ),
              expected_request_id: request_id
            )
          end

          def load_response(bytes, expected_request_id:)
            value = parse_canonical(bytes)
            status = value.fetch("status")
            keys =
              status == "ok" ?
                OK_RESPONSE_KEYS : ERROR_RESPONSE_KEYS
            exact!(value, keys)
            malformed! unless
              value.fetch("schema") == RESPONSE_SCHEMA &&
                value.fetch("schema_version") == SCHEMA_VERSION &&
                REQUEST_ID.match?(
                  value.fetch("request_id").to_s
                ) &&
                value.fetch("request_id") ==
                  expected_request_id.to_s
            if status == "ok"
              relative_ref(value.fetch("output_ref"))
              malformed! unless
                DIGEST.match?(
                  value.fetch("output_sha256").to_s
                )
            else
              malformed! unless
                status == "error" &&
                  ERROR_REASONS.include?(value.fetch("reason"))
            end
            body = value.reject do |key, _child|
              key == "response_sha256"
            end
            malformed! unless
              DIGEST.match?(
                value.fetch("response_sha256").to_s
              ) &&
                value.fetch("response_sha256") ==
                  digest("provider-response", body)

            Response.new(payload: immutable(value)).freeze
          rescue KeyError, NoMethodError, TypeError
            malformed!
          end

          def canonical_content(bytes, kind:)
            malformed! unless
              bytes.is_a?(String) &&
                bytes.bytesize.positive? &&
                bytes.bytesize <= MAX_FRAME_BYTES
            value = JSON.parse(bytes)
            malformed! unless
              value.is_a?(Hash) &&
                value.keys == [
                  KINDS.fetch(kind.to_s).fetch(:root_key)
                ] &&
                value.values.fetch(0).is_a?(Array)
            canonical(value).b.freeze
          rescue JSON::ParserError, EncodingError, KeyError
            malformed!
          end

          def write_frame(io, value)
            bytes = value.is_a?(String) ?
              value.b : canonical(value).b
            malformed! unless
              bytes.bytesize.positive? &&
                bytes.bytesize <= MAX_FRAME_BYTES
            io.write([ bytes.bytesize ].pack("N"))
            io.write(bytes)
            io.flush
            bytes.bytesize
          rescue IOError, SystemCallError
            malformed!
          end

          def read_frame(io)
            header = read_exact(io, 4)
            length = header.unpack1("N")
            malformed! unless
              length.positive? && length <= MAX_FRAME_BYTES
            read_exact(io, length).b.freeze
          rescue IOError, SystemCallError
            malformed!
          end

          def canonical(value)
            Hive::WorkflowPackage::CanonicalJSON.generate(value)
          end

          private

          def parse_canonical(bytes)
            malformed! unless
              bytes.is_a?(String) &&
                bytes.bytesize.positive? &&
                bytes.bytesize <= MAX_FRAME_BYTES
            value = JSON.parse(bytes)
            malformed! unless bytes == canonical(value)
            value
          rescue JSON::ParserError, EncodingError
            malformed!
          end

          def prompt_value(value)
            malformed! unless
              value.is_a?(String) &&
                !value.empty? &&
                value.bytesize <= MAX_PROMPT_BYTES &&
                value.valid_encoding?
            value.dup.freeze
          end

          def context_refs(value)
            malformed! unless
              value.is_a?(Array) &&
                value.length <= MAX_CONTEXT_REFS
            refs = value.map { |ref| relative_ref(ref) }
            malformed! unless
              refs.uniq.length == refs.length &&
                refs == refs.sort
            refs.freeze
          end

          def output_ref(value, kind:)
            ref = relative_ref(value)
            contract = KINDS.fetch(kind)
            malformed! unless
              File.basename(ref) == contract.fetch(:basename) &&
                ref.start_with?(
                  "sandbox/repository/.hive-state/"
                )
            ref
          end

          def relative_ref(value)
            text = value.to_s
            path = Pathname.new(text)
            malformed! unless
              value.is_a?(String) &&
                !text.empty? &&
                text.bytesize <= MAX_REF_BYTES &&
                !path.absolute? &&
                path.cleanpath.to_s == text &&
                !text.include?("\\") &&
                !text.include?("\0") &&
                text.split("/", -1).none? do |part|
                  part.empty? || part == "." || part == ".."
                end
            text.dup.freeze
          rescue ArgumentError
            malformed!
          end

          def request_value(value)
            return value if value.is_a?(Request)

            malformed!
          end

          def exact!(value, keys)
            malformed! unless
              value.is_a?(Hash) &&
                value.keys.all? { |key| key.is_a?(String) } &&
                value.keys.sort == keys.sort
          end

          def read_exact(io, length)
            bytes = +"".b
            while bytes.bytesize < length
              chunk = io.read(length - bytes.bytesize)
              malformed! unless chunk
              bytes << chunk
            end
            bytes
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
              malformed!
            end
          end

          def malformed!
            raise Hive::ConfigError,
                  "patrol qualification provider protocol is malformed"
          end
        end
      end
    end
  end
end
