module Agents
  class LoginCompletionsController < ApplicationController
    def create
      AgentLogin.find!(params[:session_id], agent: params[:agent]).complete!(params[:code])
      redirect_to agents_path, notice: "Login completed"
    end
  end
end
