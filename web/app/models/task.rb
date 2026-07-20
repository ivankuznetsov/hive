require "tempfile"

class Task
  ARTIFACT_ORDER = %w[idea.md brainstorm.md plan.md task.md pr.md summary.md artifact.md].freeze
  MEDIA_FILENAME_RE = /\A[\w.-]+\.(?:png|jpe?g|gif)\z/i
  DIFF_TIMEOUT_SEC = Integer(ENV.fetch("HIVEBOX_DIFF_TIMEOUT_SEC", 15))
  DIFF_MAX_BYTES = 512 * 1024
  RECOVERY_ACTIONS = %w[recover_execute recover_review error].freeze
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

  Diff = Data.define(:content, :truncated?)

  attr_reader :project

  def self.find!(project:, slug:, snapshot: StatusBroadcaster.snapshot)
    project_payload = snapshot.fetch("projects", []).find { |candidate| candidate["name"] == project.name }
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

  def folder
    self["folder"]
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

  def media_manifest
    return nil unless folder

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
    return [] unless folder

    path = File.join(folder, "brainstorm.md")
    return [] unless File.file?(path)

    Hive::Bot::BrainstormParser.unanswered_questions(Hive::Bot::BrainstormParser.parse(path))
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
    return "stage" if action == "ready_to_run"

    action.sub(/\Aready_(?:to|for)_/, "").tr("_", "-")
  end

  def terminal?
    Hive::Workflows.all_terminal_stage_dirs.include?(self["stage"].to_s)
  end

  def diff
    unless worktree?
      raise Hive::InvalidTaskPath, "no worktree for #{slug}"
    end

    log = Tempfile.create("hivebox-diff")
    pid = Process.spawn("git", "-C", worktree_path, "diff", "--",
                        pgroup: true, out: log.path, err: log.path)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DIFF_TIMEOUT_SEC
    status = wait_for_diff(pid, deadline)
    raise Hive::Error, "git diff failed: #{File.read(log.path).strip}" unless status.success?

    output = File.open(log.path, "rb") { |file| file.read(DIFF_MAX_BYTES + 1) }
                 .to_s.force_encoding(Encoding::UTF_8).scrub
    truncated = output.bytesize > DIFF_MAX_BYTES
    content = truncated ? output.byteslice(0, DIFF_MAX_BYTES).scrub : output
    Diff.new(content:, truncated?: truncated)
  ensure
    log&.close
    File.unlink(log.path) if log && File.exist?(log.path)
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

  def original_idea_line
    text = original_idea_text.to_s.gsub(/\[image\d+\]/, "")
    text.strip.lines.first.to_s.strip.presence&.truncate(90)
  end

  def wait_for_diff(pid, deadline)
    loop do
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      return status if status

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Process.kill("KILL", -pid) rescue nil
        Process.waitpid2(pid) rescue nil
        raise Hive::Error, "git diff timed out after #{DIFF_TIMEOUT_SEC}s"
      end
      sleep 0.1
    end
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
end
