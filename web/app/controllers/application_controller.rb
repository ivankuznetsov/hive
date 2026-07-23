require "hive/web/environment"

class ApplicationController < ActionController::Base
  # Rails 8 enables forgery protection by default; explicit so static
  # scanners (and readers) see the contract without chasing framework
  # defaults.
  protect_from_forgery with: :exception
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :require_login

  helper_method :current_login, :operator_access?, :operator_label,
                :local_web_mode?, :local_loopback_request?, :web_product_name

  # Hive's typed errors are operator-readable by design ("task not in stage",
  # "invalid clone URL"). Render them on an error page instead of a blank
  # 500 — the web tier's contract since the Sinatra version. Order matters:
  # rescue_from matches the LAST registered handler first, so the specific
  # InvalidTaskPath (a Hive::Error subclass → 404) must come AFTER the
  # generic 422 handler or it would never fire.
  # NOT bare KeyError: that would reclassify programming errors anywhere in
  # a request as 422 user errors. TaskMutations#run! turns unknown submitted
  # actions into Hive::Error before looking up the canonical verb;
  # ParameterMissing (a KeyError subclass) is a genuine user error.
  rescue_from Hive::Error, ActionController::ParameterMissing do |e|
    render_typed_error(:unprocessable_entity, "Action failed", e.message)
  end

  rescue_from Hive::InvalidTaskPath do |e|
    render_typed_error(:not_found, "Not found", e.message)
  end

  private

  # Hive's typed errors render an HTML error page for browser requests. Binary
  # endpoints (the task media route streams png/jpg/gif) carry a non-HTML
  # request format with no matching errors/show template, so an unknown
  # task/project there must HEAD the status — otherwise the rescue itself
  # raises ActionView::MissingTemplate and the clean 404 becomes a 500.
  def render_typed_error(status, heading, message)
    if request.format.html?
      render "errors/show", status: status, locals: { heading: heading, message: message }
    else
      head status
    end
  end

  def current_login
    session[:github_login]
  end

  # Loopback mode is authenticated by the connection itself rather than a
  # GitHub session. Treat that operator as signed in for navigation while
  # keeping GitHub-specific actions behind an explicit account connection.
  def operator_access?
    current_login.present? || local_loopback_request?
  end

  def operator_label
    current_login.presence || "Local"
  end

  def local_web_mode?
    Hive::Web::Environment.boolean("HIVE_WEB_LOCAL_LOOPBACK")
  end

  def web_product_name
    return "hive" if local_web_mode?
    return "hivebox" if ENV["HIVEBOX_PRECOMPILED_ASSETS"] == "1"

    "Hive web"
  end

  def require_login
    return if local_loopback_request?
    return redirect_to login_path unless current_login

    # Sessions must track the CURRENT owner, not the owner at sign-in time:
    # rotating web.github.owner (or re-claiming an instance) would otherwise leave
    # old sessions alive with repo-scoped credentials. The dev/test seam
    # signs in arbitrary logins, so it is exempt only where real GitHub auth
    # is (local envs).
    auth = Hive::Web::GithubAuth.new(config: Hive::Config.load_global_web)
    return if auth.owner?(current_login)
    return if Rails.env.local? && session[:github_token].blank?

    reset_session
    redirect_to login_path, alert: "Signed out: this Hive web instance's owner changed."
  end

  # Hive::Web::Loopback is the same test the CLI bind policy uses, so the
  # "which addresses count as loopback" rule can't drift between the tier
  # that sets HIVE_WEB_LOCAL_LOOPBACK and the tier that honors it. Both the
  # socket peer and Host must be loopback: a localhost proxy may connect from
  # loopback for an arbitrary public hostname, but that request belongs behind
  # the GitHub owner gate rather than the local no-auth boundary.
  def local_loopback_request?
    return false unless local_web_mode?

    # Trust the socket peer and literal Host, not ActionDispatch's
    # proxy-expanded remote_ip/request.host values. request.host prefers
    # X-Forwarded-Host, which is client-spoofable when a proxy preserves it.
    Hive::Web::Loopback.address?(request.get_header("REMOTE_ADDR")) &&
      Hive::Web::Loopback.address?(literal_request_host)
  end

  # Extract only the authority sent in the actual Host header. The strict
  # shape rejects userinfo and other URI syntax while normalizing the optional
  # port and brackets that HTTP requires around an IPv6 literal.
  def literal_request_host
    authority = request.get_header("HTTP_HOST").to_s
    match = authority.match(/\A(?:\[([^\]]+)\]|([^:]+))(?::\d+)?\z/)
    match && (match[1] || match[2])
  end

  def registered_projects
    @registered_projects ||= Project.all
  end

  def find_project!(name)
    Project.find!(name, projects: registered_projects)
  end
end
