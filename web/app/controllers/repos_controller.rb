class ReposController < ApplicationController
  def index
    @projects = registered_projects
    registered_names = @projects.map(&:name).to_set
    @github_repos = session[:github_token] ? github_repositories(registered_names) : nil
  end

  def new
    @url = params[:url].to_s.strip
    raw_project = params[:project].to_s.strip
    @project_name = raw_project.present? ? File.basename(raw_project) : nil
    @suggested_name = params[:name].to_s.strip.presence ||
                      (@project_name || File.basename(@url).delete_suffix(".git") if @url.present? || @project_name)
    @defaults = InitSetup.defaults
    @workflows = InitSetup.workflows
    @current_workflow = Hive::Workflows::CODING_ID.to_s

    project = @project_name && registered_projects.find { |entry| entry.name == @project_name }
    return unless project

    @workflows = project.workflows
    @current_workflow = project.default_workflow || @current_workflow
  end

  def create
    setup = InitSetup.new(params[:settings])
    workflow = InitSetup.workflow(params.dig(:settings, :workflow))
    return setup_existing_project(setup, workflow) if params[:project].present?

    registration = Repository.new(
      source: params[:url], name: params[:name], token: session[:github_token]
    ).register!(setup:, workflow:)
    redirect_after_init("#{registration.project.name} is registered", registration.warning)
  end

  private

  def setup_existing_project(setup, workflow)
    project = find_project!(File.basename(params[:project].to_s.strip))
    warning = project.setup!(setup, workflow:)
    redirect_after_init("#{project.name} settings applied", warning)
  end

  def redirect_after_init(notice, warning)
    options = { notice: }
    if warning
      Rails.logger.warn("web init completed with provisioning findings: #{warning.squish}")
      options[:alert] = "Project setup completed with agent-skill findings: #{warning}"
    end
    redirect_to repos_path, **options
  end

  def github_repositories(registered_names)
    GithubApi.new(session[:github_token]).repositories.map do |repo|
      {
        "full_name" => repo["full_name"],
        "name" => repo["name"],
        "description" => repo["description"],
        "private" => repo["private"],
        "language" => repo["language"],
        "pushed_at" => repo["pushed_at"],
        "registered" => registered_names.include?(repo["name"])
      }
    end
  rescue Hive::Error => e
    @github_error = e.message
    nil
  end
end
