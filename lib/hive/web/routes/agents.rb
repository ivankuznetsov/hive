module Hive
  module Web
    class App < Sinatra::Base
      get "/agents" do
        @statuses = settings.agents_auth.statuses
        erb :agents
      end

      post "/agents/:agent/login/start" do
        # `start` bounded-waits for the authorize URL before returning, so the
        # rendered page usually already carries the provider link.
        @session = settings.agents_auth.start(params["agent"])
        load_session_view(@session.id)
        erb :agents
      end

      # Poll route the login page meta-refreshes to while the authorize URL is
      # still being printed (native HTML refresh — hive is not Rails, so no
      # Turbo). Re-renders the same page until the URL is available.
      get "/agents/:agent/login/:session_id" do
        @session = settings.agents_auth.session(params["session_id"])
        halt 404, "unknown login session" unless @session
        load_session_view(@session.id)
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

      helpers do
        # Read the live session's output/URL under AgentsAuth's mutex and set
        # the statuses, so the agents view never touches the Session struct
        # the reader thread mutates concurrently.
        def load_session_view(session_id)
          @session_output = settings.agents_auth.output_for(session_id)
          @session_url = settings.agents_auth.url_for(session_id)
          @statuses = settings.agents_auth.statuses
        end
      end
    end
  end
end
