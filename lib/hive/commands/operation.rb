# frozen_string_literal: true

require "hive/cli_usage_contracts"
require "hive/schemas"
require "json"
require "uri"

module Hive
  module Commands
    class Operation
      include Hive::Schemas::EnvelopeEmitter

      def initialize(id, project:, json: false, client: nil, stdout: $stdout)
        @id, @project, @json, @client, @stdout = id, project, json, client, stdout
      end

      def call
        call_with_envelope do
          raise Hive::UsageError, "operation lookup requires --context <remote>; use hive receipt for local commands" unless @client
          unless @id.to_s.match?(/\A[0-9a-f-]{36}\z/) && @project.to_s.match?(/\A[A-Za-z0-9_.-]{1,128}\z/) && !%w[. ..].include?(@project)
            raise Hive::UsageError, "operation requires a durable operation ID and --project PROJECT"
          end
          result = @client.get("/projects/#{URI.encode_www_form_component(@project)}/operations/#{@id}")
          document = { "schema" => envelope_schema,
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(envelope_schema), "ok" => true,
            "instance_id" => result.fetch("instance_id"), "data" => result.fetch("data") }
          @stdout.puts(@json ? JSON.generate(document) : JSON.pretty_generate(document.fetch("data")))
          @stdout_written = true if @json
          document
        end
      end

      def envelope_schema = "hive-operation"
      def envelope_error_kind(error) = error.is_a?(Hive::UsageError) ? "usage" : "remote"

      def emit_envelope(error)
        @stdout.puts(JSON.generate(envelope_payload_for(error)))
        @stdout_written = true
      end
    end
  end
end

Hive::CliUsageContracts.declare("operation", { schema: "hive-operation", error_kind: "usage" })
