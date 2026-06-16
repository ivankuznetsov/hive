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
