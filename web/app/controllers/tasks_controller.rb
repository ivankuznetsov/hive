require "open3"

class TasksController < ApplicationController
  before_action :load_project

  def show
    @row = task_row!
    @files = artifact_files(@row)
    @log = latest_log
  end

  # Rendered inside a polled turbo-frame on the task page so the tail stays
  # live without SSE plumbing.
  def log
    @row = task_row!
    @log = latest_log
    render partial: "tasks/log", locals: { log: @log, project: @project, row: @row }
  end

  def diff
    @row = task_row!
    # The status payload carries the task's canonical worktree path (the same
    # rule `hive run` uses) — do not re-derive it here; a configured
    # worktree_root with `~` or HIVE_WORKTREE_BASE would diverge.
    worktree = @row["worktree_path"].to_s
    raise Hive::InvalidTaskPath, "no worktree for #{params[:slug]}" if worktree.empty? || !File.directory?(worktree)

    out, err, status = Open3.capture3("git", "-C", worktree, "diff", "--")
    raise Hive::Error, "git diff failed: #{err.strip}" unless status.success?

    @diff = out
  end

  def approve
    dispatcher.approve(slug: params[:slug], project: @project["name"],
                       from: params[:from], to: params[:to], force: params[:force] == "1")
    # Approve moves the task to the next stage; its detail page may no longer
    # resolve at this slug/stage — return to the grid.
    redirect_to root_path, notice: "Approved #{params[:slug]}"
  end

  def reject
    dispatcher.reject(slug: params[:slug], project: @project["name"],
                      from: params[:from], to: params[:to])
    redirect_to root_path, notice: "Sent #{params[:slug]} back a stage"
  end

  def run_stage
    dispatcher.assert_dispatchable!(params[:action_name])
    dispatcher.dispatch(slug: params[:slug], project: @project["name"],
                        action: params[:action_name], stage: params[:stage])
    redirect_to task_path(@project["name"], params[:slug]), notice: "Queued for the daemon"
  end

  def intervene
    row = task_row!
    dispatcher.intervene(folder: row["folder"], message: params[:message])
    redirect_to task_path(@project["name"], params[:slug]), notice: "Answer recorded"
  end

  private

  def load_project
    @project = find_project!(params[:project])
  end

  def dispatcher
    Hive::Web::Dispatcher.new
  end

  def task_row!
    snapshot = StatusBroadcaster.snapshot
    payload = snapshot.fetch("projects", []).find { |p| p["name"] == @project["name"] }
    row = payload && payload.fetch("tasks", []).find { |t| t["slug"] == params[:slug] }
    row || raise(Hive::InvalidTaskPath, "unknown task #{params[:slug]}")
  end

  def artifact_files(row)
    folder = row["folder"]
    return [] unless folder && File.directory?(folder)

    %w[idea.md brainstorm.md plan.md task.md pr.md summary.md artifact.md].filter_map do |name|
      path = File.join(folder, name)
      [ name, File.read(path) ] if File.file?(path)
    end
  end

  def latest_log
    dir = File.join(@project["hive_state_path"], "logs", params[:slug])
    path = Dir.glob(File.join(dir, "*.log")).max_by { |p| File.mtime(p) }
    return nil unless path

    # Bounded tail: the page shows the live end of the log, not all of it.
    lines = File.readlines(path).last(200)
    { "path" => path, "tail" => lines.join }
  end
end
