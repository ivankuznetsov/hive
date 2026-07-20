class ApplicationController < ActionController::Base
  WORK_VIEWS = %w[board grid].freeze
  # Rails 8 enables forgery protection by default; explicit so static
  # scanners (and readers) see the contract without chasing framework
  # defaults.
  protect_from_forgery with: :exception
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :require_login

  helper_method :current_login, :default_work_view

  # Hive's typed errors are operator-readable by design ("task not in stage",
  # "invalid clone URL"). Render them on an error page instead of a blank
  # 500 — the web tier's contract since the Sinatra version. Order matters:
  # rescue_from matches the LAST registered handler first, so the specific
  # InvalidTaskPath (a Hive::Error subclass → 404) must come AFTER the
  # generic 422 handler or it would never fire.
  # NOT bare KeyError: that would reclassify programming errors anywhere in
  # a request as 422 user errors. The dispatcher owns its verb-map KeyError;
  # ParameterMissing (a KeyError subclass) is a genuine user error.
  rescue_from Hive::Error, ActionController::ParameterMissing do |e|
    render_typed_error(:unprocessable_entity, "Action failed", e.message)
  end

  rescue_from Hive::InvalidTaskPath do |e|
    render_typed_error(:not_found, "Not found", e.message)
  end

  rescue_from Hive::StaleTask do |e|
    if request.format.json?
      render json: {
        error: "stale_task", message: e.message,
        expected_fingerprint: e.expected_fingerprint,
        card: e.current_card
      }, status: :conflict
    else
      render_typed_error(:conflict, "Task changed", e.message)
    end
  end

  private

  # Hive's typed errors render an HTML error page for browser requests. Binary
  # endpoints (the task media route streams png/jpg/gif) carry a non-HTML
  # request format with no matching errors/show template, so an unknown
  # task/project there must HEAD the status — otherwise the rescue itself
  # raises ActionView::MissingTemplate and the clean 404 becomes a 500.
  def render_typed_error(status, heading, message)
    if request.format.json?
      render json: { error: heading.parameterize(separator: "_"), message: message }, status: status
    elsif request.format.html?
      render "errors/show", status: status, locals: { heading: heading, message: message }
    else
      head status
    end
  end

  def current_login
    session[:github_login]
  end

  def default_work_view
    view = cookies.signed[:hive_default_view].to_s
    WORK_VIEWS.include?(view) ? view : "board"
  end

  def require_login
    return if local_loopback_request?
    return authentication_denied unless current_login

    # Sessions must track the CURRENT owner, not the owner at sign-in time:
    # rotating web.github.owner (or re-claiming a box) would otherwise leave
    # old sessions alive with repo-scoped credentials. The dev/test seam
    # signs in arbitrary logins, so it is exempt only where real GitHub auth
    # is (local envs).
    auth = Hive::Web::GithubAuth.new(config: Hive::Config.load_global_web)
    return if auth.owner?(current_login)
    return if Rails.env.local? && session[:github_token].blank?

    reset_session
    authentication_denied(message: "Signed out: this box's owner changed.")
  end

  def authentication_denied(message: "Sign in to continue.")
    if request.format.json?
      render json: { error: "authentication_required", message: message }, status: :unauthorized
    else
      redirect_to login_path, alert: message
    end
  end

  # Hive::Web::Loopback is the same test the CLI bind policy uses, so the
  # "which addresses count as loopback" rule can't drift between the tier
  # that sets HIVEBOX_LOCAL_LOOPBACK and the tier that honors it.
  def local_loopback_request?
    return false unless ENV["HIVEBOX_LOCAL_LOOPBACK"] == "1"

    Hive::Web::Loopback.address?(request.remote_ip)
  end

  def registered_projects
    @registered_projects ||= Hive::Config.registered_projects
  end

  def find_project!(name)
    registered_projects.find { |p| p["name"] == name } ||
      raise(Hive::InvalidTaskPath, "unknown project #{name}")
  end
end
