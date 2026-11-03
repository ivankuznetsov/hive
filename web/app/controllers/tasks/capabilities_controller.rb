require "hive/task_capabilities/revision"

class Tasks::CapabilitiesController < Tasks::BaseController
  include CapabilityInputs

  rescue_from Hive::TaskCapabilities::Admission::Error do |error|
    capabilities = Hive::TaskCapabilities::Projection.new(task: @native_task, cfg: @project.config, project: @project.name).call
    if request.format.turbo_stream?
      render turbo_stream: turbo_stream.replace("task-capabilities", partial: "tasks/capabilities", locals: { capabilities: capabilities, error: error }), status: :unprocessable_entity
    else
      render partial: "tasks/capabilities", locals: { capabilities: capabilities, error: error }, status: :unprocessable_entity
    end
  end

  def create
    expected = { expected_identity: JSON.parse(params.require(:identity)),
      expected_version: Integer(params.require(:plan_version)), expected_sha: params.require(:sha) }
    service = Hive::TaskCapabilities::Revision.new(task: @native_task)
    case params[:operation]
    when "accept"
      service.accept(proposal_digest: params.require(:proposal), **expected)
    when "reject"
      service.reject(proposal_digest: params.require(:proposal), reason: params[:reason].to_s, **expected)
    when "waive"
      service.waive(reason: params.require(:reason), checks: Array(params[:checks]), **expected)
    when "risk-accept"
      service.risk_accept(result_digest: params.require(:result), finding_ids: Array(params[:findings]), reason: params.require(:reason), **expected)
    when "propose"
      service.propose(selections: capability_pairs(:capabilities),
        approval_references: capability_pairs(:capability_approvals), task_approvals: capability_pairs(:task_approvals),
        verification_plans: params[:verification_plan].present? ? JSON.parse(params[:verification_plan]) : {},
        reason: params[:reason].to_s, checks: Array(params[:checks]), **expected)
    end
    redirect_to task_path(@project.name, @task.slug), notice: "Capability decision recorded"
  rescue JSON::ParserError, ArgumentError => error
    raise Hive::TaskCapabilities::Admission::Error.new("invalid capability correction: #{error.message}", reason: "task_capability_invalid_selection")
  end
end
