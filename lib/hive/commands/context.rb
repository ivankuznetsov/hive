# frozen_string_literal: true

require "hive/connection_contexts"
require "hive/schemas"
require "json"

module Hive
  module Commands
    # The launcher registers this boundary when its remote transport is loaded.
    class Context
      include Hive::Schemas::EnvelopeEmitter

      def initialize(action, name = nil, url: nil, token_stdin: false, json: false,
                     contexts: Hive::ConnectionContexts.new, stdin: $stdin, stdout: $stdout)
        @action, @name, @url, @token_stdin = action.to_s, name, url, token_stdin
        @json, @contexts, @stdin, @stdout = json, contexts, stdin, stdout
      end

      def call
        call_with_envelope do
          validate_options!
          data = case @action
          when "add"
            @contexts.add(@name, url: @url, token_reader: -> { @stdin.read(4098) })
          when "list" then @contexts.list
          when "show" then @contexts.show(@name)
          when "use" then @contexts.use(@name)
          else raise Hive::UsageError, "expected context add, list, use, or show"
          end
          payload = { "schema" => envelope_schema,
                      "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(envelope_schema),
                      "ok" => true, "action" => @action, "data" => data }
          if @json
            @stdout.puts(JSON.generate(payload))
            @stdout_written = true
          else
            Array(data.is_a?(Array) ? data : [ data ]).each { |context| print_context(context) }
          end
          payload
        end
      end

      def envelope_schema = "hive-context"
      def envelope_error_kind(error)
        case error
        when Hive::ConfigError then "config"
        when Hive::UsageError then "usage"
        else "internal"
        end
      end

      def emit_envelope(error)
        @stdout.puts(JSON.generate(envelope_payload_for(error)))
        @stdout_written = true
      rescue Errno::EPIPE
        @stdout_written = true
      end

      private

      def validate_options!
        unless %w[add list use show].include?(@action)
          raise Hive::UsageError, "expected context add, list, use, or show"
        end
        if %w[add use].include?(@action) && @name.to_s.empty?
          raise Hive::UsageError, "context #{@action} requires NAME"
        end
        if @action == "list" && @name
          raise Hive::UsageError, "context list takes no NAME"
        end
        if @action == "add"
          raise Hive::UsageError, "context add requires --url and --token-stdin" if !@url || !@token_stdin
        elsif @url || @token_stdin
          raise Hive::UsageError, "--url and --token-stdin are only valid with context add"
        end
      end

      def print_context(context)
        selected = context["selected"] ? " *" : ""
        @stdout.puts("#{context.fetch('name')}#{selected}: #{context.fetch('url', 'local installation')}")
        @stdout.puts("  installation: #{context['instance_id']}") if context["instance_id"]
        authority = context["authority"]
        return unless authority

        if context.fetch("type") == "local"
          @stdout.puts("  authority: unrestricted local operator")
        else
          @stdout.puts("  token: #{authority['id']}; scopes: #{Array(authority['scopes']).join(', ')}")
          @stdout.puts("  projects: #{authority['all_projects'] ? 'all projects' : Array(authority['projects']).join(', ')}")
          @stdout.puts("  expires: #{authority['expires_at'] || 'never'}")
        end
      end
    end
  end
end

require "hive/cli_usage_contracts"
Hive::CliUsageContracts.declare("context", { schema: "hive-context", error_kind: "usage" })
