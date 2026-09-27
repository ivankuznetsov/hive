# frozen_string_literal: true

require "digest"
require "json"
require "stringio"
require "thread"
require "securerandom"
require "hive/command_receipt_store"

module Hive
  # One caller receipt around one public command boundary. Keyed success is
  # buffered until the exact response has committed; unkeyed calls retain the
  # command's existing streaming behavior.
  class CommandOperation
    CAPTURE_MUTEX = Mutex.new
    Context = Data.define(
      :receipt_id, :effect_id, :principal, :principal_source, :ordinal,
      :request_fingerprint, :transport_request_id
    )

    def self.current_context = Thread.current[:hive_command_operation_context]

    def self.local_principal(database)
      unless Process.uid == Process.euid
        raise Hive::ConfigError,
              "keyed CLI execution requires matching real and effective user ids"
      end
      installation = database.installation_identity.fetch(:installation_id)
      "installation:#{installation}:uid:#{Process.uid}"
    end

    def initialize(key:, command:, target:, request:, project_root:, principal: nil,
                   principal_source: "local_cli", mode: nil, json: false,
                   structured: false, store: Hive::CommandReceiptStore.new)
      @key = key
      @command = command.to_s
      @target = target.to_s
      @request = request
      @project_root = project_root
      @store = store
      @principal = principal || self.class.local_principal(store.database)
      @principal_source = principal_source
      @mode = mode
      @json = json
      @structured = structured
    end

    def call
      return yield if @key.nil?

      if (existing = @store.lookup_existing(
        key: @key, command: @command, target: @target,
        request: @request, principal: @principal
      ))
        return replay(existing)
      end

      root = @project_root.respond_to?(:call) ? @project_root.call : @project_root
      claim = @store.reserve(
        project_root: root,
        key: @key,
        command: @command,
        mode: @mode,
        target: @target,
        request: @request,
        principal: @principal,
        principal_source: @principal_source
      )
      return replay(claim) if claim.disposition == :replay

      claim = @store.mark_executing(claim)
      effect = @store.prepare_effect(
        claim, ordinal: 0, kind: "#{@command}:#{@mode || 'default'}",
        identity: { "target" => @target, "request_fingerprint" => claim.request_fingerprint }
      )
      context = operation_context(claim, effect)
      result, captured = with_context(context) { capture { yield } }
      @store.update_effect(
        claim, effect_id: effect.fetch(:effect_id), from: %w[prepared submitted], to: "applied",
        evidence: { "boundary_completed" => true }
      )
      payload = response_payload(result, captured)
      public_receipt = {
        "id" => claim.receipt_id,
        "generation" => claim.generation + 1,
        "state" => "succeeded"
      }
      emitted = attach_receipt(payload, public_receipt)
      stored = stored_response(emitted)
      @store.succeed(claim, result: stored, status: Hive::ExitCodes::SUCCESS)
      emit_or_return(emitted)
    rescue Exception # rubocop:disable Lint/RescueException -- preserve Interrupt/SystemExit ambiguity
      begin
        @store.update_effect(
          claim, effect_id: effect.fetch(:effect_id), from: %w[prepared submitted], to: "unknown",
          evidence: { "boundary_completed" => false }
        ) if claim && effect
        @store.mark_unresolved(claim, reason: "command_execution_interrupted") if claim
      rescue StandardError
        # The original failure remains authoritative. A failed uncertainty
        # commit is still fail-closed because no buffered success is emitted.
      end
      raise
    end

    private

    def operation_context(claim, effect)
      ordinal = effect.fetch(:ordinal)
      transport = "command-dispatch:v1:#{Digest::SHA256.hexdigest(
        [ claim.receipt_id, effect.fetch(:effect_id), ordinal ].join("\0")
      )[0, 64]}"
      Context.new(
        receipt_id: claim.receipt_id, effect_id: effect.fetch(:effect_id),
        principal: claim.principal, principal_source: @principal_source,
        ordinal: ordinal, request_fingerprint: claim.request_fingerprint,
        transport_request_id: transport
      )
    end

    def with_context(context)
      previous = self.class.current_context
      Thread.current[:hive_command_operation_context] = context
      yield
    ensure
      Thread.current[:hive_command_operation_context] = previous
    end

    def capture
      return [ yield, nil ] if @structured

      CAPTURE_MUTEX.synchronize do
        previous = $stdout
        buffer = StringIO.new
        $stdout = buffer
        result = yield
        [ result, buffer.string ]
      ensure
        $stdout = previous
      end
    end

    def response_payload(result, captured)
      return result if @structured
      return captured unless @json

      parsed = JSON.parse(captured.to_s)
      raise Hive::InternalError, "keyed command emitted a non-object JSON result" unless parsed.is_a?(Hash)
      parsed
    rescue JSON::ParserError => error
      raise Hive::InternalError, "keyed command emitted invalid JSON: #{error.message}"
    end

    def attach_receipt(payload, receipt)
      return payload unless @json || @structured
      payload.merge("command_receipt" => receipt)
    end

    def stored_response(payload)
      if @json || @structured
        template = template_payload(payload)
        {
          "format" => "json",
          "payload" => template,
          "expanded_sha256" => Digest::SHA256.hexdigest(
            Hive::RuntimeControlPlane::Codec.dump_json(payload)
          )
        }
      else
        { "format" => "text", "text" => payload.to_s }
      end
    end

    def template_payload(payload)
      return payload unless @command == "act" && payload["observation_token"].is_a?(String)
      value = payload.fetch("observation_token")
      payload.merge(
        "observation_token" => {
          "$command_request_field" => "observation",
          "sha256" => Digest::SHA256.hexdigest(value)
        }
      )
    end

    def replay(claim)
      if claim.state == "settled"
        raise Hive::CommandUnresolved.new(
          reason: "command_original_result_unavailable", state: "settled",
          command_receipt: claim.public_receipt,
          message: "the original command result is unavailable; effects may have occurred and retry is forbidden"
        )
      end
      stored = claim.result
      unless stored.is_a?(Hash) && %w[json text].include?(stored["format"])
        raise Hive::RuntimeControlPlane::IntegrityError.new(
          "command receipt result has an unsupported replay representation",
          code: :command_result_invalid,
          action: Hive::RuntimeControlPlane::Database::BACKUP_ACTION
        )
      end
      if stored.fetch("format") == "text"
        return stored.fetch("text") if @structured
        $stdout.write(stored.fetch("text"))
        return nil
      end

      payload = expand_template(stored.fetch("payload"))
      digest = Digest::SHA256.hexdigest(Hive::RuntimeControlPlane::Codec.dump_json(payload))
      unless digest == stored.fetch("expanded_sha256")
        raise Hive::CommandConflict,
              "retry inputs cannot reconstruct the original command response"
      end
      emit_or_return(payload)
    end

    def expand_template(payload)
      token = payload["observation_token"]
      return payload unless token.is_a?(Hash) && token["$command_request_field"] == "observation"
      value = @request[:observation] || @request["observation"]
      unless value.is_a?(String) && Digest::SHA256.hexdigest(value) == token["sha256"]
        raise Hive::CommandConflict,
              "retry observation does not match the original command request"
      end
      payload.merge("observation_token" => value)
    end

    def emit_or_return(payload)
      return payload if @structured
      if @json
        $stdout.puts(JSON.generate(payload))
      else
        $stdout.write(payload.to_s)
      end
      nil
    end
  end
end
