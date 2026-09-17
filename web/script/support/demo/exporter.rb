require "json"
require "digest"
require "ostruct"
require "fileutils"
require "pathname"
require "hive/stage_label"
require "hive/secret_patterns"
require_relative "snapshot"
require_relative "routes"
require_relative "static"
require_relative "view"

module HiveDemo
  class Exporter
    LEAK_PATTERNS = {
      "absolute_path" => %r{(?:/home/|/Users/|[A-Za-z]:\\+(?:Users|home)\\+)},
      "operator_name" => /\basterio\b/,
      "excluded_project" => /\b(?:writero|todero|webmail\.sh|rabatafs|hive-private)\b/i,
      "prelaunch_endpoint" => /\bhivedev\.sh\b/,
      "active_content" => /\b(?:javascript:|vbscript:|data:text\/html)|\bon(?:error|load|click)\s*=\s*["']/i,
      "control_bytes" => /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/,
      "email" => /\b[A-Za-z0-9._%+-]+@(?!example\.(?:com|org|net)(?![A-Za-z0-9.-]))[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/
    }.freeze

    TEMPLATES = {
      status: "status/index",
      archive: "status/archive",
      repos: "repos/index",
      workflows: "workflows/index",
      modules: "modules/index",
      patrol: "patrol/index",
      digest: "digests/show",
      task: "tasks/show",
      document: "documents/show",
      change: "tasks/diff",
      unavailable: "unavailable/show"
    }.freeze

    attr_reader :snapshot, :routes

    def initialize(snapshot_root: Snapshot::ROOT, snapshot: nil)
      @snapshot = snapshot || Snapshot.load(snapshot_root)
      @routes = Routes.new(@snapshot)
    end

    def export(destination)
      @destination = Pathname.new(destination)
      FileUtils.rm_rf(@destination)
      FileUtils.mkdir_p(@destination)
      write_assets
      route_manifest = routes.manifest
      route_manifest.each do |record|
        render(routes.fetch(record.fetch("path")))
      end
      write("routes.json", "#{JSON.pretty_generate({
        'schema' => 'hive-demo-routes', 'schema_version' => 1,
        'captured_at' => snapshot.captured_at, 'ui_sha' => snapshot.ui_sha,
        'stylesheet' => @stylesheet,
        'routes' => route_manifest
      })}\n")
      route_manifest
    end

    private

    def render(route)
      view = View.new(routes: routes, snapshot: snapshot)
      assign(view, route)
      content = view.render(template: TEMPLATES.fetch(route.kind))
      sanitized = Static.fragment(content) { |node| validate_links!(route, node) }
      view.content_for(:page_content) { sanitized.html_safe }
      page = view.render(template: "layouts/application", layout: false)
      write(route.page, page)
    end

    def assign(view, route)
      view.assign(
        route: route, snapshot: snapshot, nav_section: route.group,
        captured_at: snapshot.captured_at, ui_sha: snapshot.ui_sha,
        source_note: snapshot.source_note, stylesheet: @stylesheet
      )
      case route.kind
      when :status then assign_status(view, route)
      when :archive then assign_archive(view, route)
      when :repos then assign_repos(view)
      when :workflows then assign_workflows(view)
      when :modules then assign_modules(view)
      when :patrol then assign_patrol(view)
      when :digest then assign_digest(view, route)
      when :task then assign_task(view, route)
      when :document then assign_document(view, route)
      when :change then assign_change(view, route)
      when :unavailable then view.assign(surface: route.group)
      end
    end

    def assign_status(view, route)
      projects = snapshot.projects
      selected = route.project && snapshot.project(route.project)
      visible = selected ? [ selected ] : projects
      counts = visible.flat_map(&:active_tasks)
                      .map { |task| TaskDisplay.new(task, fresh: true).state }
                      .tally
      if route.state
        visible = visible.filter_map do |project|
          rows = project.rows.select do |row|
            row["role"] == "active" && TaskDisplay.new(Task.new(project: project, attributes: row), fresh: true).state == route.state
          end
          next if rows.empty?

          project.with_rows(rows)
        end
      end
      view.assign(
        status_view: route.view || "board", projects: projects, selected_project: selected,
        visible_projects: visible, status_fresh: true, status_display_fresh: true,
        task_state: route.state,
        task_counts: counts,
        board: (board(visible, project_tasks(visible, route.state)) if (route.view || "board") == "board")
      )
    end

    def project_tasks(projects, state)
      projects.flat_map do |project|
        tasks = project.active_tasks
        tasks = tasks.select { |task| TaskDisplay.new(task, fresh: true).state == state } if state
        tasks.map { |task| [ project, task ] }
      end
    end

    def archive_tasks(projects)
      projects.flat_map { |project| project.archived_tasks.map { |task| [ project, task ] } }
    end

    def assign_archive(view, route)
      projects = snapshot.projects
      selected = route.project && snapshot.project(route.project)
      visible = selected ? [ selected ] : projects
      view.assign(
        projects: projects, selected_project: selected,
        visible_projects: visible.map { |project| project.with_rows(project.rows.reject { |row| row["role"] == "active" }) },
        board: (board(visible, archive_tasks(visible), expand_completed: true) if route.view == "board")
      )
    end

    def assign_repos(view)
      view.assign(repos: snapshot.repos.fetch("repos").map { |repo| OpenStruct.new(repo) },
                  projects: snapshot.projects)
    end

    def assign_workflows(view)
      payload = snapshot.workflows
      project = snapshot.project(payload.fetch("project"))
      view.assign(project: project, selected_project: project,
                  workflows: payload.fetch("workflows").map { |workflow| Workflow.new(project: project, attributes: workflow) },
                  excluded_workflows: payload.fetch("excluded"))
    end

    def assign_modules(view)
      payload = snapshot.modules
      project = snapshot.project(payload.fetch("project"))
      view.assign(project: project, selected_project: project,
                  modules: payload.fetch("modules").map { |hive_module| HiveModule.new(project: project, attributes: hive_module) })
    end

    def assign_patrol(view)
      view.assign(project: snapshot.project(snapshot.patrol.fetch("project")),
                  patrol: OpenStruct.new(snapshot.patrol))
    end

    def assign_digest(view, route)
      view.assign(digest: snapshot.digest_view(requested_date: route.path.split("/").last))
    end

    def assign_task(view, route)
      task = snapshot.task_for_slug(route.project, route.task.split("/").last)
      documents = snapshot.documents(task)
      primary = primary_document(task, documents)
      view.assign(
        task: task, project: task.project, documents: documents,
        workspace: { "status" => { "freshness" => "fresh", "state" => "current" },
                     "task" => { "archived" => task.archived? } },
        result: { "primary" => primary && record(primary),
                  "supporting" => supporting_documents(documents, primary).map { |document| record(document) },
                  "warning" => nil },
        publication: publication(task),
        change: task.change
      )
    end

    def assign_document(view, route)
      task = snapshot.task_for_slug(route.project, route.task.split("/").last)
      document = snapshot.document(task, route.path.sub("#{routes.task_path(route.project, task.slug)}/documents/", ""))
      view.assign(task: task, project: task.project, document: document,
                  document_html: view.render_markdown_document(document.content))
    end

    def assign_change(view, route)
      task = snapshot.task_for_slug(route.project, route.task.split("/").last)
      view.assign(task: task, project: task.project, task_source: task.archived? ? "archive" : nil,
                  diff_result: diff_result(task))
    end

    def record(document)
      { "reference" => document.name, "name" => document.name, "content" => document.content,
        "binary" => false, "truncated" => false }
    end

    def supporting_documents(documents, primary)
      documents.reject { |document| document.equal?(primary) }
    end

    def primary_document(task, documents)
      documents.find { |document| document.path == task["primary_document"] } ||
        documents.find { |document| document.role == "primary" } ||
        documents.find { |document| document.role == "plan" }
    end

    def publication(task)
      pub = task.publication
      return nil unless pub

      {
        "state" => "current",
        "publication_state" => pub.fetch("state").downcase,
        "pull_request" => { "number" => pub.fetch("number"), "url" => pub.fetch("url") },
        "remote" => { "observed_at" => pub["merged_at"],
                      "observation" => { "state" => pub.fetch("state").downcase } },
        "local" => {
          "repository" => pub.fetch("repository"), "branch" => pub["branch"],
          "base_branch" => pub["base_branch"], "head_oid" => pub["head_oid"]
        },
        "diagnostics" => []
      }
    end

    def diff_result(task)
      change = task.change
      if change.nil?
        OpenStruct.new(state: "unavailable", reason: "No change evidence was selected for this task",
                       diagnostic: "Open the public pull request from the task workspace for the complete change.",
                       next_action: "Open the task workspace for the captured outcome evidence.",
                       truncated: false, invalid_encoding: false, sections: {})
      elsif change.fetch("state") == "unavailable"
        OpenStruct.new(state: "unavailable", reason: change["reason"] || "Diff unavailable",
                       diagnostic: change.dig("provenance", "url") ? "Open #{change.dig('provenance', 'url')} for the complete public change." : nil,
                       next_action: "Open the public pull request for the complete change.",
                       truncated: false, invalid_encoding: false, sections: {})
      else
        content = snapshot.change_content(task)
        OpenStruct.new(
          state: "available", next_action: "Open the public pull request for the complete change.",
          truncated: change["truncated"] == true, invalid_encoding: false,
          sections: { "committed" => content, "staged" => "", "unstaged" => "", "untracked" => "" }
        )
      end
    end

    def board(projects, task_pairs, expand_completed: false)
      bands = projects.map do |project|
        tasks = task_pairs.select { |pair| pair.first.name == project.name }.map(&:last)
        columns = Hive::StageLabel::KNOWN.keys.map do |stage|
          Board::Column.new(stage: stage, label: Hive::StageLabel.format(stage),
                            tasks: tasks.select { |task| task["stage"] == stage }, terminal: stage == "9-done")
        end
        Board::Band.new(project: project, workflow_id: "coding", columns: columns,
                        daemon_enabled: false, error: nil)
      end
      OpenStruct.new(bands: bands, empty?: bands.empty?, expand_completed: expand_completed)
    end

    def write_assets
      css = Dir[File.join(Rails.root, "app/assets/stylesheets/*.css")].sort.map { |path| File.read(path) }.join("\n")
      raise "Stylesheet imports are not static" if css.match?(/@import/i)

      css.scan(/url\(\s*['"]?([^'")]+)/i).flatten.each do |url|
        raise "Unapproved stylesheet asset: #{url}" unless url.start_with?("data:image/svg+xml,")
      end
      css_path = "assets/hive-#{Digest::SHA256.hexdigest(css)[0, 12]}.css"
      write(css_path, css)
      @stylesheet = "/#{css_path}"
    end

    def validate_links!(route, fragment)
      fragment.css("a[href^='/']").each do |anchor|
        next if routes.include?(anchor["href"])

        raise "Route #{route.path} links to an unexported path: #{anchor['href']}"
      end
    end

    def assert_publishable!(path, content)
      LEAK_PATTERNS.each do |kind, pattern|
        next if kind == "active_content" && path.include?("/change/")

        match = pattern.match(content)
        raise "Exported file #{path} contains forbidden #{kind}: #{match[0].slice(0, 80)}" if match
      end
      Hive::SecretPatterns::PATTERNS.each do |name, pattern|
        match = pattern.match(content)
        raise "Exported file #{path} contains forbidden credential (#{name}): #{match[0].slice(0, 80)}" if match
      end
    end

    def write(path, content)
      assert_publishable!(path, content)
      target = @destination.join(path)
      expanded = File.expand_path(target)
      destination = File.expand_path(@destination)
      unless expanded.start_with?("#{destination}#{File::SEPARATOR}")
        raise "Export path escapes the destination: #{path}"
      end

      FileUtils.mkdir_p(target.dirname)
      target.write(content)
    end
  end
end
