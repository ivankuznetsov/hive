# frozen_string_literal: true

require "json"
require "hive/schemas"
require "hive/config"
require "hive/web/environment"
require "hive/command_operation"

module Hive
  module Remote
    module Protocol
      BASE_PATHS = ["/api/v1"].freeze
      MAX_MUTATION_BYTES = 256 * 1024
      MAX_RESPONSE_BYTES = 2 * 1024 * 1024

      module_function

      def envelope(instance_id: nil, data: nil, error: nil)
        result = {
          "schema" => "hive-remote",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-remote"),
          "ok" => error.nil?, "instance_id" => instance_id
        }
        result[error ? "error" : "data"] = error || data
        result
      end

      def error(code, message, instance_id: nil, **details)
        envelope(instance_id: instance_id, error: { "code" => code, "message" => message }.merge(details.transform_keys(&:to_s)))
      end

      def unavailable
        error("unavailable", "remote API is unavailable")
      end

      def interlock(mutation:, store: nil, local_configuration: false)
        config = Hive::Config.load_global_web
        return "api_unavailable_owner_blank" if config.dig("github", "owner").to_s.strip.empty?
        loopback = if local_configuration
          Hive::Web::Environment.local_loopback_mode?(bind: config.fetch("bind"), default: config.fetch("local_loopback", true))
        else
          Hive::Web::Environment.boolean("HIVE_WEB_LOCAL_LOOPBACK")
        end
        return "api_unavailable_loopback_bypass" if loopback
        if mutation && !Hive::CommandOperation.receipts_installed?(store || Hive::CommandReceiptStore.new)
          return "api_unavailable_receipts_absent"
        end
        nil
      rescue Hive::Error, SystemCallError
        "api_unavailable_configuration"
      end
    end
  end
end
