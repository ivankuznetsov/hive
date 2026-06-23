require "open3"
require "tempfile"

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
    raw_project = params[:project].to_s.strip
    # File.basename strips path segments so a crafted `project` param can't walk
    # out of the registered-projects lookup below — mirrors create's hardening.
    @project_name = raw_project.present? ? File.basename(raw_project) : nil
    @suggested_name = params[:name].to_s.strip.presence ||
                      (@project_name || File.basename(@url).delete_suffix(".git") if @url.present? || @project_name)
    @defaults = InitSetup.defaults
    @workflows = InitSetup.workflows
    @current_workflow = Hive::Workflows::CODING_ID.to_s

    project = @project_name && registered_projects.find { |entry| entry["name"] == @project_name }
    return unless project

    @workflows = InitSetup.workflows(project["path"])
    @current_workflow = persisted_default_workflow(project) || @current_workflow
  end

  def create
    selected_workflow = params.dig(:settings, :workflow).presence
    if params[:project].present?
      # Re-run setup for an already-registered project (no clone).
      project = find_project!(File.basename(params[:project].to_s.strip))
      reinit!(project["path"], InitSetup.new(params[:settings]), workflow: selected_workflow)
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

    # A non-directory at the target (stray file, symlink) must be a hard
    # stop: clone! deletes `target` on failure, and "clone over whatever is
    # there" would turn that cleanup into deleting something we don't own.
    if File.exist?(target) && !File.directory?(target)
      raise Hive::Error, "#{name} already exists under the repos root and is not a directory — remove it first"
    end

    setup = InitSetup.new(params[:settings])
    clone!(url, target) unless File.directory?(target)
    normalize_origin!(target)
    reinit!(target, setup, workflow: selected_workflow)
    redirect_to repos_path, notice: "#{name} is registered"
  end

  private

  # The persisted `default_workflow` for a registered project's re-run form, or
  # nil when none is set. A corrupt/unreadable config.yml degrades to nil (the
  # caller then falls back to coding) — matching the InitSetup.workflows list
  # rendered just above, which already survives the same broken file via its own
  # fallback — rather than letting an unrescued Psych::Exception 500 the very
  # form an operator opens to repair the project. Mirrors
  # tasks_controller#project_daemon_enabled?'s rescue-and-degrade pattern;
  # Config.load (lib/hive/config.rb) does not rescue Psych and
  # ApplicationController only rescues Hive::Error/ParameterMissing.
  def persisted_default_workflow(project)
    Hive::Config.load(project["path"])["default_workflow"].presence
  rescue StandardError => e
    Rails.logger.warn("default_workflow unreadable for #{project["name"]}: #{e.class}: #{e.message}")
    nil
  end

  # The InitSetup adapter rides Init's `prompts:` seam, so a web setup is
  # indistinguishable from an interactive `hive init`.
  def reinit!(target, setup, workflow: nil)
    Hive::Commands::Init.new(target, force: true, json: false, prompts: setup, workflow: workflow).call
  end

  # A hung clone (slow network, wedged gh) would otherwise hold a Puma
  # worker forever; the box has few. Env-overridable for tests.
  CLONE_TIMEOUT_SEC = Integer(ENV.fetch("HIVEBOX_CLONE_TIMEOUT_SEC", 180))

  # Clone via `gh` with the operator's device-flow token in GH_TOKEN, so
  # private repos clone with the session grant — the box needs no separate
  # `gh auth login` for repos the operator owns. Falls back to the box's own
  # gh auth when no session token exists (e.g. token-less curl admin).
  # Runs in its own process group with a hard deadline; a timed-out or
  # failed clone removes the partial target so a retry starts clean.
  def clone!(url, target)
    # Refuse rather than risk the failure-path cleanup deleting something
    # that existed before this request (create already filters, but clone!
    # must be safe on its own).
    raise Hive::Error, "clone target already exists: #{File.basename(target)}" if File.exist?(target)

    env = session[:github_token] ? { "GH_TOKEN" => session[:github_token] } : {}
    log = Tempfile.create("hivebox-clone")
    pid = Process.spawn(env, "gh", "repo", "clone", url, target,
                        pgroup: true, out: log.path, err: log.path)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + CLONE_TIMEOUT_SEC
    status = nil
    loop do
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      break if status

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Process.kill("KILL", -pid) rescue nil
        Process.waitpid2(pid) rescue nil
        FileUtils.rm_rf(target)
        raise Hive::Error, "clone timed out after #{CLONE_TIMEOUT_SEC}s — "                            "check the network and try again"
      end
      sleep 0.2
    end
    return if status.success?

    FileUtils.rm_rf(target)
    raise Hive::Error, "clone failed: #{File.read(log.path).strip}"
  ensure
    log&.close
    File.unlink(log.path) if log && File.exist?(log.path)
  end

  # Registered repos must push over https: at push time git's credential
  # helper reads the box's `gh auth login` (the device-flow session token
  # only powers clone-time GH_TOKEN and is never persisted), while SSH is a
  # dead end here — the
  # container ships no keys, and a host daemon can't answer an interactive
  # agent (1Password and friends). gh clones over ssh whenever the
  # operator's git_protocol prefers it, so rewrite the origin afterwards.
  def normalize_origin!(target)
    out, err, status = Open3.capture3("git", "-C", target, "remote", "get-url", "origin")
    unless status.success?
      # Pre-existing dir with no origin (or not a repo): registration still
      # proceeds, but pushes will fail far from here — leave the breadcrumb.
      Rails.logger.warn("origin not normalized for #{target}: #{err.strip.presence || out.strip}")
      return
    end

    url = out.strip
    https = url.sub(%r{\A(?:ssh://)?git@github\.com[:/]}, "https://github.com/")
    if https == url
      # Non-github ssh remotes survive the rewrite (the allowlist only admits
      # github.com sources, but a pre-existing dir can point anywhere) — and
      # the box only ships push credentials for https://github.com.
      unless url.start_with?("https://github.com/")
        Rails.logger.warn("origin for #{target} is #{url.inspect} — the box can only push to https://github.com remotes")
      end
      return
    end

    _out, err, set_status = Open3.capture3("git", "-C", target, "remote", "set-url", "origin", https)
    raise Hive::Error, "failed to switch origin to https: #{err.strip}" unless set_status.success?
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
