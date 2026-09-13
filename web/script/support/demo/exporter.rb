require "json"
require "digest"
require "ostruct"
require "fileutils"
require "open3"

module HiveDemo
  # A deliberately narrow presentation object: never delegates to Hive models.
  class Task < Hash
    def slug = fetch("slug")
    def title = fetch("title")
    def recovery = nil
    def recovery_action_visible? = false
    def recovery_action_enabled? = false
    def passable? = false
    def worktree? = false
  end

  class View < ActionView::Base.with_empty_template_cache
    include ApplicationHelper
    include Turbo::FramesHelper
    def task_path(_project, slug, **) = "#/task/#{slug}/overview"
    def turbo_frame_request? = true
    def web_product_name = "Hive"
  end

  class Exporter
    ROOT = File.expand_path("../../../..", __dir__)
    ALLOWED_TAGS = %w[div section header h1 h2 h3 h4 h5 h6 p span a article details summary ol ul li pre code em strong del hr br table thead tbody tr th td blockquote].freeze
    ALLOWED_ATTRIBUTES = %w[id class href title role aria-label aria-labelledby aria-live aria-atomic aria-hidden hidden data-project-name data-workflow data-stage data-task-slug data-primary-artifact data-diff-section].freeze

    def initialize
      @scenario = JSON.parse(File.read(File.join(ROOT, "demo/scenarios/notebook.json")))
      @view = View.new(ActionView::LookupContext.new([ File.join(ROOT, "web/app/views") ]), {}, nil)
    end

    # Deliberate fixture controls are removed structurally. Any new live control
    # introduced by an upstream view fails the export instead of being published.
    def static_fragment(html)
      fragment = Nokogiri::HTML.fragment(html)
      fragment.css("turbo-frame").each do |node|
        raise "Lazy frame is not static" if node["src"]
        node.replace(node.children)
      end
      fragment.css(".kanban-fold-icon").remove
      fragment.css(".kanban-card-meta .faint").each { |node| node.content = "Sample task" }
      fragment.css("button.kanban-column-toggle").each do |node|
        node.name = "span"
        node.attribute_nodes.each { |attribute| attribute.remove unless attribute.name == "class" }
        node["class"] = "kanban-column-label"
      end
      fragment.css("*").each do |node|
        node.attribute_nodes.each do |attribute|
          attribute.remove if attribute.name.match?(/\Adata-(?:controller|action|kanban-column-|task-workspace-|workspace-disclosure-|turbo)/)
        end
      end
      validate!(fragment)
      fragment.to_html
    end

    def validate!(fragment)
      fragment.css("*").each do |node|
        raise "Unapproved active element: #{node.name}" unless ALLOWED_TAGS.include?(node.name)
        node.attribute_nodes.each do |attribute|
          raise "Unapproved attribute: #{attribute.name}" unless ALLOWED_ATTRIBUTES.include?(attribute.name)
        end
        next unless node["href"]
        raise "Unapproved destination: #{node['href']}" unless node["href"].match?(/\A#(?:\/task\/[a-z0-9-]+\/(?:overview|plan|diff|evidence)|[a-z0-9_-]+)?\z/)
      end
      true
    end

    def export(destination)
      FileUtils.mkdir_p(destination)
      manifest = { version: 1, source_commit: Open3.capture2("git", "-C", ROOT, "rev-parse", "HEAD").first.strip,
                  initial: "question", featured: "dark-mode", tasks: @scenario.fetch("tasks").map { |task| task.slice("slug", "title") }, states: {} }
      css = Dir[File.join(ROOT, "web/app/assets/stylesheets/*.css")].sort.map { |path| File.read(path) }.join("\n")
      raise "Stylesheet imports are not static" if css.match?(/@import/i)
      css.scan(/url\(\s*['"]?([^'")]+)/i).flatten.each do |url|
        raise "Unapproved stylesheet asset: #{url}" unless url.start_with?("data:image/svg+xml,")
      end
      manifest[:stylesheet] = "assets/hive-#{Digest::SHA256.hexdigest(css)[0, 12]}.css"
      write(destination, manifest[:stylesheet], css)
      states.each do |id, branch, phase|
        tasks = @scenario.fetch("tasks").map { |data| task_for(data, branch, phase) }
        entry = { phase: phase, branch: branch, next: next_state(branch, phase), board: "fragments/#{id}/board.html", tasks: {} }
        write(destination, entry[:board], static_fragment(@view.render(partial: "status/board", locals: { board: board(tasks), status_fresh: true })))
        tasks.each do |task|
          @view.assign(task: task, task_source: nil, project: OpenStruct.new(name: "Notebook"))
          panels = { overview: overview(task), plan: document(task, "plan.md", task.fetch("plan")) }
          if task["diff"]
            panels[:diff] = diff(task)
            panels[:evidence] = document(task, "test-evidence.md", task.fetch("evidence"))
          end
          entry[:tasks][task.slug] = panels.to_h do |panel, html|
            path = "fragments/#{id}/#{task.slug}-#{panel}.html"
            write(destination, path, static_fragment(html))
            [ panel, path ]
          end
        end
        manifest[:states][id] = entry
      end
      write(destination, "manifest.json", JSON.pretty_generate(manifest) + "\n")
      manifest
    end

    private

    def write(destination, path, content)
      target = File.join(destination, path)
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, content)
    end

    def states
      [ [ "question", nil, "question" ] ] + %w[system manual].flat_map { |branch| %w[plan implementing review completed].map { |phase| [ "#{branch}-#{phase}", branch, phase ] } }
    end

    def next_state(branch, phase)
      following = { "plan" => "implementing", "implementing" => "review", "review" => "completed" }[phase]
      "#{branch}-#{following}" if following
    end

    def task_for(data, branch, phase)
      values = data.dup
      if data.fetch("slug") == "dark-mode"
        values.merge!(@scenario.fetch("branches").fetch(branch)) if branch
        values["phase"] = phase
        values.delete("diff") if %w[question plan].include?(phase)
        values["result"] = if phase == "completed"
          values.fetch("outcome")
        elsif phase == "question"
          "# Add dark mode\n\nNotebook is a fictional notes app. Its users want a comfortable way to write after dark.\n\n## One decision before work starts\n\nShould it follow the system setting? Choose a prepared answer below to explore the matching plan."
        else
          values.fetch("plan")
        end
      end
      values["stage"], values["action"], values["action_label"] = {
        "question" => [ "2-brainstorm", "needs_input", "Needs your input" ],
        "plan" => [ "3-plan", "ready_execute", "Plan prepared" ],
        "implementing" => [ "4-execute", "agent_running", "Implementing" ],
        "review" => [ "6-review", "needs_input", "Ready for your review" ],
        "completed" => [ "9-done", "archived", "Completed" ]
      }.fetch(values.fetch("phase"))
      values["unanswered_questions"] = phase == "question" && data["slug"] == "dark-mode" ? 1 : 0
      values["age_seconds"] = 0
      Task[values]
    end

    def board(tasks)
      columns = %w[2-brainstorm 3-plan 4-execute 6-review 9-done].map do |stage|
        label = { "2-brainstorm" => "Needs your answer", "3-plan" => "Plan", "4-execute" => "Implementing", "6-review" => "Ready for review", "9-done" => "Completed" }.fetch(stage)
        OpenStruct.new(stage: stage, label: label, tasks: tasks.select { |task| task["stage"] == stage }, folded_by_default?: false)
      end
      band = OpenStruct.new(project: OpenStruct.new(name: "Notebook"), workflow_id: "coding", task_count: tasks.length, hidden_archived_task_count: 0, unavailable?: false, daemon_enabled: true, columns: columns)
      OpenStruct.new(empty?: false, bands: [ band ])
    end

    def overview(task)
      workspace = { "status" => { "freshness" => "fresh", "state" => "current" }, "task" => { "archived" => false } }
      @view.render(partial: "tasks/workspace_summary", locals: { workspace: workspace }) + document(task, task["phase"] == "completed" ? "result.md" : "current-work.md", task.fetch("result"))
    end

    def document(task, name, content)
      @view.render(partial: "tasks/primary_result", locals: { result: { "primary" => { "reference" => "demo:#{task.slug}:#{name}", "name" => name, "content" => content } } })
    end

    def diff(task)
      result = OpenStruct.new(state: "available", next_action: "Inspect this prepared diff and the sample test evidence.", truncated: false, invalid_encoding: false,
                              sections: { "committed" => task.fetch("diff"), "staged" => "", "unstaged" => "", "untracked" => "" })
      @view.assign(diff_result: result)
      @view.render(template: "tasks/diff")
    end
  end
end
