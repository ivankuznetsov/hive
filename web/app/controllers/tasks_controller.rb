require "open3"

class TasksController < ApplicationController
  before_action :load_project

  def show
    @row = task_row!
    @files = artifact_files(@row)
    @log = latest_log
    @questions = open_questions(@row)
    @worktree_exists = worktree_exists?(@row)
    @daemon_enabled = project_daemon_enabled?
  end

  # Per-question answers from the Q&A form (answers[n] => text), written
  # through the same BrainstormAnswerWriter path as the bot. The daemon's
  # answers-pending gate resumes the brainstorm once questions are answered.
  def answer
    row = task_row!
    # Validated field-by-field in the dispatcher (numbers against the open
    # set, blanks skipped) — permit! just unlocks the hash conversion.
    answers = params[:answers].respond_to?(:permit!) ? params[:answers].permit! : params[:answers]
    result = dispatcher.answer_questions(folder: row["folder"], answers: answers)
    answered = result[:answered]
    redirect_to task_path(@project["name"], params[:slug]),
                notice: "Recorded #{answered.size == 1 ? "answer" : "answers"} to Q#{answered.join(", Q")}"
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

  def drop
    dispatcher.drop(slug: params[:slug], project: @project["name"], from: params[:from])
    # The task no longer exists at any stage — its page is gone too.
    redirect_to root_path, notice: "Dropped #{params[:slug]}"
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

  ARTIFACT_ORDER = %w[idea.md brainstorm.md plan.md task.md pr.md summary.md artifact.md].freeze

  def artifact_files(row)
    folder = row["folder"]
    return [] unless folder && File.directory?(folder)

    artifact_order(row).filter_map do |name|
      path = File.join(folder, name)
      [ name, File.read(path) ] if File.file?(path)
    end
  end

  # Pipeline-chronological (idea first) while the task is being worked —
  # earlier stages read top-to-bottom as a story. From finalize onward the
  # run's deliverable is what the operator opens the page for, so artifact.md
  # leads (and, being first, renders open). Not at 7-artifacts: the file is
  # still being written there.
  def artifact_order(row)
    return ARTIFACT_ORDER unless %w[8-finalize 9-done].include?(row["stage"].to_s)

    [ "artifact.md" ] + (ARTIFACT_ORDER - [ "artifact.md" ])
  end

  def open_questions(row)
    folder = row["folder"]
    return [] unless folder

    path = File.join(folder, "brainstorm.md")
    return [] unless File.file?(path)

    Hive::Bot::BrainstormParser.unanswered_questions(Hive::Bot::BrainstormParser.parse(path))
  rescue StandardError => e
    # A half-written brainstorm.md (agent mid-flight) must not 500 the page;
    # the generic steer box remains available. Logged because a PERMANENTLY
    # malformed file looks identical from here — a task silently waiting
    # forever with no questions is diagnosable only from this line.
    Rails.logger.warn("brainstorm.md unparseable for #{params[:slug]}: #{e.class}: #{e.message}")
    []
  end

  def worktree_exists?(row)
    path = row["worktree_path"].to_s
    path.present? && File.directory?(path)
  end

  # Manual stage runs only make sense when the project's daemon is NOT
  # auto-advancing (otherwise the daemon races the operator); per-project
  # `daemon.enabled` defaults to true. An unreadable project config also
  # answers true — but LOUDLY: that state hides the manual Run button at
  # the exact moment the daemon can't parse the config either, so the log
  # line is the only breadcrumb.
  def project_daemon_enabled?
    Hive::Config.load(@project["path"]).dig("daemon", "enabled") != false
  rescue StandardError => e
    Rails.logger.warn("project config unreadable for #{@project["name"]}: #{e.class}: #{e.message}")
    true
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
