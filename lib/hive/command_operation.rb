# frozen_string_literal: true

require "digest"
require "base64"
require "json"
require "stringio"
require "thread"
require "securerandom"
require "hive/command_receipt_store"
require "hive/config"
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
      :receipt_generation, :request_fingerprint, :transport_request_id,
      :retry_horizon_expires_at
    )

    def self.current_context
      Thread.current[:hive_command_operation_context] ||
        (defined?(Hive::Attempts::Context) && Hive::Attempts::Context.current&.command_context)
    end
    def self.current_operation = Thread.current[:hive_command_operation]

    def self.record_effect_submission(kind:, identity:)
      return current_operation.send(:record_effect_submission, kind: kind, identity: identity) if current_operation
      context = defined?(Hive::Attempts::Context) && Hive::Attempts::Context.current&.command_context
      return unless context
      Hive::CommandReceiptStore.new.record_effect_submission(
        receipt_id: context.receipt_id, effect_id: context.effect_id,
        principal: context.principal, request_fingerprint: context.request_fingerprint,
        generation: context.receipt_generation, kind: kind, identity: identity
      )
    end

    def self.record_effect_observation(source:, correlation_id:, evidence: {})
      return current_operation.send(
        :record_effect_observation,
        source: source, correlation_id: correlation_id, evidence: evidence
      ) if current_operation
      context = defined?(Hive::Attempts::Context) && Hive::Attempts::Context.current&.command_context
      return unless context
      Hive::CommandReceiptStore.new.record_effect_observation(
        receipt_id: context.receipt_id, effect_id: context.effect_id,
        principal: context.principal, request_fingerprint: context.request_fingerprint,
        generation: context.receipt_generation, source: source,
        correlation_id: correlation_id, evidence: evidence
      )
    end

    def self.local_principal(database)
      unless Process.uid == Process.euid
        raise Hive::ConfigError,
              "keyed CLI execution requires matching real and effective user ids"
      end
      installation = database.installation_identity.fetch(:installation_id)
      "installation:#{installation}:uid:#{Process.uid}"
    end

    # Return only roots the caller can already address through the registered
    # project configuration. The task folder itself is deliberately not
    # resolved here: a committed receipt must remain discoverable after that
    # folder moves or is deleted.
    def self.registered_project_roots(target:, project: nil)
      projects = Hive::Config.registered_projects
      if project
        row = projects.find { |entry| entry["name"] == project.to_s }
        return row ? [ row.fetch("path") ] : []
      end

      source = target.to_s
      return projects.map { |entry| entry.fetch("path") } unless
        source.include?("/") || source.start_with?("~", ".")

      expanded = File.expand_path(source)
      projects.filter_map do |entry|
        roots = [ entry["path"], entry["hive_state_path"] ].compact.map {
          |value| File.expand_path(value)
        }
        entry.fetch("path") if roots.any? {
          |root| expanded == root || expanded.start_with?("#{root}#{File::SEPARATOR}")
        }
      end
    end

    def initialize(key:, command:, target:, request:, project_root:, project_roots: nil,
                   principal: nil,
                   principal_source: "local_cli", mode: nil, json: false,
                   structured: false, maintenance: false,
                   display_json: json,
                   failure_payload: nil,
                   text_renderer: nil,
                   retry_horizon_expires_at: nil,
                   store: Hive::CommandReceiptStore.new)
      @key = key
      @command = command.to_s
      @target = target.to_s
      @request = request
      @project_root = project_root
      @project_roots = project_roots
      @store = store
      verify_receipt_extension! if @key
      @principal = principal || self.class.local_principal(store.database)
      @principal_source = principal_source
      @mode = mode
      @json = json
      @structured = structured
      @display_json = display_json
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
      if @project_roots && (existing = @store.lookup_existing_in_projects(
        project_roots: resolved_project_roots,
        key: @key, command: @command, target: @target,
        request: @request, principal: @principal
      ))
        return replay(existing) unless existing.disposition == :resume
        claim = existing
      end

      root = claim&.project_root || resolved_project_root
      unless claim
        if (existing = @store.lookup_existing(
          project_root: root,
          key: @key, command: @command, target: @target,
          request: @request, principal: @principal
        ))
          return replay(existing) unless existing.disposition == :resume
          claim = existing
        end
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
      payload = response_payload(result, captured)
      public_receipt = {
        "id" => claim.receipt_id,
        "generation" => claim.generation + 1,
        "state" => "succeeded"
      }
      canonical_source = canonical_payload(result, captured)
      canonical = canonical_source&.merge("command_receipt" => public_receipt)
      emitted = if !@json && canonical_source && !result.is_a?(Hash)
        render_text(canonical)
      else
        attach_receipt(payload, public_receipt)
      end
      stored = stored_response(emitted, canonical: canonical, captured: captured)
      begin
        @store.complete_effect(
          claim, effect_id: effect.fetch(:effect_id), result: stored,
          status: Hive::ExitCodes::SUCCESS
        )
        @store.succeed(claim, result: stored, status: Hive::ExitCodes::SUCCESS)
      rescue Sequel::Error, SQLite3::Exception, SystemCallError, IOError => persistence_error
        persist_uncertainty(claim, effect, persistence_error)
        persistence_failed = true
        raise Hive::CommandUnresolved.new(
          command_receipt: persisted_receipt_identity(claim),
          message: "the command effect completed but its durable result could not be finalized"
        )
      end
      emit_or_return(emitted)
    rescue Exception => error # rubocop:disable Lint/RescueException -- preserve Interrupt/SystemExit ambiguity
      raise if persistence_failed
      raise if error.is_a?(SystemExit) && claim&.disposition == :replay
      if claim && effect && deterministic_non_application?(error)
        persist_failure(claim, effect, error)
      elsif claim
        persist_uncertainty(claim, effect, error)
      end
      raise
    end

    private

    def verify_receipt_extension!
      return @store.verify_extension! if @store.respond_to?(:verify_extension!)
      return unless @store.respond_to?(:database) && @store.database.respond_to?(:read)
      return if Hive::RuntimeControlPlane::CommandSchema.installed?(@store.database)

      raise Hive::ConfigError,
            "command receipts are not installed; run `hive setup --install-command-receipts`"
    rescue Hive::ConfigError
      raise
    rescue Hive::Error, Sequel::Error => error
      raise Hive::ConfigError,
            "cannot verify command receipt storage: #{error.message}"
    end

    def resolved_project_roots
      value = @project_roots.respond_to?(:call) ? @project_roots.call : @project_roots
      Array(value)
    end

    def resolved_project_root
      @project_root.respond_to?(:call) ? @project_root.call : @project_root
    end

    def operation_context(claim, effect)
      ordinal = effect.fetch(:ordinal)
      transport = "command-dispatch:v1:#{Digest::SHA256.hexdigest(
        [ claim.receipt_id, effect.fetch(:effect_id), ordinal ].join("\0")
      )[0, 64]}"
      Context.new(
        receipt_id: claim.receipt_id, effect_id: effect.fetch(:effect_id),
        principal: claim.principal, principal_source: @principal_source,
        ordinal: ordinal, receipt_generation: claim.generation,
        request_fingerprint: claim.request_fingerprint,
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
        generation: context.receipt_generation, kind: kind, identity: identity
      )
    end

    def record_effect_observation(source:, correlation_id:, evidence:)
      context = self.class.current_context
      return unless context

      @store.record_effect_observation(
        receipt_id: context.receipt_id, effect_id: context.effect_id,
        principal: context.principal, request_fingerprint: context.request_fingerprint,
        generation: context.receipt_generation, source: source,
        correlation_id: correlation_id, evidence: evidence
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

    def persist_uncertainty(claim, effect, error = nil)
      if effect && @store.authoritative_result_recorded?(
        receipt_id: claim.receipt_id, effect_id: effect.fetch(:effect_id)
      )
        @store.mark_unresolved(claim, reason: "command_execution_interrupted")
        return
      end

      if effect && retryable_pre_submission_contention?(error)
        @store.abort_pre_submission(
          claim, effect_id: effect.fetch(:effect_id), reason: "command_retryable_contention"
        )
        return
      end

      begin
        @store.update_effect(
          claim, effect_id: effect.fetch(:effect_id), from: %w[prepared submitted], to: "unknown",
          evidence: { "boundary_completed" => false, "owner_released" => true }
        ) if effect
      rescue StandardError
        # An effect may already be applied (for example finalization failed).
        # Receipt uncertainty still has to be persisted independently.
      end
      if effect
        @store.mark_unresolved(claim, reason: "command_execution_interrupted")
      else
        @store.abort_before_effect(claim, reason: "command_cancelled_before_effect")
      end
    rescue StandardError
      begin
        @store.mark_unresolved(claim, reason: "command_execution_interrupted")
      rescue StandardError
        # The original exception remains authoritative and no buffered success is emitted.
      end
    end

    def persisted_receipt_identity(claim)
      row = @store.receipt(claim.receipt_id)
      return {
        "id" => row.fetch(:receipt_id), "generation" => row.fetch(:generation),
        "state" => row.fetch(:state)
      } if row

      { "id" => claim.receipt_id, "generation" => claim.generation, "state" => claim.state }
    rescue StandardError
      { "id" => claim.receipt_id, "generation" => claim.generation, "state" => claim.state }
    end

    def persist_failure(claim, effect, error)
      @store.update_effect(
        claim, effect_id: effect.fetch(:effect_id), from: "prepared", to: "not_applied",
        evidence: { "whole_effect_non_application" => true,
                    "failure_class" => error.class.name }
      )
      @store.fail_non_application(
        claim, result: stored_failure(error), status: error.exit_code,
        reason: failure_error_kind(error), whole_effect_non_application: true
      )
    rescue StandardError
      persist_uncertainty(claim, effect)
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
        stored = {
          "format" => "dual", "payload" => payload,
          "text" => "#{error.message}\n",
          "expanded_sha256" => Digest::SHA256.hexdigest(
            Hive::RuntimeControlPlane::Codec.dump_json(payload)
          )
        }
        stored["json_bytes"] = "#{JSON.generate(payload)}\n" if template_payload(payload) == payload
        stored
      else
        { "format" => "text", "text" => "#{error.message}\n" }
      end
    end

    def response_payload(result, captured)
      return result if @structured
      return captured unless @json
      return result if result.is_a?(Hash)

      parsed = JSON.parse(captured.to_s)
      raise Hive::InternalError, "keyed command emitted a non-object JSON result" unless parsed.is_a?(Hash)
      parsed
    rescue JSON::ParserError => error
      raise Hive::InternalError, "keyed command emitted invalid JSON: #{error.message}"
    end

    def canonical_payload(result, captured)
      return result if result.is_a?(Hash)
      return unless !@json && @text_renderer && captured.to_s.lstrip.start_with?("{")

      parsed = JSON.parse(captured)
      parsed if parsed.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    def attach_receipt(payload, receipt)
      return payload unless @json || @structured
      payload.merge("command_receipt" => receipt)
    end

    def stored_response(payload, canonical: nil, captured: nil)
      if canonical
        template = template_payload(canonical)
        text = @json ? render_text(canonical) : captured.to_s
        stored = {
          "format" => "dual", "payload" => template,
          "expanded_sha256" => Digest::SHA256.hexdigest(
            Hive::RuntimeControlPlane::Codec.dump_json(canonical)
          )
        }
        stored["json_bytes"] = "#{JSON.generate(canonical)}\n" if template == canonical
        stored["text"] = text unless answer_binding?(canonical)
        return stored
      end
      if @json || @structured
        template = template_payload(payload)
        stored = {
          "format" => "json",
          "payload" => template,
          "expanded_sha256" => Digest::SHA256.hexdigest(
            Hive::RuntimeControlPlane::Codec.dump_json(payload)
          )
        }
        stored["json_bytes"] = "#{JSON.generate(payload)}\n" if template == payload
        stored
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
        fields = begin JSON.parse(Base64.urlsafe_decode64(binding))
        rescue JSON::ParserError, ArgumentError then nil end
        return payload unless fields.is_a?(Hash)
        return payload.merge(
          "slot" => payload.fetch("slot").merge(
            "binding" => {
              "$command_response_fields" => fields, "template_version" => 1,
              "$command_response_field_order" => fields.keys,
              "encoding" => "base64url-json",
              "sha256" => Digest::SHA256.hexdigest(binding)
            }
          )
        )
      end
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
      if stored.fetch("format") == "text"
        if @structured
          if claim.state == "failed"
            raise Hive::CommandReplayFailure.new(
              stored.fetch("text").strip, exit_code: claim.status
            )
          end
          return stored.fetch("text")
        end
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
      exact_payload = exact_json_payload(stored, payload)
      if !@json && !@structured
        text = stored.fetch("format") == "dual" ? stored["text"] : nil
        $stdout.write(text || render_text(payload))
        exit(Integer(claim.status)) if claim.state == "failed"
        return nil
      end
      if claim.state == "failed" && @structured && !@display_json
        raise Hive::CommandReplayFailure.new(
          payload.fetch("message", "the original keyed command failed"),
          exit_code: claim.status
        )
      end
      if claim.state == "failed" && @structured
        $stdout.write(stored["json_bytes"] || "#{JSON.generate(payload)}\n")
        exit(Integer(claim.status))
      end
      emitted = if @structured
        exact_payload || payload
      elsif @json && stored["json_bytes"]
        $stdout.write(stored.fetch("json_bytes"))
        nil
      else
        emit_or_return(payload)
      end
      exit(Integer(claim.status)) if claim.state == "failed" && !@structured
      emitted
    end

    def answer_binding?(payload)
      @command == "answer" && payload.dig("slot", "binding").is_a?(String)
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
        order = binding_template.fetch("$command_response_field_order")
        unless order.is_a?(Array) && order.sort == fields.keys.sort && order.uniq == order
          raise KeyError
        end
        raise KeyError unless binding_template["encoding"] == "base64url-json"
        ordered_fields = order.to_h { |key| [ key, fields.fetch(key) ] }
        value = Base64.urlsafe_encode64(JSON.generate(ordered_fields), padding: false)
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
        error.is_a?(Hive::OperationalActionUsageError) ||
        error.is_a?(Hive::WrongStage)
      return "config" if error.is_a?(Hive::ConfigError)

      "internal"
    end

    def deterministic_non_application?(error)
      error.is_a?(Hive::UsageError) ||
        error.is_a?(Hive::OperationalActionUsageError) || error.is_a?(Hive::WrongStage)
    end

    def retryable_pre_submission_contention?(error)
      return false unless error
      return true if error.is_a?(Hive::ConcurrentRunError)
      return true if error.is_a?(Hive::CommandCapacityError) &&
        error.reason == "command_prune_busy"

      current = error
      5.times do
        return true if current.is_a?(Sequel::DatabaseLockTimeout) ||
          current.class.name == "SQLite3::BusyException"
        current = current.cause
        break unless current
      end
      false
    end

    def exact_json_payload(stored, payload)
      bytes = stored["json_bytes"]
      return unless bytes.is_a?(String) && bytes.end_with?("\n")
      parsed = JSON.parse(bytes)
      unless parsed == payload
        raise Hive::RuntimeControlPlane::IntegrityError.new(
          "command receipt exact replay bytes do not match the saved result",
          code: :command_result_invalid,
          action: Hive::RuntimeControlPlane::Database::BACKUP_ACTION
        )
      end
      parsed
    rescue JSON::ParserError
      raise Hive::RuntimeControlPlane::IntegrityError.new(
        "command receipt exact replay bytes are invalid",
        code: :command_result_invalid,
        action: Hive::RuntimeControlPlane::Database::BACKUP_ACTION
      )
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
