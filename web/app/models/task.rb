require "digest"
require "json_schemer"
require "pathname"
require "hive/plan_review/projection"
require "hive/plan_review/store"
require "hive/web/environment"

class Task
  include TaskMutations

  BoundBrainstormQuestion = Struct.new(
    :round, :n, :text, :binding, :ordinal, keyword_init: true
  )

  ARTIFACT_ORDER = %w[idea.md brainstorm.md plan.md task.md pr.md summary.md artifact.md].freeze
  MEDIA_FILENAME_RE = /\A[\w.-]+\.(?:png|jpe?g|gif|webp|webm|mp4)\z/i
  CAPTURE_MANIFEST_V2_SCHEMER = JSONSchemer.schema(
    Pathname.new(Hive::Schemas.schema_path("hive-artifact-capture", version: 2))
  )
  DIFF_TIMEOUT_SEC = Integer(Hive::Web::Environment.value("HIVE_WEB_DIFF_TIMEOUT_SEC"))
  RECOVERY_ACTIONS = %w[recover_execute recover_review error].freeze
  RECOVERY_LABELS = {
    "queued" => "Recovery queued",
    "cooldown" => "Retry available later",
    "running" => "Agent running",
    "blocked" => "Recovery blocked",
    "unavailable" => "Current state unavailable"
  }.freeze
  STAGE_DISPATCH_ACTIONS = {
    "1" => "ready_to_brainstorm",
    "2" => "ready_to_brainstorm",
    "3" => "ready_to_plan",
    "4" => "ready_to_develop",
    "5" => "ready_to_open_pr",
    "6" => "ready_for_review",
    "7" => "ready_to_artifacts",
    "8" => "ready_to_finalize"
  }.freeze
  PASSABLE_MARKERS = Hive::Commands::Approve::VALID_TERMINAL_MARKERS.map(&:to_s).freeze
  PLAN_REVIEW_ARTIFACT_KEYS = /\A(?:policy|candidate_plan|resolution|(?:primary|adversarial|verification)_(?:result|coverage|route)|planner_revision_(?:input|result|coverage|route)|decision_prd-[0-9a-f]{64})\z/

  attr_reader :project

  def self.find!(project:, slug:, snapshot: StatusBroadcaster.snapshot)
    project_payload = snapshot.fetch("projects", []).find { |candidate| candidate["name"] == project.name }
    if project_payload&.fetch("error", nil) == "project_load_failed"
      raise Hive::Error,
            "project #{project.name} status is unavailable — repair its configuration or workflow, then reload"
    end

    attributes = project_payload&.fetch("tasks", [])&.find { |candidate| candidate["slug"] == slug }
    raise Hive::InvalidTaskPath, "unknown task #{slug}" unless attributes

    new(project:, attributes:)
  end

  def initialize(project:, attributes:)
    @project = project
    @attributes = attributes
  end

  def [](key)
    @attributes[key]
  end

  def dig(*keys)
    @attributes.dig(*keys)
  end

  def slug
    self["slug"]
  end

  def title
    display_name = self["display_name"]
    return display_name if display_name.present? && display_name != slug

    original_idea_line || slug.to_s.sub(/-\d{6}-\h{4}\z/, "").tr("-", " ").upcase_first
  end

  def status_label
    self["action_label"].presence || self["marker"].presence || "idle"
  end

  def folder
    self["folder"]
  end

  def project_root
    project.path
  end

  def worktree_path
    self["worktree_path"].to_s
  end

  def artifacts
    return [] unless folder && File.directory?(folder)

    artifact_order.filter_map do |name|
      path = File.join(folder, name)
      [ name, File.read(path) ] if File.file?(path)
    end
  end

  def plan_review
    value = self["plan_review"]
    value.is_a?(Hash) && value["applicable"] == true ? value : nil
  end

  # Status owns the summary. The task-local store owns detailed evidence, and
  # this accessor will read only the content-addressed artifacts selected by
  # the exact status observation. There is deliberately no caller-supplied
  # path, so Web cannot become an arbitrary task-folder file reader.
  def plan_review_details
    summary = plan_review
    return nil unless summary

    details = {
      "summary" => summary, "coverage" => [], "findings" => [],
      "routes" => Array(summary["routes"]), "artifacts" => []
    }
    return details unless folder && summary["review_id"]

    review_root = File.join(folder, Hive::PlanReview::Store::ROOT_BASENAME)
    root_status = File.lstat(review_root)
    unless root_status.directory? && !root_status.symlink?
      raise Hive::PlanReview::InvalidRecord, "plan review root is not a plain directory"
    end
    store = Hive::PlanReview::Store.new(task_folder: folder)
    current = store.current_validated
    projection = Hive::PlanReview::Projection.new(current)
    unless current.review_id == summary["review_id"] && current.version == summary["version"] &&
           projection.observation_digest == summary["observation_digest"]
      raise Hive::PlanReview::StaleObservation,
            "task status and plan review evidence identify different observations"
    end

    details.merge(
      "coverage" => current["coverage"],
      "findings" => current["findings"].sort_by { |finding| finding["display_order"] },
      "routes" => current["routes"],
      "artifacts" => safe_plan_review_artifacts(store, current["artifacts"])
    )
  rescue Hive::PlanReview::Error, JSON::ParserError, SystemCallError, IOError => error
    Rails.logger.warn("plan review evidence unreadable for #{slug}: #{error.class}: #{error.message}")
    {
      "summary" => summary.merge(
        "freshness" => { "status" => "invalid", "reason" => "plan review evidence changed" },
        "blocker_owner" => "hive", "blocker_reason" => "invalid_plan_review",
        "required_action" => "refresh plan review state and retry",
        "execution_allowed" => false
      ),
      "coverage" => [], "findings" => [], "routes" => [], "artifacts" => []
    }
  end

  def media_manifest
    return nil unless folder

    capture_path = File.join(folder, "media", "capture-manifest.json")
    return capture_media_manifest(capture_path) if File.file?(capture_path)

    path = File.join(folder, "media", "manifest.json")
    return nil unless File.file?(path)

    manifest = JSON.parse(File.read(path))
    return nil unless manifest.is_a?(Hash)
    return nil unless manifest["schema"] == Hive::MediaManifest::SCHEMA

    status = manifest["status"].to_s
    return nil unless %w[captured skipped failed].include?(status)

    {
      "status" => status,
      "reason" => manifest["reason"].to_s,
      "items" => normalized_media_items(manifest["items"])
    }
  rescue JSON::ParserError, SystemCallError => e
    Rails.logger.warn("media manifest unreadable for #{slug}: #{e.class}: #{e.message}")
    nil
  end

  def media_path(filename)
    return nil unless folder

    filename = filename.to_s
    return nil unless File.basename(filename) == filename
    return nil unless filename.match?(MEDIA_FILENAME_RE)

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

  def open_questions
    return [] unless self["stage"] == "2-brainstorm"

    Hive::Commands::Answer.inventory(slug, project: project.name)
                          .fetch("slots")
                          .reject { |slot| slot.fetch("answered") }
                          .map do |slot|
      BoundBrainstormQuestion.new(
        round: slot.fetch("round"),
        n: slot.fetch("question_number"),
        text: slot.fetch("text"),
        binding: slot.fetch("binding"),
        ordinal: slot.fetch("ordinal")
      )
    end
  rescue StandardError => e
    Rails.logger.warn("brainstorm.md unparseable for #{slug}: #{e.class}: #{e.message}")
    []
  end

  def worktree?
    worktree_path.present? && File.directory?(worktree_path)
  end

  def original_idea_text
    return unless folder

    path = File.join(folder, "idea.md")
    return unless File.file?(path)

    front = File.read(path, 8192).to_s[/\A---\n(.*?)\n---/m, 1]
    return unless front

    YAML.safe_load(front, permitted_classes: [ Time, Date ])&.dig("original_text").to_s.strip.presence
  rescue StandardError
    nil
  end

  def recovery_action?
    RECOVERY_ACTIONS.include?(self["action"].to_s)
  end

  def recovery
    value = self["recovery"]
    value.is_a?(Hash) ? value : nil
  end

  def recovery_action_visible?
    recovery_action? && recovery&.fetch("status", nil) != "terminal"
  end

  def recovery_action_enabled?
    recovery_action? && recovery.nil? && !recovery_intervention_required?
  end

  def recovery_primary_label
    return unless recovery

    status = recovery["status"].to_s
    return recovery_terminal_success? ? "Completed" : "Failed" if status == "terminal"

    RECOVERY_LABELS.fetch(status, "Current state unavailable")
  end

  def recovery_context
    return [] unless recovery

    context = []
    context << "request #{recovery['request_id']}" if recovery["request_id"].present?
    context << "attempt #{recovery['attempt_id']}" if recovery["attempt_id"].present?
    context << "eligible #{recovery['next_eligible_at']}" if
      recovery["status"] == "cooldown" && recovery["next_eligible_at"].present?
    context << "origin #{recovery['failure_origin']}" if recovery["failure_origin"].present?
    context << recovery["terminal_outcome"].to_s.tr("_", " ") if
      recovery["status"] == "terminal" && recovery["terminal_outcome"].present?
    context << "at #{recovery['terminal_at']}" if
      recovery["status"] == "terminal" && recovery["terminal_at"].present?
    context << recovery["reason"].to_s.tr("_", " ") if recovery["reason"].present?
    context << recovery["remediation"] if recovery["remediation"].present?
    if recovery.dig("provider_hint", "retry_after").present?
      context << "provider reset estimate #{recovery.dig('provider_hint', 'retry_after')} (display only)"
    end
    context
  end

  def passable?
    PASSABLE_MARKERS.include?(self["marker"].to_s)
  end

  def dispatch_action
    unless Hive::Workflows.coding_id?(self["workflow"])
      return self["action"].to_s == "ready_to_run" ? "ready_to_run" : nil
    end

    projected = self["action"].to_s
    if projected == Hive::Schemas::TaskActionKind::PLAN_REVIEWING ||
       projected == Hive::Schemas::TaskActionKind::PLAN_REVIEW_RETRY &&
         self["suggested_command"].to_s.start_with?("hive plan-review-run ")
      return projected
    end

    STAGE_DISPATCH_ACTIONS[self["stage"].to_s.split("-", 2).first]
  end

  def run_verb
    action = dispatch_action
    return unless action

    command = Hive::TaskAction::DISPATCH_COMMANDS.fetch(action)
    command == "run" ? "stage" : command
  end

  def terminal?
    Hive::Workflows.all_terminal_stage_dirs.include?(self["stage"].to_s)
  end

  def diff
    Hive::Web::TaskDiff.new(task: self, timeout_sec: DIFF_TIMEOUT_SEC).call
  end

  def latest_log
    dir = File.join(project.hive_state_path, "logs", File.basename(slug))
    path = Dir.glob(File.join(dir, "*.log")).max_by { |candidate| File.mtime(candidate) }
    return nil unless path

    size = File.size(path)
    window = 256 * 1024
    tail = File.open(path, "rb") do |file|
      file.seek([ size - window, 0 ].max)
      file.read.to_s
    end
    lines = tail.force_encoding(Encoding::UTF_8).scrub.lines.last(200)
    lines.shift if size > window && lines.size > 1
    { "path" => path, "tail" => lines.join }
  end

  private

  def safe_plan_review_artifacts(store, references)
    references.sort.filter_map do |name, reference|
      next unless name.match?(PLAN_REVIEW_ARTIFACT_KEYS)

      content = store.read_reference(reference)
      {
        "name" => name, "path" => reference.fetch("path"),
        "sha256" => reference.fetch("sha256"), "bytes" => reference.fetch("bytes"),
        "format" => name == "candidate_plan" ? "markdown" : "json",
        "content" => content.force_encoding(Encoding::UTF_8).scrub("?")
      }
    end
  end

  def recovery_intervention_required?
    Hive::Recovery.intervention_required?(
      marker: self["marker"], attrs: self["attrs"] || {}, folder: folder
    )
  end

  def recovery_terminal_success?
    %w[succeeded success completed terminal_replay].include?(
      recovery["terminal_outcome"].to_s
    )
  end

  def original_idea_line
    text = original_idea_text.to_s.gsub(/\[image\d+\]/, "")
    text.strip.lines.first.to_s.strip.presence&.truncate(90)
  end

  def artifact_order
    return generic_artifact_order unless Hive::Workflows.coding_id?(self["workflow"])
    return ARTIFACT_ORDER unless %w[8-finalize 9-done].include?(self["stage"].to_s)

    [ "artifact.md" ] + (ARTIFACT_ORDER - [ "artifact.md" ])
  end

  def generic_artifact_order
    Hive::Workflows::Project.synchronize do
      Hive::Workflows::Project.load!(project.path)
      Hive::Workflows::Registry.fetch(self["workflow"].to_sym).stages.map(&:state_file).uniq
    end
  rescue Hive::Workflows::UnknownWorkflow
    ARTIFACT_ORDER
  end

  def normalized_media_items(items)
    Array(items).filter_map do |item|
      next unless item.is_a?(Hash)

      file = item["file"].to_s
      next unless file.match?(MEDIA_FILENAME_RE)
      next unless File.basename(file) == file
      unless media_path(file)
        Rails.logger.warn("media item unresolved for #{slug}: #{file.inspect}")
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

  def capture_media_manifest(path)
    stat = File.lstat(path)
    return nil unless stat.file? && !stat.symlink?
    return nil if stat.size > Hive::ARTIFACT_CAPTURE_MANIFEST_MAX_BYTES

    manifest = JSON.parse(File.binread(path, Hive::ARTIFACT_CAPTURE_MANIFEST_MAX_BYTES))
    return nil unless manifest.is_a?(Hash)
    return nil unless manifest["schema"] == "hive-artifact-capture"
    return nil unless [ 1, 2 ].include?(manifest["schema_version"])
    if manifest["schema_version"] == 2
      return nil unless CAPTURE_MANIFEST_V2_SCHEMER.valid?(manifest)
    end

    status = manifest["status"].to_s
    return nil unless %w[captured failed].include?(status)

    {
      "status" => status,
      "reason" => manifest["diagnostic"].to_s,
      "items" => normalized_capture_items(manifest["artifacts"])
    }
  rescue JSON::ParserError, SystemCallError => e
    Rails.logger.warn("capture manifest unreadable for #{slug}: #{e.class}: #{e.message}")
    nil
  end

  def normalized_capture_items(artifacts)
    Array(artifacts).filter_map do |artifact|
      next unless artifact.is_a?(Hash)

      file = artifact["file"].to_s
      next unless File.basename(file) == file && file.match?(MEDIA_FILENAME_RE)
      path = media_path(file)
      next unless path
      next unless File.size(path) == Integer(artifact["bytes"], exception: false)
      next unless Digest::SHA256.file(path).hexdigest == artifact["sha256"].to_s

      extension = File.extname(file).downcase
      {
        "file" => file,
        "type" => %w[.webm .mp4].include?(extension) ? "video" : "still",
        "caption" => extension == ".png" ? "Captured browser state" : "Captured browser demo",
        "screenote_url" => nil
      }
    rescue SystemCallError
      nil
    end
  end
end
