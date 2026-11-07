# frozen_string_literal: true

require "stringio"
require "logger"
require "hive/remote/protocol"

module Hive
  module Remote
    # This boundary precedes Rails parameter parsing and request logging. The
    # ordinary Rails request log includes client addresses and arbitrary query
    # values; API requests instead produce one fixed-field audit entry.
    class RequestBoundary
      class Body
        def initialize(body, logger)
          @body, @logger = body, logger
        end

        def each(&block)
          @logger.silence(Logger::FATAL) { @body.each(&block) }
        end

        def close
          @logger.silence(Logger::FATAL) { @body.close if @body.respond_to?(:close) }
        end
      end

      def initialize(app, logger: nil)
        @app = app
        @logger = logger
      end

      def call(env)
        path = env.fetch("PATH_INFO", "")
        return @app.call(env) unless path == "/api" || path.start_with?("/api/")

        logger = @logger || Rails.logger
        env["hive.remote.audit"] = { "token_id" => "unknown", "project" => nil,
                                     "operation" => "api.request", "outcome" => "unavailable" }
        response = logger.silence(Logger::FATAL) { process(env) }
        logger.info(JSON.generate(env.fetch("hive.remote.audit")))
        [response[0], response[1], Body.new(response[2], logger)]
      end

      private

      def process(env)
        mutation = !%w[GET HEAD OPTIONS].include?(env["REQUEST_METHOD"])
        if (code = Protocol.interlock(mutation: mutation))
          env.fetch("hive.remote.audit")["outcome"] = code
          return json_response(503, Protocol.unavailable)
        end
        if mutation
          length = Integer(env.fetch("CONTENT_LENGTH", "0"), exception: false)
          if length && length > Protocol::MAX_MUTATION_BYTES
            env.fetch("hive.remote.audit")["outcome"] = "body_too_large"
            return json_response(413, Protocol.error("too_large", "mutation body exceeds 256 KiB"))
          end
          input = env["rack.input"]
          raw = input&.read(Protocol::MAX_MUTATION_BYTES + 1).to_s
          if raw.bytesize > Protocol::MAX_MUTATION_BYTES
            env.fetch("hive.remote.audit")["outcome"] = "body_too_large"
            return json_response(413, Protocol.error("too_large", "mutation body exceeds 256 KiB"))
          end
          env["rack.input"] = StringIO.new(raw)
          env["CONTENT_LENGTH"] = raw.bytesize.to_s
          unless env.fetch("CONTENT_TYPE", "").split(";", 2).first == "application/json"
            env.fetch("hive.remote.audit")["outcome"] = "malformed_input"
            return json_response(400, Protocol.error("malformed_input", "JSON object input is required"))
          end
          begin
            data = JSON.parse(raw)
          rescue JSON::ParserError
            data = nil
          end
          unless data.is_a?(Hash)
            env.fetch("hive.remote.audit")["outcome"] = "malformed_input"
            return json_response(400, Protocol.error("malformed_input", "JSON object input is required"))
          end
          env["action_dispatch.request.request_parameters"] = data
        end
        @app.call(env)
      rescue ActionDispatch::Http::Parameters::ParseError
        env.fetch("hive.remote.audit")["outcome"] = "malformed_input"
        json_response(400, Protocol.error("malformed_input", "invalid JSON request"))
      end

      def json_response(status, payload)
        body = JSON.generate(payload)
        [status, { "content-type" => "application/json", "content-length" => body.bytesize.to_s }, [body]]
      end
    end
  end
end
