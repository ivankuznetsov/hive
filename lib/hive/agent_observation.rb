require "time"
require "hive/billing_evidence"
require "hive/task_activity"

module Hive
  # Attempt-bound, provider-neutral session evidence. This object never owns
  # process liveness: it records one durable start and at most one terminal
  # observation around the existing launcher result.
  class AgentObservation
    RESOURCE_KINDS = %w[
      monetary_api_cap budget_equivalent_guard token_limit launch_quota timeout
      account_quota provider_rate_limit turn_limit model_output_limit
    ].freeze
    UNITS = %w[usd tokens launches seconds turns requests].freeze
    ENFORCEMENTS = %w[controller provider_cli provider_account advisory unenforced].freeze
    BILLING_SEMANTICS = %w[api_billed subscription_backed not_applicable unknown].freeze
    BILLING_ROUTES = Hive::BillingEvidence::ROUTES

    attr_reader :session_id, :started_at

    def initialize(task:, context:, session_id:, role:, provider:, timeout_sec:,
                   guards:, requested_model: nil, requested_effort: nil,
                   requested_provider: nil, billing_route: "unknown",
                   billing_evidence_source: "unavailable",
                   activity: nil, attempt_store: nil, clock: -> { Time.now.utc })
      @task = task
      @context = context
      @session_id = identifier(session_id, "session_id")
      @role = normalized_role(role)
      @provider = identifier(provider, "provider")
      @requested_provider = optional_identifier(requested_provider, "requested_provider")
      @requested_model = optional_text(requested_model)
      @requested_effort = optional_text(requested_effort)
      @billing_route = billing_route.to_s
      unless BILLING_ROUTES.include?(@billing_route)
        raise ArgumentError, "billing_route must be subscription, api, or unknown"
      end
      @billing_evidence_source = identifier(
        billing_evidence_source, "billing_evidence_source"
      )
      @timeout_sec = optional_positive_number(timeout_sec, "timeout_sec")
      @guards = normalize_guards(guards)
      @clock = clock
      @attempt_store = attempt_store
      @activity = activity || build_activity
      @available = compatible_context? && !@activity.nil?
      @started = false
      @finished = false
    end

    def available? = @available

    def start!
      return false unless available?
      return true if @started

      reconcile_terminal_operations!
      @started_at = normalize_time(@clock.call)
      append(
        kind: "session_started", operation_id: "session:#{session_id}:start",
        reason: "agent session started", occurred_at: @started_at,
        payload: base_payload.merge(
          "started_at" => @started_at, "ended_at" => nil,
          "live" => true, "health" => "live", "outcome" => nil,
          "actual_provider" => nil, "actual_model" => nil,
          "observed_execution" => nil, "guards" => @guards
        )
      )
      @started = true
    rescue Hive::TaskActivity::Error
      false
    end

    def finish!(result = nil, exception: nil, **attributes)
      return false unless available?
      return false if @finished

      result = (result || {}).to_h.merge(attributes)
      return false unless @started || start!
      ended_at = normalize_time(@clock.call)
      resource = resource_observation(result)
      payload = base_payload.merge(
        "started_at" => @started_at, "ended_at" => ended_at,
        "live" => false, "health" => health(result, exception),
        "outcome" => outcome(result, exception),
        "actual_provider" => actual_provider(result),
        "actual_model" => actual_model(result),
        "observed_execution" => observed_execution(result),
        "timed_out" => timed_out?(result),
        "resource_observation" => resource,
        "usage" => normalized_usage(result[:usage]),
        "guards" => @guards
      )
      operation = @activity.begin_operation(
        kind: "session_finished", operation_id: "session:#{session_id}:finish",
        source: "agent_runtime", reason: "agent session finished",
        precondition: { "session_id" => session_id, "live" => true },
        expected_postcondition: { "session_id" => session_id, "live" => false }
      )
      operation.complete!(
        result: payload, occurred_at: ended_at, correlation_id: session_id,
        payload: payload,
        evidence: [ { "kind" => "runtime_receipt", "reference" => "sessions/#{session_id}" } ]
      )
      @finished = true
      true
    rescue Hive::TaskActivity::Error
      begin
        if operation&.reconcile!
          @finished = true
          return true
        end
      rescue Hive::TaskActivity::Error
        nil
      end
      false
    end

    private

    def append(kind:, operation_id:, reason:, occurred_at:, payload:)
      @activity.record(
        kind: kind, operation_id: operation_id, correlation_id: session_id,
        reason: reason, source: "agent_runtime", occurred_at: occurred_at,
        observed_at: occurred_at,
        evidence: [ { "kind" => "runtime_receipt", "reference" => "sessions/#{session_id}" } ],
        payload: payload
      )
    end

    def reconcile_terminal_operations!
      @activity.reconcile_operations! { :defer }
    end

    def base_payload
      {
        "session_id" => session_id, "role" => @role, "provider" => @provider,
        "harness" => @provider,
        "requested_provider" => @requested_provider,
        "requested_model" => @requested_model,
        "requested_effort" => @requested_effort,
        "billing_route" => @billing_route,
        "billing_evidence_source" => @billing_evidence_source,
        "admitted_launch" => {
          "requested_provider" => @requested_provider,
          "requested_model" => @requested_model,
          "billing_route" => @billing_route,
          "billing_evidence_source" => @billing_evidence_source
        },
        "timeout_sec" => @timeout_sec
      }
    end

    def build_activity
      return nil unless compatible_context?

      Hive::TaskActivity.for_context(
        @task, context: @context, attempt_store: @attempt_store, clock: @clock
      )
    rescue Hive::TaskActivity::Error, SystemCallError
      nil
    end

    def compatible_context?
      @context && @task.respond_to?(:slug) &&
        @context.task_slug.to_s == @task.slug.to_s &&
        !@context.attempt_id.to_s.empty?
    end

    def normalize_guards(value)
      Array(value).map.with_index do |guard, index|
        row = guard.to_h.transform_keys(&:to_s)
        kind = row.fetch("kind").to_s
        unit = row.fetch("unit").to_s
        enforcement = row.fetch("enforcement").to_s
        billing = row.fetch("billing_semantics").to_s
        raise ArgumentError, "guard #{index} kind is invalid" unless RESOURCE_KINDS.include?(kind)
        raise ArgumentError, "guard #{index} unit is invalid" unless UNITS.include?(unit)
        raise ArgumentError, "guard #{index} enforcement is invalid" unless ENFORCEMENTS.include?(enforcement)
        raise ArgumentError, "guard #{index} billing semantics are invalid" unless BILLING_SEMANTICS.include?(billing)

        {
          "kind" => kind, "unit" => unit,
          "scope" => identifier(row.fetch("scope"), "guard scope"),
          "source" => identifier(row.fetch("source"), "guard source"),
          "enforcement" => enforcement, "billing_semantics" => billing,
          "configured" => numeric_or_nil(row["configured"]),
          "observed" => numeric_or_nil(row["observed"]),
          "reset_at" => optional_time(row["reset_at"]),
          "retry_at" => optional_time(row["retry_at"])
        }
      end.freeze
    end

    def resource_observation(result)
      detail = result[:resource_exhaustion]
      if detail.is_a?(Hash)
        reason = detail[:reason] || detail["reason"]
        kind, unit = case reason.to_s
        when "token_limit" then [ "token_limit", "tokens" ]
        when "turn_limit" then [ "turn_limit", "turns" ]
        when "model_output_limit" then [ "model_output_limit", "tokens" ]
        else return nil
        end
        return {
          "kind" => kind,
          "unit" => unit,
          "configured" => detail[:limit] || detail["limit"],
          "observed" => detail[:observed] || detail["observed"],
          "retry_at" => nil
        }
      end
      signal = result[:provider_signal]
      return nil unless signal.respond_to?(:to_h)

      row = signal.to_h
      failure = row[:failure_class] || row["failure_class"]
      kind = failure.to_s.include?("rate") ? "provider_rate_limit" : "account_quota"
      retry_seconds = row[:reset_hint_seconds] || row["reset_hint_seconds"]
      {
        "kind" => kind, "unit" => "requests", "configured" => nil,
        "observed" => nil,
        "retry_at" => retry_seconds && normalize_time(@clock.call + retry_seconds.to_i)
      }
    end

    def actual_model(result)
      value = result[:actual_model]
      value ||= split_route(result[:actual_opencode_route]).last
      value ||= result[:model] || result.dig(:usage, :model)
      _provider, model = split_route(value)
      optional_text(model || value)
    end

    def actual_provider(result)
      value = result[:actual_provider]
      value ||= split_route(result[:actual_opencode_route]).first
      optional_identifier(value, "actual_provider")
    end

    def observed_execution(result)
      provider = actual_provider(result)
      model = actual_model(result)
      source = result[:execution_identity_source]
      source ||= "sanitized_export" if result[:actual_opencode_route]
      source ||= "provider_usage_event" if provider || model
      source ||= "unavailable"
      {
        "actual_provider" => provider,
        "actual_model" => model,
        "evidence_source" => identifier(source, "execution_identity_source")
      }
    end

    def normalized_usage(value)
      return nil unless value.is_a?(Hash)

      {
        "input" => optional_nonnegative_integer(hash_value(value, :input)),
        "output" => optional_nonnegative_integer(hash_value(value, :output)),
        "cached" => optional_nonnegative_integer(hash_value(value, :cached)),
        "cache_read" => optional_nonnegative_integer(hash_value(value, :cache_read)),
        "cache_write" => optional_nonnegative_integer(hash_value(value, :cache_write)),
        "reasoning" => optional_nonnegative_integer(hash_value(value, :reasoning)),
        "input_includes_cache_read" => optional_boolean(
          hash_value(value, :input_includes_cache_read)
        ),
        "input_includes_cache_write" => optional_boolean(
          hash_value(value, :input_includes_cache_write)
        ),
        "output_includes_reasoning" => optional_boolean(
          hash_value(value, :output_includes_reasoning)
        ),
        "provider_reported_cost" => optional_nonnegative_number(
          hash_value(value, :provider_reported_cost) || hash_value(value, :cost)
        )
      }
    end

    def outcome(result, exception)
      return "timed_out" if timed_out?(result)
      return "failed" if exception

      status = result[:status].to_s
      return "unavailable" if status.empty?
      return "failed" if %w[error failed].include?(status)

      "succeeded"
    end

    def health(result, exception)
      return "timed_out" if timed_out?(result)
      return "error" if exception || %w[error failed].include?(result[:status].to_s)
      return "unavailable" if result[:status].to_s.empty?

      "completed"
    end

    def timed_out?(result)
      result[:timed_out] == true || result[:status].to_s == "timeout"
    end

    def identifier(value, label)
      string = value.to_s
      unless string.match?(%r{\A[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}\z})
        raise ArgumentError, "#{label} is invalid"
      end
      string
    end

    def optional_identifier(value, label)
      return nil if value.to_s.empty?

      identifier(value, label)
    end

    def normalized_role(value)
      role = value.to_s.gsub(%r{[^A-Za-z0-9._:/-]+}, "-")
                     .sub(/\A-+/, "").sub(/-+\z/, "")
      role = "agent" if role.empty?
      identifier(role.byteslice(0, 256), "role")
    end

    def optional_text(value)
      return nil if value.to_s.empty?

      text = Hive::SecretPatterns.redact(value.to_s)
      raise ArgumentError, "observation text exceeds 512 bytes" if text.bytesize > 512
      text
    end

    def positive_number(value, label)
      number = Float(value)
      raise ArgumentError, "#{label} must be positive" unless number.positive?
      number % 1 == 0 ? number.to_i : number
    end

    def optional_positive_number(value, label)
      return nil if value.nil?

      positive_number(value, label)
    end

    def numeric_or_nil(value)
      return nil if value.nil?

      number = Float(value)
      number % 1 == 0 ? number.to_i : number
    end

    def optional_nonnegative_integer(value)
      return nil if value.nil?

      integer = Integer(value)
      raise ArgumentError, "usage value must be non-negative" if integer.negative?

      integer
    end

    def optional_nonnegative_number(value)
      return nil if value.nil?

      number = Float(value)
      raise ArgumentError, "usage value must be non-negative" if number.negative?

      number
    end

    def optional_boolean(value)
      return nil if value.nil?
      return value if value == true || value == false

      raise ArgumentError, "usage inclusion value must be true, false, or nil"
    end

    def hash_value(hash, key)
      hash.key?(key) ? hash[key] : hash[key.to_s]
    end

    def split_route(value)
      string = value.to_s
      return [ nil, nil ] unless string.include?("/")

      string.split("/", 2)
    end

    def optional_time(value)
      value.nil? ? nil : normalize_time(value)
    end

    def normalize_time(value)
      (value.respond_to?(:utc) ? value.utc : Time.iso8601(value.to_s).utc).iso8601(6)
    end
  end
end
