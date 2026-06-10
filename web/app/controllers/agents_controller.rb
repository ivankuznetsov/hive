# The agent OAuth relay: Hive::Web::AgentsAuth runs the real CLI login in a
# PTY (ADR-035); these actions are a thin HTTP shell over it. One AgentsAuth
# instance per process — login sessions live in its mutex-guarded map.
class AgentsController < ApplicationController
  def index
    @statuses = agents_auth.statuses
  end

  def start_login
    # `start` bounded-waits for the authorize URL, so the redirect target
    # usually already carries the provider link.
    login = agents_auth.start(params[:agent])
    redirect_to agent_login_status_path(params[:agent], login.id)
  end

  # The waiting view inside a polled turbo-frame: re-renders until the
  # authorize URL is captured, then shows it plus the code form.
  def login_status
    @login_session = agents_auth.session(params[:session_id])
    raise Hive::InvalidTaskPath, "unknown login session" unless @login_session

    @session_output = agents_auth.output_for(@login_session.id)
    @session_url = agents_auth.url_for(@login_session.id)
    @statuses = agents_auth.statuses
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

  private

  def agents_auth
    self.class.agents_auth
  end

  class << self
    def agents_auth
      @agents_auth ||= Hive::Web::AgentsAuth.new
    end
  end
end
