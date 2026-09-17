require "action_view"

module HiveDemo
  VIEWS = File.expand_path("views", __dir__)

  class LiveControlError < StandardError; end

  # Rendering context for snapshot pages. Route helpers resolve through the
  # exported route graph; every live action helper fails loudly.
  class View < ActionView::Base.with_empty_template_cache
    include ApplicationHelper
    include Turbo::FramesHelper

    LIVE_HELPERS = %i[
      task_recover_path task_approve_path task_run_path task_reject_path
      task_drop_path task_answers_path task_intervene_path task_plan_review_action_path
      task_publication_path task_evidence_path task_closure_path new_task_closure_path
      login_path logout_path status_view_preference_path ideas_path
      install_workflow_path update_workflow_path remove_workflow_path
      preview_workflow_install_path preview_workflow_update_path preview_workflow_remove_path
      preview_module_install_path preview_module_update_path preview_module_uninstall_path
      preview_module_enable_path preview_module_disable_path
      agents_path telegram_path
    ].freeze

    attr_reader :routes, :snapshot

    def initialize(routes:, snapshot:)
      @routes = routes
      @snapshot = snapshot
      super(ActionView::LookupContext.new([ VIEWS, Rails.root.join("app/views").to_s ]), {}, nil)
    end

    def web_product_name = "Hive"

    def turbo_frame_request? = false

    def root_path = "/"

    def nav_class(section)
      section.to_s == @nav_section.to_s ? "nav-link nav-link-active" : "nav-link"
    end

    def task_path(project, slug, **options)
      path = routes.task_path(project, slug)
      options[:anchor] ? "#{path}##{options[:anchor]}" : path
    end

    def board_path(project: nil, **) = routes.board_path(project)

    def grid_path(project: nil, **) = routes.grid_path(project)

    def archive_path(project: nil, view: nil, **) = routes.archive_path(project, view: view)

    def status_filter_path(**changes)
      project = changes.key?(:project) ? changes[:project] : @selected_project&.name
      state = changes.key?(:state) ? changes[:state] : @task_state
      case @route&.kind
      when :archive
        @route.view == "board" ? routes.done_path(project) : routes.archive_path(project)
      else
        @status_view == "grid" ? routes.grid_path(project, state) : routes.board_path(project, state)
      end
    end

    def repos_path(**) = "/repos"

    def new_repo_path(**) = "/repos"

    def honeycombs_path(project: nil, **) = "/honeycombs/workflows"

    def workflows_path(project: nil, **) = "/honeycombs/workflows"

    def modules_path(project: nil, **) = "/honeycombs/modules"

    def patrol_path(**) = "/patrol"

    def digest_path(date = nil, project: nil, **)
      candidate = "/digest/#{date}"
      routes.include?(candidate) ? candidate : "/digest/#{snapshot.digest.fetch('local_date')}"
    end

    def task_diff_path(project, slug, **) = routes.change_path(project, slug)

    def status_stream_source(**) = raise(LiveControlError, "status stream is not available in the saved snapshot")

    def current_login = nil

    def operator_label = nil

    def operator_access? = false

    LIVE_HELPERS.each do |helper|
      define_method(helper) do |*, **|
        raise LiveControlError, "#{helper} is a live Hive action and cannot run in the saved snapshot"
      end
    end
  end
end
