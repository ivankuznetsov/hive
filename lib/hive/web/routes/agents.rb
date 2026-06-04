module Hive
  module Web
    class App < Sinatra::Base
      get "/agents" do
        @statuses = settings.agents_auth.statuses
        @sessions = {}
        erb :agents
      end

      post "/agents/:agent/login/start" do
        @session = settings.agents_auth.start(params["agent"])
        @statuses = settings.agents_auth.statuses
        erb :agents
      end

      post "/agents/:agent/login/complete" do
        settings.agents_auth.complete(params["session_id"], params["code"])
        redirect "/agents"
      end

      post "/agents/pi/token" do
        settings.agents_auth.write_pi_token(params["token_json"])
        redirect "/agents"
      end
    end
  end
end
