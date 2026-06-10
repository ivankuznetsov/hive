require "open3"

class ReposController < ApplicationController
  # Accepted clone sources: a github.com https/ssh URL or `owner/repo`
  # gh shorthand. Open3 array form blocks shell injection; the regexes and
  # the leading-dash guard block argument injection and arbitrary hosts.
  GITHUB_URL_RE = %r{\Ahttps://github\.com/[\w.-]+/[\w.-]+?(?:\.git)?\z}
  GITHUB_SSH_RE = %r{\Agit@github\.com:[\w.-]+/[\w.-]+?(?:\.git)?\z}
  GH_SHORTHAND_RE = %r{\A[\w.-]+/[\w.-]+\z}

  def index
    @projects = registered_projects
    registered_names = @projects.map { |p| p["name"] }.to_set
    # The device-flow grant carries `repo` scope, so the operator's own
    # repositories list directly — no separate GitHub configuration.
    @github_repos = session[:github_token] ? github_repositories(registered_names) : nil
  end

  # The setup questionnaire — the web equivalent of `hive init`'s TTY
  # prompts. Reached from the clone form, a GitHub repo's "Add to hive",
  # or a registered project's "Re-run setup".
  def new
    @url = params[:url].to_s.strip
    @project_name = params[:project].to_s.strip.presence
    @suggested_name = params[:name].to_s.strip.presence ||
                      (@project_name || File.basename(@url).delete_suffix(".git") if @url.present? || @project_name)
    @defaults = InitSetup.defaults
  end

  def create
    if params[:project].present?
      # Re-run setup for an already-registered project (no clone).
      project = find_project!(File.basename(params[:project].to_s.strip))
      reinit!(project["path"], InitSetup.new(params[:settings]))
      return redirect_to repos_path, notice: "#{project["name"]} settings applied"
    end

    url = params[:url].to_s.strip
    raise Hive::Error, "repo URL required" if url.empty?
    raise Hive::Error, "invalid repo URL — use a github.com URL or owner/repo" unless valid_repo_url?(url)

    name = params[:name].to_s.strip
    name = File.basename(url).delete_suffix(".git") if name.empty?
    # File.basename strips path segments so `../` can't escape the root.
    name = File.basename(name)
    raise Hive::Error, "invalid repo name" if name.empty? || name == "." || name == ".."

    # The container sets HIVEBOX_REPOS_DIR=/data/repos; a host run (dev
    # checkout) keeps clones under hive's data home instead of assuming a
    # /data mount exists.
    root = ENV["HIVEBOX_REPOS_DIR"] || File.join(Hive::Paths.data_home, "repos")
    FileUtils.mkdir_p(root)
    target = File.join(root, name)

    setup = InitSetup.new(params[:settings])
    clone!(url, target) unless File.directory?(target)
    reinit!(target, setup)
    redirect_to repos_path, notice: "#{name} is registered"
  end

  private

  # The InitSetup adapter rides Init's `prompts:` seam, so a web setup is
  # indistinguishable from an interactive `hive init`.
  def reinit!(target, setup)
    Hive::Commands::Init.new(target, force: true, json: false, prompts: setup).call
  end

  # Clone via `gh` with the operator's device-flow token in GH_TOKEN, so
  # private repos clone with the session grant — the box needs no separate
  # `gh auth login` for repos the operator owns. Falls back to the box's own
  # gh auth when no session token exists (e.g. token-less curl admin).
  def clone!(url, target)
    env = session[:github_token] ? { "GH_TOKEN" => session[:github_token] } : {}
    out, err, status = Open3.capture3(env, "gh", "repo", "clone", url, target)
    raise Hive::Error, "clone failed: #{[ out, err ].join("\n").strip}" unless status.success?
  end

  def github_repositories(registered_names)
    GithubApi.new(session[:github_token]).repositories.map do |repo|
      {
        "full_name" => repo["full_name"],
        "name" => repo["name"],
        "description" => repo["description"],
        "private" => repo["private"],
        "language" => repo["language"],
        "pushed_at" => repo["pushed_at"],
        "registered" => registered_names.include?(repo["name"])
      }
    end
  rescue Hive::Error => e
    # The repos page must still render the registered list when GitHub is
    # unreachable or the token grant was revoked — degrade to a notice.
    @github_error = e.message
    nil
  end

  def valid_repo_url?(url)
    return false if url.start_with?("-")

    GITHUB_URL_RE.match?(url) || GITHUB_SSH_RE.match?(url) || GH_SHORTHAND_RE.match?(url)
  end
end
