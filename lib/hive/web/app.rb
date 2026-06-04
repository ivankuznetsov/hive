require "erb"
require "json"
require "securerandom"
require "sinatra/base"
require "rack/protection"
require "hive/config"
require "hive/web/session_secret"
require "hive/web/github_auth"
require "hive/web/status_feed"
require "hive/web/dispatcher"
require "hive/web/agents_auth"

module Hive
  module Web
    class App < Sinatra::Base
      set :root, File.expand_path("../../..", __dir__)
      set :views, File.expand_path("views", __dir__)
      set :public_folder, File.expand_path("../../../public", __dir__)
      set :show_exceptions, false
      set :raise_errors, false

      configure do
        cfg = Hive::Config.load_global_web
        set :web_config, cfg
        set :github_auth, Hive::Web::GithubAuth.new(config: cfg)
        set :status_feed, Hive::Web::StatusFeed.new
        set :dispatcher, Hive::Web::Dispatcher.new
        set :agents_auth, Hive::Web::AgentsAuth.new
        set :sessions,
            httponly: true,
            same_site: :lax,
            secure: cfg.fetch("origin").start_with?("https://"),
            secret: Hive::Web::SessionSecret.load_or_create(cfg.fetch("session_secret_file"))
        enable :sessions
        use Rack::Protection, except: :host_authorization
      end

      helpers do
        def h(value)
          Rack::Utils.escape_html(value.to_s)
        end

        def csrf_tag
          token = env["rack.session"][:csrf] ||= SecureRandom.hex(24)
          %(<input type="hidden" name="authenticity_token" value="#{h(token)}">)
        end

        def protected!
          return if request.path_info == "/health"
          return if request.path_info.start_with?("/auth/github")
          return if session[:github_login]

          redirect "/login"
        end

        def verify_csrf!
          return unless request.post? || request.put? || request.delete?
          expected = session[:csrf]
          actual = params["authenticity_token"]
          halt 403, erb(:unauthorized, locals: { message: "Invalid CSRF token" }) unless expected && actual && expected.bytesize == actual.to_s.bytesize && Rack::Utils.secure_compare(expected, actual.to_s)
        end

        def find_project!(name)
          project = Hive::Config.registered_projects.find { |p| p["name"] == name }
          halt 404, "unknown project" unless project
          project
        end
      end

      before do
        protected!
        verify_csrf!
      end

      get("/health") { content_type(:json); JSON.generate(ok: true) }

      get "/login" do
        erb :login
      end

      get "/auth/github" do
        auth = settings.github_auth
        halt 500, "GitHub OAuth is not configured" unless auth.configured?
        state = auth.new_state
        session[:github_oauth_state] = state
        redirect auth.authorize_url(state: state)
      end

      get "/auth/github/callback" do
        halt 403, erb(:unauthorized, locals: { message: "Invalid OAuth state" }) unless params["state"] == session.delete(:github_oauth_state)

        login = settings.github_auth.exchange_code(params.fetch("code"))
        halt 403, erb(:unauthorized, locals: { message: "#{login} is not allowed" }) unless settings.github_auth.owner?(login)

        session[:github_login] = login
        redirect "/"
      end

      post "/logout" do
        session.clear
        redirect "/login"
      end
    end
  end
end

require "hive/web/routes/status"
require "hive/web/routes/actions"
require "hive/web/routes/agents"
require "hive/web/routes/telegram"
require "hive/web/routes/repos"
