require "digest"
require "json_schemer"
require "pathname"
require "shellwords"
require "hive/web/environment"
require "hive/task_workspace/artifacts"
require "hive/task_workspace/publication"
require "hive/artifacts/outcome_evidence/store"

class Task
  include TaskMutations

  class VerifiedEvidenceBody
    include Enumerable

    CHUNK_BYTES = 64 * 1024

    def initialize(io, bytes)
      @io = io
      @bytes = bytes
    end

    def each
      return enum_for(__method__) unless block_given?

      begin
        remaining = @bytes
        while remaining.positive? && (chunk = @io.read([ CHUNK_BYTES, remaining ].min))
          yield chunk
          remaining -= chunk.bytesize
        end
      ensure
        close
      end
    end

    def close
      @io.close unless @io.closed?
    end
  end

  BoundBrainstormQuestion = Struct.new(
    :round, :n, :text, :binding, :ordinal, keyword_init: true
  )

  ARTIFACT_ORDER = %w[idea.md brainstorm.md plan.md task.md pr.md summary.md artifact.md].freeze
  MEDIA_FILENAME_RE = /\A[\w.-]+\.(?:png|jpe?g|gif|webp|webm|mp4)\z/i
  EVIDENCE_ATTEMPT_RE = Hive::Artifacts::OutcomeEvidence::Store::SAFE_ID
  EVIDENCE_DIGEST_RE = Hive::Artifacts::OutcomeEvidence::Store::DIGEST
  EVIDENCE_MEDIA_TYPES = {
    "image/png" => [ "image/png", "inline" ],
    "image/jpeg" => [ "image/jpeg", "inline" ],
    "image/webp" => [ "image/webp", "inline" ],
    "video/webm" => [ "video/webm", "inline" ],
    "video/mp4" => [ "video/mp4", "inline" ],
    "text/plain" => [ "text/plain; charset=utf-8", "inline" ],
    "text/markdown" => [ "text/markdown; charset=utf-8", "attachment" ],
    "application/json" => [ "application/json", "attachment" ],
    "application/pdf" => [ "application/pdf", "attachment" ],
    "application/x-asciinema+json" => [ "application/octet-stream", "attachment" ]
  }.freeze
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
    artifact_panel.fetch("records").filter_map do |record|
      [ record.fetch("name"), record["content"] ] unless record["binary"]
    end
  end

  def artifact_panel
    return Hive::TaskWorkspace.unavailable_panel("artifacts") unless
      folder && File.directory?(folder)

    Hive::TaskWorkspace::Artifacts.new(
      task_root: folder, references: artifact_order
    ).call
  end

  def publication(cache: nil)
    Hive::TaskWorkspace::Publication.new(
      task: self,
      expected_repository: project["repository_identity"],
      cache: cache
    ).call
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

  def outcome_evidence
    return nil unless folder

    current = File.join(folder, "outcome-evidence", "current.json")
    return nil unless File.file?(current) || File.symlink?(current)

    normalize_outcome_evidence(outcome_evidence_store.package_metadata)
  rescue Hive::Artifacts::OutcomeEvidence::Error, SystemCallError => e
    Rails.logger.warn("outcome evidence unreadable for #{slug}: #{e.class}")
    {
      "status" => "invalid",
      "reason" => "Outcome evidence failed integrity validation and was not rendered."
    }
  end

  def outcome_evidence_file(attempt_id, digest)
    attempt_id = attempt_id.to_s
    digest = digest.to_s.downcase
    return nil unless attempt_id.match?(EVIDENCE_ATTEMPT_RE) && digest.match?(EVIDENCE_DIGEST_RE)

    package = outcome_evidence_store.package_metadata
    attempt = package.fetch("attempts").find { |item| item.fetch("attempt_id") == attempt_id }
    return nil unless attempt

    representation = attempt.fetch("evidence").flat_map do |entry|
      entry.fetch("representations")
    end.find { |item| item.fetch("sha256") == digest }
    return nil unless representation

    media = EVIDENCE_MEDIA_TYPES[representation.fetch("media_type")]
    return nil unless media

    path = File.join(folder, representation.fetch("path"))
    io = File.open(path, File::RDONLY | File::NOFOLLOW)
    expected_bytes = representation.fetch("bytes")
    unless io.stat.file? && io.stat.size == expected_bytes
      io.close
      return nil
    end
    actual_digest = Digest::SHA256.new
    observed_bytes = 0
    while (chunk = io.read(VerifiedEvidenceBody::CHUNK_BYTES))
      observed_bytes += chunk.bytesize
      if observed_bytes > expected_bytes
        io.close
        return nil
      end
      actual_digest << chunk
    end
    unless observed_bytes == expected_bytes && actual_digest.hexdigest == digest
      io.close
      return nil
    end
    io.rewind

    {
      "body" => VerifiedEvidenceBody.new(io, expected_bytes),
      "bytes" => expected_bytes,
      "filename" => File.basename(representation.fetch("path")),
      "content_type" => media.first,
      "disposition" => media.last
    }
  rescue Hive::Artifacts::OutcomeEvidence::Error, SystemCallError
    io&.close unless io&.closed?
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

    STAGE_DISPATCH_ACTIONS[self["stage"].to_s.split("-", 2).first]
  end

  def run_verb
    action = dispatch_action
    return unless action

    command = Hive::TaskAction::READY_COMMANDS.fetch(action)
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

  def outcome_evidence_store
    Hive::Artifacts::OutcomeEvidence::Store.new(task: self, project: project.name)
  end

  def normalize_outcome_evidence(package)
    current = package.fetch("current")
    requirement = package.fetch("requirement")
    attempts = package.fetch("attempts")
    active_attempt = attempts.last
    verdicts = active_attempt&.dig("review", "verdicts").to_a.to_h do |verdict|
      [ verdict.fetch("target_id"), verdict ]
    end
    evidence = active_attempt&.fetch("evidence").to_a
    normalize_target = lambda do |target|
      id = target.fetch("id")
      {
        "id" => id,
        "statement" => target.fetch("statement"),
        "proof_kind" => target["proof_kind"],
        "reason" => target["reason"],
        "changed_paths" => target.fetch("changed_paths"),
        "verdict" => verdicts[id]&.fetch("verdict", nil),
        "verdict_reason" => verdicts[id]&.fetch("reason", nil),
        "evidence" => evidence.select { |entry| entry.fetch("claims").include?(id) }.map do |entry|
          {
            "kind" => entry.fetch("kind"),
            "summary" => entry.fetch("summary"),
            "representations" => entry.fetch("representations").map do |representation|
              representation.slice("role", "media_type", "rendering", "sha256", "bytes").merge(
                "attempt_id" => active_attempt.fetch("attempt_id"),
                "filename" => File.basename(representation.fetch("path"))
              )
            end
          }
        end
      }
    end
    {
      "status" => current.fetch("status"),
      "generation" => current.fetch("generation"),
      "claims" => requirement.fetch("claims").map(&normalize_target),
      "exclusions" => requirement.fetch("exclusions").map(&normalize_target),
      "changed_path_count" => requirement.dig("implementation", "changed_paths").length,
      "actors" => {
        "inference" => requirement.fetch("inference"),
        "producer" => active_attempt&.fetch("producer", nil),
        "reviewer" => active_attempt&.dig("review", "reviewer")
      },
      "reviewer_capabilities" => requirement.fetch("reviewer_capabilities"),
      "attempts" => attempts.map do |attempt|
        {
          "attempt_id" => attempt.fetch("attempt_id"),
          "status" => attempt.fetch("status"),
          "recorded_at" => attempt.fetch("recorded_at"),
          "diagnostic" => attempt["diagnostic"]
        }
      end,
      "blocker" => if current.fetch("status") == "blocked"
                     current.slice(
                       "reason", "failed_targets", "reviewer_reasons", "recovery_digest",
                       "recovery_epoch"
                     ).merge(
                       "command" => [
                         "hive", "evidence", "recover", "#{project.name}:#{slug}",
                         "--generation", current.fetch("generation"),
                         "--recovery-digest", current.fetch("recovery_digest")
                       ].shelljoin
                     )
                   end
    }
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
