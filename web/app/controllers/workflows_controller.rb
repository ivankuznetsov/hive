class WorkflowsController < ApplicationController
  PREVIEW_PURPOSE = "hive-web-workflow-lifecycle".freeze
  PREVIEW_TTL = 15.minutes

  def index
    load_page
  end

  def create
    project = project_from_param!
    result = workflow_lifecycle.scaffold(
      project,
      id: params.require(:id),
      template: params[:template].presence || Hive::Commands::Workflow::DEFAULT_TEMPLATE
    )
    redirect_to workflows_path(project: project.name),
                notice: "Created #{result.fetch('id')} for #{project.name}."
  end

  def preview_install
    project = project_from_param!
    source = params.require(:source).to_s.strip
    @preview = workflow_lifecycle.preview_install(project, source: source)
    @preview_operation = "install"
    @preview_token = sign_preview(
      "operation" => @preview_operation,
      "project" => project.name,
      "source" => source,
      "expected" => @preview.slice(
        "name", "version", "catalog_commit", "source_commit", "manifest_digest",
        "configuration_digest"
      )
    )
    load_page(project)
    render :index, formats: :html, content_type: "text/html"
  end

  def install
    require_consent!("install")
    receipt = verify_preview!("install")
    project = find_project!(receipt.fetch("project"))
    result = workflow_lifecycle.install(
      project, source: receipt.fetch("source"), expected: receipt.fetch("expected")
    )
    redirect_with_workflow_result(
      workflows_path(project: project.name), result: result,
      notice: "#{result.fetch('name')} #{workflow_status_message(result)}."
    )
  end

  def preview_update
    project = project_from_param!
    name = params.require(:name).to_s
    @preview = workflow_lifecycle.preview_update(project, name: name)
    if @preview.fetch("status") == "already_current"
      return redirect_to workflows_path(project: project.name),
                         notice: "#{name} is already current."
    end

    @preview_operation = "update"
    @preview_token = sign_preview(
      "operation" => @preview_operation,
      "project" => project.name,
      "name" => name,
      "escalation" => @preview.dig("diff", "escalation") == true,
      "expected" => @preview.slice(
        "from_commit", "from_manifest_digest", "from_configuration_digest",
        "to_commit", "manifest_digest", "configuration_digest"
      )
    )
    load_page(project)
    render :index, formats: :html, content_type: "text/html"
  end

  def update
    require_consent!("update")
    receipt = verify_preview!("update")
    if receipt["escalation"] && params[:allow_escalation] != "1"
      raise Hive::Error, "confirm the separately disclosed security escalation before updating"
    end

    project = find_project!(receipt.fetch("project"))
    result = workflow_lifecycle.update(
      project,
      name: receipt.fetch("name"),
      expected: receipt.fetch("expected"),
      allow_escalation: receipt["escalation"] == true
    )
    redirect_with_workflow_result(
      workflows_path(project: project.name), result: result,
      notice: "#{result.fetch('name')} #{workflow_status_message(result)}."
    )
  end

  def preview_remove
    project = project_from_param!
    name = params.require(:name).to_s
    @preview = workflow_lifecycle.preview_remove(project, name: name)
    @preview_operation = "remove"
    @preview_token = sign_preview(
      "operation" => @preview_operation,
      "project" => project.name,
      "name" => name,
      "expected" => @preview.slice("source_commit", "manifest_digest", "configuration_digest")
    )
    load_page(project)
    render :index, formats: :html, content_type: "text/html"
  end

  def remove
    require_consent!("remove")
    receipt = verify_preview!("remove")
    project = find_project!(receipt.fetch("project"))
    result = workflow_lifecycle.remove(
      project, name: receipt.fetch("name"), expected: receipt.fetch("expected")
    )
    redirect_with_workflow_result(
      workflows_path(project: project.name), result: result,
      notice: "#{result.fetch('name')} removed for new tasks; " \
              "#{result.fetch('retained_commits').length} task-pinned generation(s) retained."
    )
  end

  private

  def load_page(selected = nil)
    @projects = registered_projects
    @selected_project = selected || selected_project
    @workflows = @selected_project ? workflow_lifecycle.list(@selected_project) : []
    @templates = workflow_lifecycle.templates
  end

  def selected_project
    requested = params[:project].to_s.strip
    return find_project!(requested) unless requested.empty?
    return @projects.first if @projects.one?

    nil
  end

  def project_from_param!
    find_project!(params.require(:project).to_s)
  end

  def sign_preview(payload)
    preview_verifier.generate(payload, expires_in: PREVIEW_TTL, purpose: PREVIEW_PURPOSE)
  end

  def verify_preview!(operation)
    payload = preview_verifier.verify(params.require(:preview_token), purpose: PREVIEW_PURPOSE)
    unless payload.is_a?(Hash) && payload["operation"] == operation
      raise Hive::Error, "workflow preview does not match this action; review it again"
    end

    payload
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    raise Hive::Error, "workflow preview expired or changed; review it again before applying"
  end

  def preview_verifier
    Rails.application.message_verifier(:workflow_lifecycle)
  end

  def require_consent!(operation)
    return if params[:consent] == "workflow_#{operation}"

    raise Hive::Error, "confirm the reviewed workflow #{operation} from the Workflows page"
  end

  def workflow_status_message(result)
    case result.fetch("status")
    when "installed" then "installed"
    when "already_installed" then "was already installed"
    when "updated" then "updated"
    when "already_current" then "was already current"
    else result.fetch("status").tr("_", " ")
    end
  end

  def redirect_with_workflow_result(path, result:, notice:)
    options = { notice: notice }
    warnings = Array(result["warnings"])
    unless warnings.empty?
      options[:alert] = "Workflow change completed with warnings: #{warnings.join('; ')}"
    end
    redirect_to path, **options
  end

  def workflow_lifecycle
    self.class.workflow_lifecycle
  end

  class << self
    def workflow_lifecycle
      @workflow_lifecycle ||= Hive::Web::WorkflowLifecycle.new
    end
  end
end
