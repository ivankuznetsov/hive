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
require "hive/web/telegram_validator"
require "hive/web/telegram_tester"
require "hive/web/sse_limiter"

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
        set :telegram_validator, Hive::Web::TelegramValidator
        set :telegram_tester, Hive::Web::TelegramTester
        # Cap concurrent SSE streams so open dashboards can't exhaust Puma's
        # thread pool (see Hive::Web::SseLimiter).
        set :sse_limiter, Hive::Web::SseLimiter.new(max: 64)
        # A truthy Hash for `:sessions` both enables Sinatra's session
        # middleware AND carries the cookie options below. Do NOT follow it
        # with `enable :sessions` — that is `set(:sessions, true)`, which
        # clobbers this Hash, so `setup_sessions` would drop the persisted
        # secret (falling back to a per-boot random one that invalidates all
        # sessions on every restart) and the HttpOnly/SameSite/Secure flags.
        set :sessions,
            httponly: true,
            same_site: :lax,
            secure: cfg.fetch("origin").start_with?("https://"),
            secret: Hive::Web::SessionSecret.load_or_create(cfg.fetch("session_secret_file"))
        # `except: :host_authorization` disables Rack::Protection's
        # Host-header check because the box binds 0.0.0.0 behind the
        # operator's reverse proxy/tunnel, which sets and validates Host.
        # If you expose the raw port without a trusted front proxy, drop
        # this `except:` to restore the DNS-rebinding / Host-injection guard.
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
          # `/login` and `/logout` MUST be exempt: gating `/login` behind
          # `protected!` makes an unauthenticated `GET /login` redirect back
          # to `/login` forever, so the fresh-box GitHub sign-in flow (U2/U9)
          # never renders.
          return if %w[/health /login /logout].include?(request.path_info)
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

      # Any uncaught Hive::Error or KeyError (missing param / config key)
      # raised by approve, dispatch, agents-complete, repos-clone, telegram,
      # or pi-token would otherwise surface as an opaque blank 500 (the app
      # runs with show_exceptions/raise_errors false). Render a readable
      # error page instead — no JS alert, just the message the operator needs.
      error Hive::Error, KeyError do
        status 422
        erb :unauthorized, locals: { message: "Action failed: #{env["sinatra.error"].message}" }
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

        # A denied consent screen (or any GitHub error) comes back as
        # `?error=...&error_description=...` with no `code`. Render a
        # friendly sign-in-failed page instead of a KeyError 500.
        code = params["code"].to_s
        if code.empty?
          reason = [ params["error_description"], params["error"] ].map(&:to_s).find { |s| !s.empty? } || "no authorization code returned"
          halt 403, erb(:unauthorized, locals: { message: "GitHub sign-in failed: #{reason}" })
        end

        login = settings.github_auth.exchange_code(code)
        halt 403, erb(:unauthorized, locals: { message: "#{login} is not allowed" }) unless settings.github_auth.owner?(login)

        # Rotate the session id at the auth boundary. Signed cookies already
        # blunt fixation today, but renewing here keeps the box safe if a
        # server-side session store is ever introduced.
        request.session_options[:renew] = true
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
