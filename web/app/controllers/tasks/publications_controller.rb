class Tasks::PublicationsController < Tasks::BaseController
  def show
    render_publication(cache: publication_cache_for_current_credential)
  end

  def create
    if @task_source
      raise Hive::Error, "archived task publication observations are read-only"
    end

    token = session[:github_token].to_s
    if token.empty?
      @refresh_notice = "Connect GitHub before refreshing remote publication state."
      return render_publication(cache: nil)
    end

    cache = publication_cache_for(token)
    initial = @task.publication(cache: cache)
    identity = initial.dig("refresh", "identity")
    if identity
      limits = Hive::TaskWorkspace::Limits.new
      cache.refresh(identity) do
        GithubApi.new(token).pull_request(
          repository: identity.fetch("repository"),
          number: identity.fetch("number"),
          expected_head: identity.fetch("expected_head"),
          max_bytes: limits.fetch(:github_response_bytes),
          checks_limit: limits.fetch(:github_checks)
        )
      end
    else
      @refresh_notice = "Publication identity is incomplete or conflicting; remote state was not queried."
    end
    render_publication(cache: cache)
  end

  private

  def render_publication(cache:)
    @publication = @task.publication(cache: cache)
    @publication_refresh_available = @task_source.nil? &&
                                     session[:github_token].present? &&
                                     @publication.dig("refresh", "eligible")
    respond_to do |format|
      format.html { render "tasks/publications/show" }
      format.json { render json: @publication }
    end
  end
end
