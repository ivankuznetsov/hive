# frozen_string_literal: true

require "digest"
require "base64"
require "json"
require "stringio"
require "thread"
require "securerandom"
require "hive/command_receipt_store"
require "hive/lock"

module Hive
  # One caller receipt around one public command boundary. Keyed success is
  # buffered until the exact response has committed; unkeyed calls retain the
  # command's existing streaming behavior.
  class CommandOperation
    CAPTURE_MUTEX = Mutex.new
    class ThreadRoutedOutput
      def initialize(capture_thread:, captured:, passthrough:)
        @capture_thread = capture_thread
        @captured = captured
        @passthrough = passthrough
      end

      def write(value) = destination.write(value)
      def flush = destination.flush
      def tty? = destination.tty?
      def sync = destination.sync
      def sync=(value)
        destination.sync = value
      end

      def method_missing(name, *args, **kwargs, &block)
        return super unless destination.respond_to?(name)

        destination.public_send(name, *args, **kwargs, &block)
      end

      def respond_to_missing?(name, include_private = false)
        destination.respond_to?(name, include_private) || super
      end

      private

      def destination
        Thread.current == @capture_thread ? @captured : @passthrough
      end
    end

    Context = Data.define(
      :receipt_id, :effect_id, :principal, :principal_source, :ordinal,
      :request_fingerprint, :transport_request_id, :retry_horizon_expires_at
    )

    def self.current_context = Thread.current[:hive_command_operation_context]
    def self.current_operation = Thread.current[:hive_command_operation]

    def self.record_effect_submission(kind:, identity:)
      current_operation&.send(:record_effect_submission, kind: kind, identity: identity)
    end

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
                   structured: false, maintenance: false,
                   failure_payload: nil,
                   text_renderer: nil,
                   retry_horizon_expires_at: nil,
                   store: Hive::CommandReceiptStore.new)
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
      @maintenance = maintenance
      @failure_payload = failure_payload
      @text_renderer = text_renderer
      @retry_horizon_expires_at = retry_horizon_expires_at
      Hive::CommandMutations.validate_keyed!(
        command: @command, mode: @mode, target: @target, options: @request
      ) unless @key.nil?
    end

    def call
      return yield if @key.nil?
      root = @project_root.respond_to?(:call) ? @project_root.call : @project_root
      if (existing = @store.lookup_existing(
        project_root: root,
        key: @key, command: @command, target: @target,
        request: @request, principal: @principal
      ))
        return replay(existing) unless existing.disposition == :resume
        claim = existing
      end

      claim ||= @store.reserve(
        project_root: root,
        key: @key,
        command: @command,
        mode: @mode,
        target: @target,
        request: @request,
        principal: @principal,
        principal_source: @principal_source,
        maintenance: @maintenance,
        execute: true,
        owner_process_start: Hive::Lock.process_start_time(Process.pid)
      )
      return replay(claim) if claim.disposition == :replay
      claim = @store.resume_maintenance(claim) if claim.disposition == :resume

      effect = @store.prepare_effect(
        claim, ordinal: 0, kind: "#{@command}:#{@mode || 'default'}",
        identity: { "target" => @target, "request_fingerprint" => claim.request_fingerprint }
      )
      context = operation_context(claim, effect)
      result, captured = with_context(context) { capture { yield } }
      @store.update_effect(
        claim, effect_id: effect.fetch(:effect_id), from: %w[prepared submitted unknown], to: "applied",
        evidence: { "boundary_completed" => true }
      )
      payload = response_payload(result, captured)
      public_receipt = {
        "id" => claim.receipt_id,
        "generation" => claim.generation + 1,
        "state" => "succeeded"
      }
      emitted = attach_receipt(payload, public_receipt)
      canonical = result.is_a?(Hash) ? attach_receipt(result, public_receipt) : nil
      stored = stored_response(emitted, canonical: canonical, captured: captured)
      @store.succeed(claim, result: stored, status: Hive::ExitCodes::SUCCESS)
      @store.close_pin(
        receipt_id: claim.receipt_id, principal: claim.principal,
        intent_id: context.transport_request_id, intent_generation: context.ordinal
      ) if context.retry_horizon_expires_at
      emit_or_return(emitted)
    rescue Exception => error # rubocop:disable Lint/RescueException -- preserve Interrupt/SystemExit ambiguity
      if claim && effect && deterministic_non_application?(error)
        persist_non_application_failure(claim, effect, error)
      elsif claim
        persist_uncertainty(claim, effect)
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
        transport_request_id: transport,
        retry_horizon_expires_at: @retry_horizon_expires_at
      )
    end

    def with_context(context)
      previous = self.class.current_context
      previous_operation = self.class.current_operation
      Thread.current[:hive_command_operation_context] = context
      Thread.current[:hive_command_operation] = self
      yield
    ensure
      Thread.current[:hive_command_operation_context] = previous
      Thread.current[:hive_command_operation] = previous_operation
    end

    def record_effect_submission(kind:, identity:)
      context = self.class.current_context
      return unless context

      @store.record_effect_submission(
        receipt_id: context.receipt_id, effect_id: context.effect_id,
        principal: context.principal, request_fingerprint: context.request_fingerprint,
        kind: kind, identity: identity
      )
    end

    def capture
      return [ yield, nil ] if @structured

      CAPTURE_MUTEX.synchronize do
        captured = StringIO.new
        previous_stdout = $stdout
        begin
          $stdout = ThreadRoutedOutput.new(
            capture_thread: Thread.current, captured: captured, passthrough: previous_stdout
          )
          result = yield
          captured.flush
          [ result, captured.string ]
        ensure
          $stdout = previous_stdout
        end
      end
    end

    def deterministic_non_application?(error)
      error.is_a?(Hive::UsageError) || error.is_a?(Hive::InvalidTaskPath) ||
        error.is_a?(Hive::WrongStage)
    end

    def persist_non_application_failure(claim, effect, error)
      @store.update_effect(
        claim, effect_id: effect.fetch(:effect_id), from: "prepared", to: "not_applied",
        evidence: { "error_class" => error.class.name, "whole_effect_non_application" => true }
      )
      @store.fail_non_application(
        claim, result: stored_failure(error), status: error.exit_code,
        reason: "command_effect_not_applied", whole_effect_non_application: true
      )
    rescue StandardError
      persist_uncertainty(claim, effect)
    end

    def persist_uncertainty(claim, effect)
      begin
        @store.update_effect(
          claim, effect_id: effect.fetch(:effect_id), from: %w[prepared submitted], to: "unknown",
          evidence: { "boundary_completed" => false }
        ) if effect
      rescue StandardError
        # An effect may already be applied (for example finalization failed).
        # Receipt uncertainty still has to be persisted independently.
      end
      @store.mark_unresolved(claim, reason: "command_execution_interrupted")
    rescue StandardError
      # The original exception remains authoritative and no buffered success is emitted.
    end

    def stored_failure(error)
      payload = @failure_payload&.call(error)
      if payload || @json || @structured
        payload ||= {
          "schema" => "hive-command-receipt", "schema_version" => 1,
          "ok" => false, "error_class" => error.class.name.split("::").last,
          "error_kind" => failure_error_kind(error),
          "exit_code" => error.exit_code, "message" => error.message
        }
        {
          "format" => "dual", "payload" => payload,
          "text" => "#{error.message}\n",
          "expanded_sha256" => Digest::SHA256.hexdigest(
            Hive::RuntimeControlPlane::Codec.dump_json(payload)
          )
        }
      else
        { "format" => "text", "text" => "#{error.message}\n" }
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

    def stored_response(payload, canonical: nil, captured: nil)
      if canonical
        template = template_payload(canonical)
        text = @json ? render_text(canonical) : captured.to_s
        return {
          "format" => "dual", "payload" => template, "text" => text,
          "expanded_sha256" => Digest::SHA256.hexdigest(
            Hive::RuntimeControlPlane::Codec.dump_json(canonical)
          )
        }
      end
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

    def render_text(payload)
      return @text_renderer.call(payload) if @text_renderer
      "#{payload}\n"
    end

    def template_payload(payload)
      if @command == "act" && payload["observation_token"].is_a?(String)
        value = payload.fetch("observation_token")
        return payload.merge(
          "observation_token" => {
            "$command_request_field" => "observation", "template_version" => 1,
            "sha256" => Digest::SHA256.hexdigest(value)
          }
        )
      end
      if @command == "answer" && payload.dig("slot", "binding").is_a?(String)
        binding = payload.dig("slot", "binding")
        fields = JSON.parse(Base64.urlsafe_decode64(binding))
        return payload.merge(
          "slot" => payload.fetch("slot").merge(
            "binding" => {
              "$command_response_fields" => fields, "template_version" => 1,
              "$command_response_value" => binding,
              "sha256" => Digest::SHA256.hexdigest(binding)
            }
          )
        )
      end
      payload
    rescue JSON::ParserError, ArgumentError
      payload
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
      unless stored.is_a?(Hash) && %w[dual json text].include?(stored["format"])
        raise Hive::RuntimeControlPlane::IntegrityError.new(
          "command receipt result has an unsupported replay representation",
          code: :command_result_invalid,
          action: Hive::RuntimeControlPlane::Database::BACKUP_ACTION
        )
      end
      if stored.fetch("format") == "text" ||
         (stored.fetch("format") == "dual" && !@json && !@structured)
        return stored.fetch("text") if @structured
        $stdout.write(stored.fetch("text"))
        exit(Integer(claim.status)) if claim.state == "failed"
        return nil
      end

      payload = expand_template(stored.fetch("payload"))
      digest = Digest::SHA256.hexdigest(Hive::RuntimeControlPlane::Codec.dump_json(payload))
      unless digest == stored.fetch("expanded_sha256")
        raise Hive::CommandConflict,
              "retry inputs cannot reconstruct the original command response"
      end
      if claim.state == "failed" && @structured
        $stdout.puts(JSON.generate(payload))
        exit(Integer(claim.status))
      end
      emitted = emit_or_return(payload)
      exit(Integer(claim.status)) if claim.state == "failed" && !@structured
      emitted
    end

    def expand_template(payload)
      token = payload["observation_token"]
      if token.is_a?(Hash) && token["$command_request_field"] == "observation" &&
         token["template_version"] == 1
        value = @request[:observation] || @request["observation"]
        unless value.is_a?(String) && Digest::SHA256.hexdigest(value) == token["sha256"]
          raise Hive::CommandConflict,
                "retry observation does not match the original command request"
        end
        return payload.merge("observation_token" => value)
      end
      binding_template = payload.dig("slot", "binding")
      if binding_template.is_a?(Hash) &&
         binding_template["$command_response_fields"].is_a?(Hash) &&
         binding_template["template_version"] == 1
        fields = binding_template.fetch("$command_response_fields")
        value = binding_template.fetch("$command_response_value")
        decoded = JSON.parse(Base64.urlsafe_decode64(value))
        unless decoded == fields && Digest::SHA256.hexdigest(value) == binding_template["sha256"]
          raise Hive::CommandConflict,
                "retry answer binding cannot reconstruct the original response"
        end
        return payload.merge("slot" => payload.fetch("slot").merge("binding" => value))
      end
      payload
    rescue JSON::ParserError, ArgumentError, KeyError
      raise Hive::CommandConflict,
            "retry answer binding cannot reconstruct the original response"
    end

    def failure_error_kind(error)
      return error.reason if error.is_a?(Hive::CommandOutcomeError) ||
        error.is_a?(Hive::CommandCapacityError) || error.is_a?(Hive::CommandIntakeDisabled)
      return "usage" if error.is_a?(Hive::UsageError) || error.is_a?(Hive::InvalidTaskPath) ||
        error.is_a?(Hive::WrongStage)
      return "config" if error.is_a?(Hive::ConfigError)

      "internal"
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
