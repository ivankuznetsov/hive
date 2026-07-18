# The agent OAuth relay: Hive::Web::AgentsAuth runs the real CLI login in a
# PTY (ADR-035); these actions are a thin HTTP shell over it. One AgentsAuth
# instance per process — login sessions live in its mutex-guarded map.
class AgentsController < ApplicationController
  def index
    load_agents_page
  end

  def start_login
    # `start` bounded-waits for the authorize URL, so the redirect target
    # usually already carries the provider link.
    login = agents_auth.start(params[:agent])
    redirect_to agent_login_status_path(params[:agent], login.id)
  end

  # The waiting view inside a polled turbo-frame. For paste-back agents it
  # re-renders until the authorize URL is captured, then shows the code form.
  # For operator-ward (poll-type) agents it keeps polling until the CLI exits,
  # so the page reflects completion without the operator pasting anything.
  def login_status
    @login_session = agents_auth.session(params[:session_id])
    raise Hive::InvalidTaskPath, "unknown login session" unless @login_session

    @session_output = agents_auth.output_for(@login_session.id)
    @session_url = agents_auth.url_for(@login_session.id)
    @poll_login = agents_auth.poll_login?(@login_session.agent)
    load_agents_page
    render :index
  end

  def complete_login
    agents_auth.complete(params[:session_id], params[:code])
    redirect_to agents_path, notice: "Login completed"
  end

  def save_pi_token
    agents_auth.write_pi_token(params[:token_json])
    redirect_to agents_path, notice: "pi token saved"
  end

  def repair_skills
    project = find_project!(params[:project].to_s.strip)
    unless params[:consent] == "repair_managed_skills"
      raise Hive::Error, "confirm the managed skill repair from the Agents page"
    end

    result = agent_skills.repair(project)
    project_name = project.fetch("name")
    if result.fetch("exit_code", 1).to_i.zero?
      redirect_to agents_path(project: project_name),
                  notice: "Managed agent skills are ready for #{project_name}."
    else
      redirect_to agents_path(project: project_name),
                  alert: "Skill setup finished with remaining issues for #{project_name}. Review the health details below."
    end
  end

  private

  def load_agents_page
    @statuses = agents_auth.statuses
    @projects = registered_projects
    project_name = params[:project].to_s.strip
    return if project_name.empty?

    @selected_project = find_project!(project_name)
    @skill_health = agent_skills.inspect(@selected_project)
  end

  def agents_auth
    self.class.agents_auth
  end

  def agent_skills
    self.class.agent_skills
  end

  class << self
    def agents_auth
      @agents_auth ||= Hive::Web::AgentsAuth.new
    end

    def agent_skills
      @agent_skills ||= Hive::Web::AgentSkills.new
    end
  end
end
