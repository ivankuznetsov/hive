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
require "hive/commands/web"

module Hive
  module Web
    class App < Sinatra::Base
      set :root, File.expand_path("../../..", __dir__)
      set :views, File.expand_path("views", __dir__)
      set :public_folder, File.expand_path("../../../public", __dir__)
      set :show_exceptions, false
      set :raise_errors, false

      # Build (or rebuild) the runtime settings from the CURRENT config.yml.
      # Extracted from the `configure` block so tests can `require` the app
      # once (keeping stdlib Coverage's line attribution for the inline route
      # blocks) and then call `reconfigure!` per test to re-read config.yml,
      # instead of `load`-reloading the whole class (which drops Coverage
      # attribution for the reloaded inline route/helper/error blocks).
      def self.apply_runtime_config!
        cfg = Hive::Config.load_global_web
        # Reclaim the previous poller thread before replacing the feed so a
        # per-test reconfigure can't leak background pollers.
        settings.status_feed.stop if settings.respond_to?(:status_feed) && settings.status_feed.respond_to?(:stop)
        set :web_config, cfg
        set :github_auth, Hive::Web::GithubAuth.new(config: cfg)
        set :status_feed, Hive::Web::StatusFeed.new
        set :dispatcher, Hive::Web::Dispatcher.new
        set :agents_auth, Hive::Web::AgentsAuth.new
        set :telegram_validator, Hive::Web::TelegramValidator
        set :telegram_tester, Hive::Web::TelegramTester
        # Cap concurrent SSE streams strictly below Puma's thread pool so
        # open dashboards can't pin every worker thread (see
        # Hive::Web::SseLimiter and Commands::Web::MAX_SSE_STREAMS, which
        # reserves headroom for non-SSE requests).
        set :sse_limiter, Hive::Web::SseLimiter.new(max: Hive::Commands::Web::MAX_SSE_STREAMS)
        # Log-tail cadence + idle ceiling (seconds). Overridable so the SSE
        # log stream releases its thread + slot after a bounded idle period
        # instead of parking forever; tests shrink these to converge fast.
        set :log_stream_tick, 1.0
        set :log_stream_idle_timeout, 60.0
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
        # Guard against double-stacking the middleware: a per-test
        # `reconfigure!` would otherwise push another Rack::Protection onto
        # the middleware list on every call.
        unless @rack_protection_installed
          use Rack::Protection, except: :host_authorization
          @rack_protection_installed = true
        end
      end

      # Re-apply runtime settings against the current config.yml without
      # reloading the class. Used by the test boot path so Coverage keeps
      # attributing the inline routes/helpers/error handlers defined in this
      # class body.
      def self.reconfigure!
        apply_runtime_config!
      end

      configure do
        apply_runtime_config!
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
          project = registered_projects_cached.find { |p| p["name"] == name }
          halt 404, "unknown project" unless project
          project
        end

        # Memoize the registry for the lifetime of one request. A single
        # request can hit `find_project!` and `task_row` (which also reads the
        # registry via the snapshot) repeatedly; without this each call
        # re-globs the filesystem and re-parses config.yml. Scoped to `env` so
        # the value never leaks across requests (the registry can change
        # between them).
        def registered_projects_cached
          env["hive.registered_projects"] ||= Hive::Config.registered_projects
        end
      end

      before do
        protected!
        verify_csrf!
      end

      # An InvalidTaskPath means an unknown agent session / missing task — a
      # not-found, not an unprocessable request. Map it to 404 BEFORE the
      # catch-all below (which would otherwise label it 422). Registered
      # before the broader handler so Sinatra's most-specific-match wins.
      error Hive::InvalidTaskPath do
        status 404
        erb :unauthorized, locals: { message: "Not found: #{env["sinatra.error"].message}" }
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
        # Require a non-empty stored state that secure-compares against the
        # supplied one. A bare `stored == supplied` passes when BOTH are nil
        # (no OAuth flow ever started), defeating the CSRF/state check; demand
        # a real stored value and constant-time compare it.
        stored = session.delete(:github_oauth_state)
        supplied = params["state"].to_s
        valid_state = stored && !stored.empty? && Rack::Utils.secure_compare(stored, supplied)
        halt 403, erb(:unauthorized, locals: { message: "Invalid OAuth state" }) unless valid_state

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
