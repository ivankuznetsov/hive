require "open3"
require "tempfile"

class TasksController < ApplicationController
  before_action :load_project

  def show
    @row = task_row!
    @files = artifact_files(@row)
    @media = media_manifest(@row)
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
    # set, blanks skipped). The keys are dynamic question numbers, so the
    # permit list is the submitted key set itself — same effect as permit!,
    # but the allowance is explicit and visible to static scanners.
    raw = params[:answers]
    answers = raw.respond_to?(:permit) ? raw.permit(*raw.keys) : raw
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

    @diff, @diff_truncated = bounded_diff(worktree)
  end

  def media
    row = task_row!
    path = resolved_media_path(row, params[:filename])
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
    row = task_row!
    dispatcher.recover(slug: params[:slug], project: @project["name"],
                       stage: row["stage"], marker: row["marker"], attrs: row["attrs"],
                       workflow: row["workflow"], retry_projection: row["retry"])
    redirect_to task_path(@project["name"], params[:slug]),
                notice: "Retry request queued through the coordinator"
  end

  def intervene
    row = task_row!
    dispatcher.intervene(folder: row["folder"], message: params[:message])
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
  #
  # A non-coding workflow has its own stage state_files (research.md, draft.md,
  # done.md, …) that ARTIFACT_ORDER never lists, so the page rendered nothing
  # for them. Derive the order from the task's workflow descriptor instead; the
  # coding branch stays byte-identical.
  def artifact_order(row)
    return generic_artifact_order(row) unless Hive::Workflows.coding_id?(row["workflow"])

    return ARTIFACT_ORDER unless %w[8-finalize 9-done].include?(row["stage"].to_s)

    [ "artifact.md" ] + (ARTIFACT_ORDER - [ "artifact.md" ])
  end

  # Chronological stage state_files for a non-coding workflow. Falls back to the
  # coding order if the descriptor is unregistered (a hand-edited or
  # later-removed workflow) so the page still renders something.
  def generic_artifact_order(row)
    # The row belongs to @project, but a custom workflow is registered only in
    # ITS project's overlay. Load that overlay under the lock before fetching:
    # without it the fetch reads whatever overlay the StatusFeed poller last
    # left active, so on a multi-project box every project but the active one
    # raises UnknownWorkflow → falls back to coding ARTIFACT_ORDER and renders
    # an empty artifact list for the custom-workflow task. The lock holds the
    # load and the fetch together so a concurrent swap can't race between them.
    Hive::Workflows::Project.synchronize do
      Hive::Workflows::Project.load!(@project["path"])
      Hive::Workflows::Registry.fetch(row["workflow"].to_sym).stages.map(&:state_file).uniq
    end
  rescue Hive::Workflows::UnknownWorkflow
    ARTIFACT_ORDER
  end

  MEDIA_FILENAME_RE = /\A[\w.-]+\.(?:png|jpe?g|gif)\z/i

  def media_manifest(row)
    folder = row["folder"]
    return nil unless folder

    path = File.join(folder, "media", "manifest.json")
    return nil unless File.file?(path)

    manifest = JSON.parse(File.read(path))
    # A syntactically-valid manifest whose top level is a JSON array, number,
    # or null is a half-written agent file — it must not 500 the page (read it
    # resiliently, like open_questions). Bail before indexing into a non-Hash.
    return nil unless manifest.is_a?(Hash)
    # Gate on the known schema version: a future schema reshapes items[], so a
    # v2 manifest must be ignored, not rendered as garbage v1 items. The schema
    # int is hoisted into the gem (Hive::MediaManifest::SCHEMA) so the stage and
    # this reader can't drift apart on a bump.
    return nil unless manifest["schema"] == Hive::MediaManifest::SCHEMA

    status = manifest["status"].to_s
    return nil unless %w[captured skipped failed].include?(status)

    {
      "status" => status,
      "reason" => manifest["reason"].to_s,
      "items" => normalized_media_items(row, manifest["items"])
    }
  rescue JSON::ParserError, SystemCallError => e
    Rails.logger.warn("media manifest unreadable for #{params[:slug]}: #{e.class}: #{e.message}")
    nil
  end

  def normalized_media_items(row, items)
    Array(items).filter_map do |item|
      next unless item.is_a?(Hash)

      file = item["file"].to_s
      next unless file.match?(MEDIA_FILENAME_RE)
      next unless File.basename(file) == file
      unless resolved_media_path(row, file)
        # A captured manifest naming a still the media dir no longer holds (a
        # cleaned/renamed demo dir, a missing file) otherwise vanishes from the
        # Demo gallery with no trace. Log it — mirroring the media action's
        # breadcrumb — so an empty Demo section is diagnosable without
        # hand-reading the manifest.
        Rails.logger.warn("media item unresolved for #{params[:slug]}: #{file.inspect}")
        next
      end

      url = item["screenote_url"].to_s
      {
        "file" => file,
        "type" => item["type"].to_s,
        "caption" => item["caption"].to_s,
        "screenote_url" => url.match?(%r{\Ahttps?://}) ? url : nil
      }
    end
  end

  def resolved_media_path(row, filename)
    folder = row["folder"].to_s
    return nil if folder.empty?

    filename = File.basename(filename.to_s)
    return nil unless filename.match?(MEDIA_FILENAME_RE)

    # Anchor the media root to the REAL task folder: resolve the folder's
    # symlinks, then require `media/` to resolve to exactly <folder>/media. A
    # `media` directory that is itself a symlink out of the task folder must not
    # become a trusted root, or a task could stream readable files from outside
    # its folder. Mirrors the stage's media_item_path.
    folder_root = File.realpath(folder)
    media_root = File.realpath(File.join(folder_root, "media"))
    return nil unless media_root == File.join(folder_root, "media")

    candidate = File.join(media_root, filename)
    return nil unless File.file?(candidate)

    real = File.realpath(candidate)
    return nil unless real.start_with?("#{media_root}#{File::SEPARATOR}")

    real
  rescue SystemCallError
    nil
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
    # The route constraint already pins the slug shape; File.basename is
    # defense in depth for the param-in-path pattern (and the scanner).
    dir = File.join(@project["hive_state_path"], "logs", File.basename(params[:slug]))
    path = Dir.glob(File.join(dir, "*.log")).max_by { |p| File.mtime(p) }
    return nil unless path

    # Bounded tail in BYTES, not just lines: the poll hits this every 3s,
    # and agent logs grow to many MB — reading the whole file each tick
    # burns a Puma worker on I/O. 256KB comfortably covers 200 lines.
    size = File.size(path)
    window = 256 * 1024
    tail = File.open(path, "rb") do |f|
      f.seek([ size - window, 0 ].max)
      f.read.to_s
    end
    tail = tail.force_encoding(Encoding::UTF_8).scrub
    lines = tail.lines.last(200)
    # A mid-line window start would render a torn first line.
    lines.shift if size > window && lines.size > 1
    { "path" => path, "tail" => lines.join }
  end
end
