module CapabilityInputs
  extend ActiveSupport::Concern

  private

  def capability_inputs
    { capabilities: capability_pairs(:capabilities),
      qa_waiver_reason: params[:qa_waiver_reason].presence,
      qa_waiver_checks: Array(params[:qa_waiver_checks]).reject(&:blank?),
      capability_approvals: capability_pairs(:capability_approvals) }
  end

  def capability_pairs(key)
    value = params[key]
    return [] unless value
    raise Hive::TaskCapabilities::Admission::Error.new("#{key} must be named choices", reason: "task_capability_invalid_selection") unless value.is_a?(ActionController::Parameters)
    value.to_unsafe_h.reject { |_id, entry| entry.blank? }.map { |id, entry| "#{id}=#{entry}" }
  end

  def capability_form(project, error: nil)
    inputs = { capabilities: [], qa_waiver_reason: nil, qa_waiver_checks: [], capability_approvals: [] }
    begin
      inputs = capability_inputs
      preview = project.capability_preview(params[:text].to_s, **inputs)
    rescue Hive::TaskCapabilities::Admission::Error => rejection
      error ||= rejection
      # Keep the submitted radio values visible beside their rejection. This
      # baseline supplies the catalog only; it does not replace rejected choices.
      preview = project.capability_preview(params[:text].to_s)
    end
    { preview: preview, selections: inputs.fetch(:capabilities).to_h { |pair| pair.split("=", 2) },
      waiver_reason: inputs[:qa_waiver_reason], waiver_checks: inputs[:qa_waiver_checks],
      approvals: inputs.fetch(:capability_approvals).to_h { |pair| pair.split("=", 2) }, error: error }
  end

  def render_capability_rejection(project, error)
    form = capability_form(project, error: error)
    if request.format.turbo_stream?
      render turbo_stream: turbo_stream.replace("composer-capabilities", partial: "status/composer_capabilities", locals: form), status: :unprocessable_entity
    else
      render partial: "status/composer_capabilities", locals: form, status: :unprocessable_entity
    end
  end
end
