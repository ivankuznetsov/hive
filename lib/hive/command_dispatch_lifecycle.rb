# frozen_string_literal: true

require "hive/command_receipt_store"
require "hive/paths"
require "hive/runtime_control_plane/dispatch_repository"

module Hive
  # Shared durable caller lifecycle for Bot, foreground Attempts, and Daemon
  # delivery. Persisted dispatch context is the only source of principal,
  # receipt, request identity, ordinal, and retry horizon after a restart.
  class CommandDispatchLifecycle
    def initialize(repository: nil, store: nil, state_home: Hive::Paths.state_home)
      @repository = repository
      @state_home = state_home
      @store = store
    end

    def protect_context!(context)
      values = normalize_context(context)
      receipt = bound_receipt!(values)
      horizon = values.fetch("retry_horizon_expires_at").to_s
      if horizon.empty?
        raise Hive::UsageError,
              "keyed durable dispatch requires an absolute --retry-horizon-expires-at"
      end
      store.acquire_pin(
        receipt_id: receipt.fetch(:receipt_id), principal: values.fetch("principal"),
        intent_id: values.fetch("source_identity"),
        intent_generation: Integer(values.fetch("ordinal")),
        retry_horizon_expires_at: horizon,
        project_root: project_root_for(values.fetch("source_identity"))
      )
    end

    def protect_request!(request_id)
      _context, pin = context_and_pin!(request_id)
      pin
    end

    def allocate_successor!(predecessor_request_id:, intent_id:, intent_version:,
                            delivery_cycle_id:)
      context, = context_and_pin!(predecessor_request_id)
      receipt = bound_receipt!(context)
      store.allocate_successor(
        namespace_id: receipt.fetch(:namespace_id),
        principal: context.fetch("principal"), intent_id: intent_id,
        intent_version: intent_version,
        predecessor_receipt_id: receipt.fetch(:receipt_id),
        delivery_cycle_id: delivery_cycle_id,
        request_fingerprint: context.fetch("request_fingerprint"),
        project_root: project_root_for(predecessor_request_id)
      )
    end

    private

    def context_and_pin!(request_id)
      context = repository.command_context(request_id)
      unless context
        raise Hive::CommandUnresolved.new(
          message: "predecessor dispatch has no durable command context"
        )
      end
      [ normalize_context(context), protect_context!(context) ]
    end

    def bound_receipt!(context)
      receipt = store.receipt(context.fetch("receipt_id"))
      unless receipt && receipt.fetch(:principal) == context.fetch("principal") &&
             receipt.fetch(:request_fingerprint) == context.fetch("request_fingerprint")
        raise Hive::CommandConflict, "predecessor command context changed"
      end
      effect = store.database.read do |connection|
        connection[:command_effects][
          effect_id: context.fetch("effect_id"), receipt_id: receipt.fetch(:receipt_id)
        ]
      end
      raise Hive::CommandConflict, "predecessor command effect context changed" unless effect
      receipt
    end

    def normalize_context(context)
      source = context.respond_to?(:to_h) ? context.to_h : context
      values = source.transform_keys(&:to_s)
      values["source_identity"] ||= values["transport_request_id"]
      required = %w[
        receipt_id effect_id principal principal_source ordinal receipt_generation
        request_fingerprint source_identity retry_horizon_expires_at
      ]
      missing = required.select { |key| values[key].nil? || values[key].to_s.empty? }
      unless missing.empty?
        raise Hive::CommandUnresolved.new(
          message: "durable command context is missing #{missing.join(', ')}"
        )
      end
      values
    end

    def project_root_for(request_id)
      request = repository.fetch(request_id)
      project_name = request&.project
      configured = project_name && Hive::Config.find_project(project_name)
      return configured.fetch("path") if configured

      row = project_name && store.database.read do |connection|
        connection[:projects][name: project_name]
      end
      path = row && row[:observed_path]
      if path.to_s.empty? || path == "__global__"
        raise Hive::ConfigError, "keyed dispatch project identity is unavailable"
      end
      path
    end

    def repository
      @repository ||= Hive::RuntimeControlPlane::DispatchRepository.open_default(
        state_home: @state_home
      )
    end

    def store
      @store ||= Hive::CommandReceiptStore.new(database: repository.database)
    end
  end
end
