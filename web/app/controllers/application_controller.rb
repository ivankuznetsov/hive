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

  helper_method :current_login

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
    render "errors/show", status: :unprocessable_entity, locals: { heading: "Action failed", message: e.message }
  end

  rescue_from Hive::InvalidTaskPath do |e|
    render "errors/show", status: :not_found, locals: { heading: "Not found", message: e.message }
  end

  private

  def current_login
    session[:github_login]
  end

  def require_login
    return redirect_to login_path unless current_login

    # Sessions must track the CURRENT owner, not the owner at sign-in time:
    # rotating web.github.owner (or re-claiming a box) would otherwise leave
    # old sessions alive with repo-scoped credentials. The dev/test seam
    # signs in arbitrary logins, so it is exempt only where real GitHub auth
    # is (local envs).
    auth = Hive::Web::GithubAuth.new(config: Hive::Config.load_global_web)
    return if auth.owner?(current_login)
    return if Rails.env.local? && session[:github_token].blank?

    reset_session
    redirect_to login_path, alert: "Signed out: this box's owner changed."
  end

  def registered_projects
    @registered_projects ||= Hive::Config.registered_projects
  end

  def find_project!(name)
    registered_projects.find { |p| p["name"] == name } ||
      raise(Hive::InvalidTaskPath, "unknown project #{name}")
  end
end
