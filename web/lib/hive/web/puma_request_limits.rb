# frozen_string_literal: true

require "puma"
require "puma/null_io"
require "puma/client"

module Hive
  module Web
    module PumaRequestLimits
      module RejectChunkedBodies
        private

        # Puma 7's http_content_length_limit rejects declared lengths before
        # Rack, but its chunk decoder otherwise spools without an incremental
        # bound. Hive Web's browser forms always send Content-Length, so reject
        # chunked request bodies at the parsed-header boundary instead of
        # accepting an unbounded stream into Puma's tempfile.
        def setup_body
          transfer_encoding = @env[Puma::Const::TRANSFER_ENCODING2].to_s
          return super unless @http_content_length_limit && chunked?(transfer_encoding)

          @http_content_length_limit_exceeded = true
          # The unread chunk stream still belongs to this request. Force the
          # response connection closed so Puma cannot reset the client and
          # misinterpret any remaining chunks as a pipelined request.
          @env[Puma::Const::HTTP_CONNECTION] = Puma::Const::CLOSE
          @buffer = nil
          @body = Puma::Client::EmptyBody
          set_ready
          true
        end

        def chunked?(transfer_encoding)
          transfer_encoding.split(",").any? { |encoding| encoding.strip.casecmp?("chunked") }
        end
      end

      module_function

      def install!
        return if Puma::Client < RejectChunkedBodies

        Puma::Client.prepend(RejectChunkedBodies)
      end
    end
  end
end
