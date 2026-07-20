require "open3"
require "tempfile"

class TasksController < ApplicationController
  before_action :load_project
  before_action :load_task, only: %i[show answer log diff media recover intervene]

  def show
    @files = @task.artifacts
    @media = @task.media_manifest
    @log = @task.latest_log
    @questions = @task.open_questions
    @worktree_exists = @task.worktree?
    @daemon_enabled = project_daemon_enabled?
    @daemon_running = daemon_running?
  end

  # Per-question answers from the Q&A form (answers[n] => text), written
  # through the same BrainstormAnswerWriter path as the bot. The daemon's
  # answers-pending gate resumes the brainstorm once questions are answered.
  def answer
    # Validated field-by-field in the dispatcher (numbers against the open
    # set, blanks skipped). The keys are dynamic question numbers, so the
    # permit list is the submitted key set itself — same effect as permit!,
    # but the allowance is explicit and visible to static scanners.
    raw = params[:answers]
    answers = raw.respond_to?(:permit) ? raw.permit(*raw.keys) : raw
    result = dispatcher.answer_questions(folder: @task.folder, answers: answers)
    answered = result[:answered]
    redirect_to task_path(@project["name"], params[:slug]),
                notice: "Recorded #{answered.size == 1 ? "answer" : "answers"} to Q#{answered.join(", Q")}"
  end

  # Rendered inside a polled turbo-frame on the task page so the tail stays
  # live without SSE plumbing.
  def log
    render partial: "tasks/log", locals: { log: @task.latest_log }
  end

  def diff
    # The status payload carries the task's canonical worktree path (the same
    # rule `hive run` uses) — do not re-derive it here; a configured
    # worktree_root with `~` or HIVE_WORKTREE_BASE would diverge.
    worktree = @task.worktree_path
    raise Hive::InvalidTaskPath, "no worktree for #{params[:slug]}" if worktree.empty? || !File.directory?(worktree)

    @diff, @diff_truncated = bounded_diff(worktree)
  end

  def media
    path = @task.media_path(params[:filename])
    unless path
      # A manifest may list a still the media dir no longer holds (a
      # half-cleaned demo dir, a rename, a traversal/extension probe). Log it so
      # the otherwise-silent 404 is diagnosable, mirroring the warns at the
      # brainstorm/config readers below.
      Rails.logger.warn("media file unresolved for #{params[:slug]}: #{params[:filename].inspect}")
      return head :not_found
    end

    expires_in 60.seconds, public: false
    send_file path,
              type: Rack::Mime.mime_type(File.extname(path), "application/octet-stream"),
              disposition: "inline"
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
    payload = dispatcher.drop(slug: params[:slug], project: @project["name"], from: params[:from])
    # The task no longer exists at any stage — its page is gone too. The
    # notice stays honest about warn-only cleanup steps Drop degraded
    # (false = attempted and failed; nil = nothing to do).
    notice = "Dropped #{params[:slug]}"
    notice += " — note: its draft PR could not be closed" if payload["pr_closed"] == false
    redirect_to root_path, notice: notice
  end

  def run_stage
    dispatcher.assert_dispatchable!(params[:action_name])
    dispatcher.dispatch(slug: params[:slug], project: @project["name"],
                        action: params[:action_name], stage: params[:stage])
    redirect_to task_path(@project["name"], params[:slug]), notice: "Queued for the daemon"
  end

  def recover
    # Recovery runs against the CURRENT row, not form-posted state: the
    # marker's attrs become the clear guard, so a task that moved on since
    # the page rendered makes the clear a no-op and the retry never fires.
    dispatcher.recover(slug: params[:slug], project: @project["name"],
                       stage: @task["stage"], marker: @task["marker"], attrs: @task["attrs"],
                       workflow: @task["workflow"])
    redirect_to task_path(@project["name"], params[:slug]),
                notice: "Recovery queued — clearing the error and re-running the stage"
  end

  def intervene
    dispatcher.intervene(folder: @task.folder, message: params[:message])
    redirect_to task_path(@project["name"], params[:slug]), notice: "Answer recorded"
  end

  private

  # An unbounded `git diff` from a huge or wedged worktree would pin one of
  # the box's few Puma threads and buffer the whole diff in memory. Same
  # discipline as ReposController#clone!: own process group, hard wall-clock
  # deadline, output to a tempfile, and only the first DIFF_MAX_BYTES are
  # rendered (with an explicit truncation flag).
  DIFF_TIMEOUT_SEC = Integer(ENV.fetch("HIVEBOX_DIFF_TIMEOUT_SEC", 15))
  DIFF_MAX_BYTES = 512 * 1024

  def bounded_diff(worktree)
    log = Tempfile.create("hivebox-diff")
    pid = Process.spawn("git", "-C", worktree, "diff", "--",
                        pgroup: true, out: log.path, err: log.path)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DIFF_TIMEOUT_SEC
    status = nil
    loop do
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      break if status

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Process.kill("KILL", -pid) rescue nil
        Process.waitpid2(pid) rescue nil
        raise Hive::Error, "git diff timed out after #{DIFF_TIMEOUT_SEC}s"
      end
      sleep 0.1
    end
    raise Hive::Error, "git diff failed: #{File.read(log.path).strip}" unless status.success?

    out = File.open(log.path, "rb") { |f| f.read(DIFF_MAX_BYTES + 1) }.to_s.force_encoding(Encoding::UTF_8).scrub
    truncated = out.bytesize > DIFF_MAX_BYTES
    [ truncated ? out.byteslice(0, DIFF_MAX_BYTES).scrub : out, truncated ]
  ensure
    log&.close
    File.unlink(log.path) if log && File.exist?(log.path)
  end

  def load_project
    @project = find_project!(params[:project])
  end

  def load_task
    @task = Task.find!(project: @project, slug: params[:slug])
  end

  def dispatcher
    Hive::Web::Dispatcher.new
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

  # Cheap liveness-only probe for the task-page blocker. The full status
  # envelope also inspects service units and installed binary versions; that
  # belongs on the dashboard, not on every pushed task-page morph.
  def daemon_running?
    require "hive/daemon/status_report"
    Hive::Daemon::StatusReport.new.running_state[:running] == true
  rescue StandardError => e
    Rails.logger.warn("daemon liveness probe failed: #{e.class}: #{e.message}")
    false
  end
end
