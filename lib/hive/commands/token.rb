# frozen_string_literal: true

require "json"
require "hive/remote/token_store"
require "hive/remote/protocol"
require "hive/cli_usage_contracts"

module Hive
  module Commands
    class Token
      include Hive::Schemas::EnvelopeEmitter

      def initialize(operation = "list", id = nil, scopes: nil, projects: nil,
                     all_projects: false, name: "personal", expires_at: nil, json: false,
                     store: Hive::Remote::TokenStore.new)
        @operation, @id, @scopes, @projects = operation, id, scopes, projects
        @all_projects, @name, @expires_at, @json, @store = all_projects, name, expires_at, json, store
      end

      def envelope_schema = "hive-token"
      def envelope_error_kind(error) = error.is_a?(Hive::ConfigError) ? "config" : "usage"

      def call
        call_with_envelope do
          raise Hive::UsageError, "only token revoke accepts a public ID" if @id && @operation != "revoke"
          result = case @operation
          when "create"
            raise Hive::UsageError, "--scopes is required (read,create,act,answer)" if @scopes.nil?
            { "token" => @store.create(name: @name, scopes: split(@scopes), projects: split(@projects),
                                        all_projects: @all_projects, expires_at: @expires_at) }
          when "list" then { "tokens" => @store.list }
          when "revoke"
            raise Hive::UsageError, "token public ID is required" if @id.to_s.empty?
            { "token" => @store.revoke(@id) }
          else raise Hive::UsageError, "use token create, list, or revoke ID"
          end
          reason = Hive::Remote::Protocol.interlock(mutation: true, local_configuration: true)
          payload = {
            "schema" => envelope_schema,
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(envelope_schema),
            "ok" => true, "operation" => @operation,
            "interlock" => { "available" => reason.nil?, "code" => reason }
          }.merge(result)
          if @json
            puts JSON.generate(payload)
            @stdout_written = true
          else
            puts "API: #{reason || 'available'}"
            rows = result.key?("tokens") ? result.fetch("tokens") : [result.fetch("token")]
            rows.each do |row|
              projects = row.fetch("all_projects") ? "all projects" : row.fetch("projects").map { |grant| grant.fetch("name") }.join(",")
              puts "#{row.fetch('id')} #{row.fetch('name')} scopes=#{row.fetch('scopes').join(',')} projects=#{projects} revoked=#{row.fetch('revoked')}"
              puts row.fetch("token") if row.key?("token")
            end
          end
          payload
        end
      end

      private

      def split(value)
        value.is_a?(Array) ? value : value.to_s.split(",").map(&:strip).reject(&:empty?)
      end
    end
  end
end

Hive::CliUsageContracts.declare("token", { schema: "hive-token", error_kind: "usage" })
