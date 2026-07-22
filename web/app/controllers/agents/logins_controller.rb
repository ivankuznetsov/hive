module Agents
  class LoginsController < ApplicationController
    def create
      agent_login = AgentLogin.create!(params[:agent])
      redirect_to agent_login_status_path(agent_login.agent, agent_login.id)
    end

    def show
      @agent_login = AgentLogin.find!(params[:session_id], agent: params[:agent])
    end
  end
end
