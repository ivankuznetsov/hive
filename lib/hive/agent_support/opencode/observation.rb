module Hive::AgentSupport::OpenCode::Observation
  module_function

  def build(selected:, stage:, generation:, requested_route:, actual_route:,
            resolution_status:, outcome_kind:, usage:)
    requested = AgentCliRuntime::Route.parse(requested_route)
    unless requested.to_s == selected.fetch("model")
      raise Hive::ImplementationIdentity::InvalidIdentity,
            "observed requested route does not match persisted implementation identity"
    end
    identity = AgentCliRuntime::RouteIdentity.new(
      requested:, actual: actual_route, resolution_status:
    )
    validate_identity!(identity)
    kind = outcome_kind.to_sym
    unless AgentCliRuntime::KINDS.include?(kind)
      raise Hive::ImplementationIdentity::InvalidIdentity,
            "invalid OpenCode outcome kind #{outcome_kind.inspect}"
    end
    normalized_usage = normalize_usage(usage)
    {
      "stage" => stage,
      "generation" => generation,
      "requested_backend" => identity.requested.provider,
      "requested_model" => identity.requested.model,
      "actual_backend" => identity.actual&.provider,
      "actual_model" => identity.actual&.model,
      "route_resolution_status" => identity.resolution_status.to_s,
      "outcome_kind" => kind.to_s,
      "usage" => normalized_usage&.to_h&.transform_keys(&:to_s)
    }.freeze
  rescue ArgumentError => error
    raise Hive::ImplementationIdentity::InvalidIdentity,
          "invalid OpenCode observation: #{error.message}", cause: error
  end

  def provenance(observation)
    {
      "reason" => "opencode_route_observed",
      "source" => observation["actual_backend"] ?
        "opencode_sanitized_export" : "opencode_run",
      "namespace" => "opencode-observation"
    }.freeze
  end

  def validate_identity!(identity)
    valid = case identity.resolution_status
    when :unobserved
      identity.actual.nil?
    when :matched
      identity.actual == identity.requested
    when :resolved_differently
      !identity.actual.nil? && identity.actual != identity.requested
    end
    return if valid

    raise Hive::ImplementationIdentity::InvalidIdentity,
          "OpenCode route resolution status contradicts observed route evidence"
  end

  def normalize_usage(usage)
    return if usage.nil?
    return usage if usage.is_a?(AgentCliRuntime::NormalizedUsage)

    values = Hive::StringifyKeys.call(usage)
    allowed = %w[input output cache_read cache_write reasoning cost]
    unknown = values.keys - allowed
    unless unknown.empty?
      raise Hive::ImplementationIdentity::InvalidIdentity,
            "unknown OpenCode usage fields: #{unknown.sort.join(', ')}"
    end
    AgentCliRuntime::NormalizedUsage.new(
      **allowed.to_h { |key| [ key.to_sym, values[key] ] }
    )
  end

  private_class_method :validate_identity!, :normalize_usage
end
