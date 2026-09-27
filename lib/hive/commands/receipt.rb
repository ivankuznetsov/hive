# frozen_string_literal: true

require "digest"
require "json"
require "hive/command_operation"
require "hive/command_receipt_maintenance"
require "hive/command_receipt_pruner"
require "hive/config"
require "hive/schemas"

module Hive
  module Commands
    class Receipt
      include Hive::Schemas::EnvelopeEmitter

      def initialize(subcommand, identifier = nil, project: nil, namespace_id: nil,
                     expected_generation: nil, confirm: false, limit: nil, cursor: nil,
                     idempotency_key: nil, settle_without_result: false,
                     orphaned_owner: false, evidence: nil, force: false, reason: nil,
                     new_identity: false, previous_identity: nil,
                     json: false, pruner: nil, maintenance: nil,
                     command_receipt_store: nil, authority: nil)
        @subcommand = subcommand.to_s
        @identifier = identifier
        @project = project
        @namespace_id = namespace_id
        @expected_generation = expected_generation
        @confirm = confirm
        @limit = limit
        @cursor = cursor
        @idempotency_key = idempotency_key
        @settle_without_result = settle_without_result
        @orphaned_owner = orphaned_owner
        @evidence_path = evidence
        @force = force
        @reason = reason
        @new_identity = new_identity
        @previous_identity = previous_identity
        @json = json
        @pruner = pruner
        @maintenance = maintenance
        @command_receipt_store = command_receipt_store
        @authority = authority
      end

      def call
        call_with_envelope do
          payload = if @subcommand == "prune" && @idempotency_key && @confirm
            raise Hive::UsageError, "keyed prune requires --project" unless project_root
            command_operation.call { execute }
          else
            reject_forbidden_key!
            execute
          end
          emit(payload)
          payload
        end
      end

      def envelope_schema
        @subcommand == "prune" ? "hive-receipt-prune" : "hive-command-receipt"
      end

      def envelope_error_kind(error)
        case error
        when Hive::CommandOutcomeError then error.reason
        when Hive::CommandCapacityError then error.reason
        when Hive::UsageError then "usage"
        when Hive::ConfigError then "config"
        else "internal"
        end
      end

      def envelope_serialization_failure_policy = :raise
      def envelope_enabled? = @json

      private

      def execute
        validate_subcommand_options!
        case @subcommand
        when "prune" then execute_prune
        when "retire" then execute_retire
        when "release-pin" then maintenance.release_pin(
          required_identifier!, expected_generation: @expected_generation,
          reason: @reason, confirm: @confirm, force: @force, namespace_id: selected_namespace_id
        )
        when "abandon-batch" then maintenance.abandon_batch(
          required_identifier!, expected_generation: @expected_generation,
          reason: @reason, confirm: @confirm, namespace_id: selected_namespace_id
        )
        when "enroll"
          execute_enroll
        else
          raise Hive::UsageError,
                "unknown receipt subcommand #{@subcommand.inspect}; expected prune, retire, release-pin, abandon-batch, or enroll"
        end
      end

      def execute_prune
        if @confirm
          pruner.prune(project_root: project_root, namespace_id: @namespace_id, limit: @limit)
        else
          pruner.preview(
            project_root: project_root, namespace_id: @namespace_id,
            limit: @limit, cursor: @cursor
          )
        end
      end

      def execute_retire
        if @settle_without_result
          maintenance.settle_without_result(
            required_identifier!, expected_generation: @expected_generation,
            reason: @reason, confirm: @confirm, namespace_id: selected_namespace_id
          )
        elsif @orphaned_owner
          maintenance.orphaned_owner(
            required_identifier!, expected_generation: @expected_generation,
            reason: @reason, confirm: @confirm, namespace_id: selected_namespace_id
          )
        elsif @evidence_path
          maintenance.retire_with_evidence(
            required_identifier!, expected_generation: @expected_generation,
            evidence: read_evidence!, reason: @reason, confirm: @confirm,
            namespace_id: selected_namespace_id
          )
        else
          raise Hive::UsageError,
                "retire requires --evidence, --orphaned-owner, or --settle-without-result"
        end
      end

      def validate_subcommand_options!
        supplied = {
          "--settle-without-result" => @settle_without_result,
          "--orphaned-owner" => @orphaned_owner,
          "--evidence" => !@evidence_path.nil?,
          "--force" => @force,
          "--limit" => !@limit.nil?,
          "--cursor" => !@cursor.nil?,
          "--new-identity" => @new_identity,
          "--previous-identity" => !@previous_identity.nil?
        }.select { |_flag, present| present }.keys
        allowed = case @subcommand
        when "retire" then %w[--settle-without-result --orphaned-owner --evidence]
        when "release-pin" then %w[--force]
        when "prune" then @confirm ? %w[--limit] : %w[--limit --cursor]
        when "enroll" then %w[--new-identity --previous-identity]
        else []
        end
        ignored = supplied - allowed
        unless ignored.empty?
          raise Hive::UsageError, "#{ignored.join(', ')} not accepted by receipt #{@subcommand}"
        end
        if @subcommand == "retire" && (supplied & allowed).length != 1
          raise Hive::UsageError,
                "retire requires exactly one of --evidence, --orphaned-owner, or --settle-without-result"
        end
      end

      def execute_enroll
        raise Hive::UsageError, "enroll requires --project" unless project_root
        raise Hive::UsageError, "enroll requires --new-identity" unless @new_identity
        if @previous_identity.to_s.empty?
          raise Hive::UsageError, "enroll requires --previous-identity UUID"
        end
        Hive::ProjectIdentity.enroll_new_identity(
          project_root: project_root, database: receipt_store.database,
          previous_identity: @previous_identity,
          expected_generation: @expected_generation,
          confirm: @confirm, authority: authority
        )
      end

      def command_operation
        Hive::CommandOperation.new(
          key: @idempotency_key, command: "receipt", mode: "prune",
          target: @project.to_s,
          request: {
            "project" => @project, "namespace_id" => @namespace_id,
            "confirm" => @confirm, "limit" => @limit
          },
          project_root: project_root, json: true, structured: true,
          maintenance: true,
          failure_payload: ->(error) { envelope_payload_for(error) },
          store: receipt_store
        )
      end

      def reject_forbidden_key!
        return if @idempotency_key.nil?
        if @subcommand == "prune" && @confirm
          return
        end
        if @subcommand == "prune"
          raise Hive::UsageError, "--idempotency-key requires confirmed receipt prune"
        end
        raise Hive::UsageError, "--idempotency-key is supported only by hive receipt prune"
      end

      def project_root
        return @project_root if defined?(@project_root)
        return @project_root = nil unless @project
        entry = Hive::Config.find_project(@project)
        raise Hive::UsageError, "unknown project #{@project}" unless entry
        @project_root = entry.fetch("path")
      end

      def required_identifier!
        value = @identifier.to_s
        raise Hive::UsageError, "#{@subcommand} requires an identifier" if value.empty?
        value
      end

      def selected_namespace_id
        if @project && @namespace_id
          raise Hive::UsageError, "--project and --namespace-id are mutually exclusive"
        end
        return maintenance.authorize_namespace_selection!(@namespace_id) if @namespace_id
        return unless project_root
        identity = Hive::ProjectIdentity.resolve(
          project_root: project_root,
          database: receipt_store.database,
          create: false
        )
        raise Hive::ConfigError, "project has no command namespace" unless identity
        identity.namespace_id
      end

      def read_evidence!
        path = File.expand_path(@evidence_path)
        raw = File.read(path, 256 * 1024 + 1)
        raise Hive::UsageError, "receipt evidence exceeds 256 KiB" if raw.bytesize > 256 * 1024
        value = JSON.parse(raw)
        raise Hive::UsageError, "receipt evidence must be a JSON object" unless value.is_a?(Hash)
        value
      rescue JSON::ParserError, SystemCallError, IOError => error
        raise Hive::UsageError, "cannot read receipt evidence: #{error.message}"
      end

      def authority
        @authority ||= Hive::CommandMaintenanceAuthority.local(
          principal: Hive::CommandOperation.local_principal(receipt_store.database)
        )
      end
      def pruner = @pruner ||= Hive::CommandReceiptPruner.new(authority: authority)
      def maintenance = @maintenance ||= Hive::CommandReceiptMaintenance.new(authority: authority)
      def receipt_store
        @command_receipt_store ||= Hive::CommandReceiptStore.new(
          maintenance_authority: @authority
        )
      end

      def emit(payload)
        if @json
          puts JSON.generate(payload)
        else
          puts JSON.pretty_generate(payload)
        end
      end
    end
  end
end

require "hive/cli_usage_contracts"
Hive::CliUsageContracts.declare("receipt") do |argv, command_index:, option_argv:|
  subcommand = Hive::CliUsageContracts.subcommand(
    argv, command_index,
    value_options: %w[--project --namespace-id --expected-generation --limit --cursor --reason --evidence --idempotency-key --previous-identity]
  )
  schema = subcommand == "prune" ? "hive-receipt-prune" : "hive-command-receipt"
  { schema: schema, error_kind: "usage" }
end
