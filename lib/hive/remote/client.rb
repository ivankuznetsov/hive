# frozen_string_literal: true

require "hive/remote/contract"

require "hive/errors"
require "json"
require "shellwords"
require "net/http"
require "openssl"
require "uri"

module Hive
  module Remote
    # Native HTTPS transport. Only fixed diagnostics cross this boundary: HTTP
    # exceptions, response bodies and redirect locations may contain secrets.
    class Client
      MAX_RESPONSE_BYTES = Contract::MAX_RESPONSE_BYTES
      MAX_MUTATION_BYTES = Contract::MAX_MUTATION_BYTES
      SCOPES = Contract::SCOPES

      class Failure < Hive::Error
        attr_reader :code, :status, :retry_binding

        def initialize(message, code: "transport", status: 0, retry_binding: nil)
          @code, @status = code, status
          @retry_binding = retry_binding
          super(message)
        end

        def exit_code = Hive::ExitCodes::UNAVAILABLE
      end

      class UnsupportedVersion < Failure
        def initialize(paths = [])
          served = Array(paths).select { |path| path.is_a?(String) && path.match?(%r{\A/api/v[0-9]{1,6}\z}) }.uniq.first(10)
          guidance = served.empty? ? "" : "; server serves #{served.join(', ')}"
          super("unsupported remote API version#{guidance}; upgrade Hive or select a compatible server",
            code: "unsupported_version", status: 404)
        end

        def exit_code = Hive::ExitCodes::CONFIG
      end

      class UnknownSubmission < Failure
        attr_reader :key, :target

        def initialize(key:, target:)
          @key, @target = key, target
          super("UNKNOWN SUBMISSION OUTCOME: target=#{target} idempotency_key=#{key}; retry the identical request with this key",
            code: "unknown_submission_outcome")
        end

        def exit_code = Hive::ExitCodes::TEMPFAIL
      end

      SAFE_ERRORS = {
        "invalid_token" => "remote token is invalid, expired or revoked",
        "insufficient_scope" => "remote token lacks the required scope",
        "not_found" => "remote resource is unavailable or inaccessible",
        "malformed_input" => "remote server rejected the request input",
        "conflict" => "idempotency key conflicts with an existing request",
        "in_progress" => "an identical remote operation is still in progress",
        "unresolved" => "the original remote operation has unresolved effects",
        "stale" => "remote task changed; refresh its observation or question inventory",
        "too_large" => "remote input or response exceeds the size limit",
        "validation" => "remote operation could not be completed; inspect the task or advance it locally",
        "unavailable" => "remote API is unavailable",
        "dispatcher_unavailable" => "daemon dispatch is disabled for the project; no remote dispatcher is available"
      }.freeze

      def initialize(context:, bearer:, connect_timeout: 5, read_timeout: 15,
                     max_response_bytes: MAX_RESPONSE_BYTES, ca_file: ENV["SSL_CERT_FILE"])
        @context = context.transform_values { |value| value.is_a?(String) ? value.dup.freeze : value }.freeze
        @bearer = bearer.to_s.dup.freeze
        @base = URI.parse(@context.fetch("url"))
        unless @base.is_a?(URI::HTTPS) && @base.host && !@base.userinfo && !@base.query && !@base.fragment
          raise Hive::UsageError, "remote context requires an HTTPS installation URL"
        end
        if @bearer.empty? || @bearer.bytesize > 4096 || @bearer.match?(/\s/)
          raise Hive::ConfigError, "remote context credentials are invalid; add the context again"
        end
        @connect_timeout, @read_timeout = connect_timeout, read_timeout
        @max_response_bytes, @ca_file = max_response_bytes, ca_file
      rescue URI::InvalidURIError, KeyError
        raise Hive::ConfigError, "remote context URL is invalid; add the context again"
      end

      def context
        response = get("/context")
        data = response.fetch("data")
        protocol_error! unless data.is_a?(Hash)
        raise UnsupportedVersion unless data["api_version"] == "v1"

        protocol_error! unless data["instance_id"] == response["instance_id"]
        verify_identity!(data["instance_id"])
        token = data["token"]
        valid = token.is_a?(Hash) && printable?(token["id"], 128) &&
          token["scopes"].is_a?(Array) && (token["scopes"] - SCOPES).empty? &&
          token["projects"].is_a?(Array) && token["projects"].all? { |name| project_name?(name) } &&
          [ true, false ].include?(token["all_projects"]) &&
          (token["expires_at"].nil? || printable?(token["expires_at"], 128))
        protocol_error! unless valid

        { "instance_id" => data.fetch("instance_id"), "api_version" => "v1",
          "token" => token.slice("id", "scopes", "projects", "all_projects", "expires_at") }
      end

      def get(path, query: {})
        request("GET", path, query: query)
      end

      def mutate(path, payload, key:, target:, stderr: $stderr)
        unless key.is_a?(String) && key.valid_encoding? && key.bytesize.between?(1, 512) && !key.match?(/[[:cntrl:]]/)
          raise Hive::UsageError, "idempotency key must contain 1 to 512 printable UTF-8 bytes"
        end
        key = key.dup.freeze
        target = safe_text(target)
        body = JSON.generate(payload)
        raise Hive::UsageError, "remote mutation exceeds 256 KiB" if body.bytesize > MAX_MUTATION_BYTES

        authority = context.fetch("token")
        projects = authority.fetch("all_projects") ? "all" : authority.fetch("projects").join(",")
        stderr.puts("hive: context=#{safe_text(@context.fetch('name'))} url=#{safe_text(@base.to_s)} " \
          "installation=#{safe_text(@context.fetch('instance_id'))} scopes=#{authority.fetch('scopes').join(',')} " \
          "projects=#{safe_text(projects)} target=#{target} idempotency_key=#{key}")
        if path.end_with?("/approvals")
          replay = [ "--from", payload.fetch("stage"), "--generation", payload.fetch("generation"), "--idempotency-key", key ]
          stderr.puts("hive: approval replay #{Shellwords.join(replay)}")
        end
        stderr.flush
        begin
          request("POST", path, body: body, key: key)
        rescue Failure => error
          raise UnknownSubmission.new(key: key, target: target) if %w[transport protocol response_too_large].include?(error.code)

          if error.code == "dispatcher_unavailable" && (command = local_retry_command(target, payload, binding: error.retry_binding))
            raise Failure.new("#{error.message}. Run locally: #{command}", code: error.code, status: error.status)
          end

          raise
        end
      end

      private

      # Reconstruct guidance from validated caller inputs, never server prose.
      def local_retry_command(target, payload, binding: nil)
        project, slug = target.split(":", 2)
        return unless project_name?(project) && slug.is_a?(String) && slug.match?(Contract::TASK_ID)
        return unless payload["action_id"] == "workflow.retry" &&
          payload["observation"].is_a?(String) && payload["observation"].match?(Contract::GENERATION)

        # Numeric task IDs must use the server's canonical slug to satisfy the
        # local descriptor's exact target check. Accept only matching identity
        # fields from the closed command grammar, never arbitrary error prose.
        if binding && binding[0] == project && binding[2] == payload["observation"] &&
            (slug.match?(/\A\d+\z/) || slug == binding[1])
          slug = binding[1]
        elsif slug.match?(/\A\d+\z/)
          return
        end

        Shellwords.join([ "hive", "act", "workflow.retry", "#{project}:#{slug}",
          "--observation", payload["observation"], "--project", project, "--json" ])
      end

      def local_retry_binding(error)
        return unless error["code"] == "dispatcher_unavailable" && printable?(error["message"], 4096)
        command = error["message"].split("Run locally: ", 2)[1]
        return unless command
        argv = Shellwords.split(command)
        return unless argv.size == 9
        project, slug = argv[3].split(":", 2)
        return unless project_name?(project) && slug&.match?(Contract::TASK_ID) && argv[5].match?(Contract::GENERATION)
        return unless argv == [ "hive", "act", "workflow.retry", "#{project}:#{slug}",
          "--observation", argv[5], "--project", project, "--json" ]
        [ project, slug, argv[5] ]
      rescue ArgumentError
        nil
      end

      def request(method, path, query: {}, body: nil, key: nil)
        uri = @base.dup
        uri.path = "#{@base.path.delete_suffix('/')}/api/v1#{path}"
        uri.query = query.empty? ? nil : URI.encode_www_form(query)
        http = Net::HTTP.new(uri.hostname, uri.port, nil)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.verify_hostname = true
        http.ca_file = @ca_file if @ca_file
        http.open_timeout = @connect_timeout
        http.ssl_timeout = @connect_timeout
        http.read_timeout = @read_timeout
        http.write_timeout = @read_timeout
        http.max_retries = 0
        headers = { "Authorization" => "Bearer #{@bearer}", "Accept" => "application/json" }
        headers["Content-Type"] = "application/json" if body
        headers["Idempotency-Key"] = key if key
        outgoing = Net::HTTPGenericRequest.new(method, !body.nil?, true, uri.request_uri, headers)
        outgoing.body = body if body
        document = nil
        http.start do
          http.request(outgoing) do |response|
            status = response.code.to_i
            raise Failure.new("remote redirects are refused; verify the configured installation URL", code: "redirect", status: status) if status.between?(300, 399)
            unless response["content-type"].to_s.split(";", 2).first.to_s.downcase == "application/json"
              protocol_error!
            end
            bytes = +""
            length = Integer(response["content-length"].to_s, exception: false)
            response_too_large! if length && length > @max_response_bytes
            response.read_body do |part|
              bytes << part
              response_too_large! if bytes.bytesize > @max_response_bytes
            end
            document = parse(bytes, status)
          end
        end
        document
      rescue Failure
        raise
      rescue OpenSSL::SSL::SSLError
        raise Failure.new("could not establish a verified TLS connection to the remote installation")
      rescue StandardError
        raise Failure.new("could not complete the remote connection")
      end

      def parse(bytes, status)
        document = JSON.parse(bytes)
        unless document.is_a?(Hash) && document["schema"] == "hive-remote" && document["schema_version"] == 1 &&
            [ true, false ].include?(document["ok"]) && document.key?("instance_id")
          protocol_error!
        end
        if document["ok"] == false
          error = document["error"]
          protocol_error! unless error.is_a?(Hash) && error["code"].is_a?(String)
          if status == 404 && error["code"] == "unsupported_version"
            raise UnsupportedVersion.new(error["served_base_paths"])
          end
          message = SAFE_ERRORS.fetch(error["code"], "remote request failed")
          code = SAFE_ERRORS.key?(error["code"]) ? error["code"] : "remote_error"
          raise Failure.new(message, code: code, status: status, retry_binding: local_retry_binding(error))
        end
        protocol_error! unless status.between?(200, 299) && document["data"].is_a?(Hash)
        verify_identity!(document["instance_id"])
        document
      rescue JSON::ParserError, EncodingError
        protocol_error!
      end

      def verify_identity!(instance)
        protocol_error! unless printable?(instance, 256)
        if @context["instance_id"] && instance != @context.fetch("instance_id")
          raise Failure.new("remote installation identity changed; verify the server and add the context again", code: "instance_mismatch")
        end
      end

      def protocol_error! = raise(Failure.new("remote response has an incompatible or malformed protocol", code: "protocol"))
      def response_too_large! = raise(Failure.new("remote response exceeds the size limit", code: "response_too_large"))
      def printable?(value, maximum) = value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, maximum) && !value.match?(/[[:cntrl:]]/)
      def project_name?(value) = value.is_a?(String) && value.valid_encoding? && value.match?(Contract::PROJECT_NAME) && !%w[. ..].include?(value)
      def safe_text(value) = value.to_s.gsub(/[[:cntrl:]]/, "?")
    end
  end
end
