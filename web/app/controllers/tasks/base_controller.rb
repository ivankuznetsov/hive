class Tasks::BaseController < ApplicationController
  require "digest"
  require "hive/task_workspace/builder"
  require "hive/task_workspace/publication_cache"

  before_action :load_project
  before_action :load_task
  before_action :reject_archived_mutation!

  private

  def load_project
    @project = find_project!(params[:project])
  end

  def load_task
    page_snapshot = StatusBroadcaster.current_page_snapshot
    @status_version = page_snapshot&.version
    # With no process-wide fleet snapshot yet, the resolver below still
    # computes this exact task row directly; that is current enough for task
    # controls without forcing a fleet scan. An explicit feed failure remains
    # unavailable/degraded and disables those controls.
    @status_availability = page_snapshot&.availability || "fresh"
    @status_last_success_at = page_snapshot&.last_success_at
    @status_error = page_snapshot&.error
    @status_fresh = @status_availability == "fresh"
    @task_source = "archive" if params[:source] == "archive"
    result = Hive::Web::TaskTargetResolver.new(
      project: @project.attributes,
      slug: params[:slug],
      cached_payload: @task_source ? nil : page_snapshot&.payload,
      archive: @task_source.present?
    ).call
    @native_task = result.native_task
    @task = Task.new(project: @project, attributes: result.attributes)
  end

  def reject_archived_mutation!
    return unless action_name == "create" && @task_source

    raise Hive::Error, "archived tasks are read-only"
  end

  def task_workspace_builder(questions: nil, daemon_enabled: nil)
    Hive::TaskWorkspace::Builder.new(
      task: @task, native_task: @native_task, project: @project.name,
      status_availability: @status_availability,
      status_last_success_at: @status_last_success_at,
      status_error: @status_error,
      dependency_context: StatusBroadcaster.dependency_context_snapshot&.fetch(:context),
      publication_cache: publication_cache_for_current_credential,
      cursor_codec: task_workspace_cursor_codec,
      questions: questions,
      daemon_enabled: daemon_enabled.nil? ? @project.daemon_enabled? : daemon_enabled,
      archive: @task_source.present?
    )
  end

  def task_workspace_cursor_codec
    secret = Digest::SHA256.digest(
      "#{Rails.application.secret_key_base}:hive-task-workspace-timeline"
    )
    Hive::TaskWorkspace::Timeline::CursorCodec.new(secret: secret)
  end

  def publication_cache_for_current_credential
    token = session[:github_token].to_s
    token.empty? ? nil : publication_cache_for(token)
  end

  def publication_cache_for(token)
    principal = Hive::TaskWorkspace::PublicationCache.principal_id(
      token, secret: Rails.application.secret_key_base
    )
    fingerprint = Hive::TaskWorkspace::PublicationCache.project_fingerprint(
      @project.attributes
    )
    Hive::TaskWorkspace::PublicationCache.new(
      principal_id: principal, project_fingerprint: fingerprint
    )
  end
end
