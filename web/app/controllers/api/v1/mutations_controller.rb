# frozen_string_literal: true

require "hive/remote/operation_projection"

module Api
  module V1
    class MutationsController < BaseController
      MAX_LIST_ITEMS = 64
      wrap_parameters false

      private

      def mutation_input!(allowed:, required:, string_list_fields: [])
        malformed! unless request.media_type == "application/json" && request.query_parameters.empty?
        input = request.request_parameters
        malformed! unless input.is_a?(Hash) && (input.keys - allowed - [ "idempotency_key" ]).empty?
        required.each { |field| malformed! unless input[field].is_a?(String) && !input[field].empty? }
        allowed.each do |field|
          value = input[field]
          if string_list_fields.include?(field) && value.is_a?(Array)
            if value.length > MAX_LIST_ITEMS
              raise Hive::Remote::Error.new(code: "too_large", status: 413, message: "mutation list exceeds the remote limit")
            end
            malformed! unless !value.empty? && value.all? { |entry| entry.is_a?(String) }
          else
            malformed! unless value.nil? || value.is_a?(String)
          end
        end
        body_key = input["idempotency_key"]
        header_key = request.headers["Idempotency-Key"]
        if header_key
          malformed! unless header_key.is_a?(String)
          header_key = header_key.dup.force_encoding(Encoding::UTF_8)
          malformed! unless header_key.valid_encoding?
        end
        malformed! if input.key?("idempotency_key") && !body_key.is_a?(String)
        malformed! if header_key && body_key && header_key != body_key
        key = header_key || body_key
        malformed! unless key.is_a?(String) && !key.empty?
        @idempotency_key = Hive::CommandMutations.normalize_key(key)
        input
      end

      def existing_operation(project)
        operation_projection.existing(project: project, key: @idempotency_key, principal: authority.principal)
      end

      def operation_projection
        @operation_projection ||= Hive::Remote::OperationProjection.new
      end

      def command_service
        @command_service ||= Hive::Remote::CommandService.new
      end

      def command_authority
        { idempotency_key: @idempotency_key, principal: authority.principal, scopes: authority.token.fetch("scopes") }
      end

      def render_acknowledgement(result, status: 200)
        data = Hive::Remote::Serializers.acknowledgement(result)
        Hive::Remote::Serializers.bound!(data, max_bytes: Hive::Remote::Protocol::MAX_RESPONSE_BYTES, instance_id: instance_id)
        render_data(data, status: data["queued"] ? 202 : status)
      end

      def malformed!
        raise Hive::Remote::Error.new(code: "malformed_input", status: 400, message: "invalid request")
      end
    end
  end
end
