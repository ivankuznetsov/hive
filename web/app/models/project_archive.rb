# Project pages read history independently of the active fleet poller. Cache
# each project briefly; a stage move invalidates it immediately.
class ProjectArchive
  CACHE = ActiveSupport::Cache::MemoryStore.new(size: 16.megabytes)
  REQUESTS = ActiveSupport::Cache::MemoryStore.new(size: 256.kilobytes, expires_in: 2.minutes)

  # Requests only subscribe to history. The existing status poller performs
  # the read, publishes it over Cable, and persists it with the active rows.
  def self.request(project)
    REQUESTS.write(identity(project).to_json, :pending, expires_in: nil)
  end

  def self.refreshed(project)
    key = identity(project).to_json
    REQUESTS.write(key, :cached) if REQUESTS.read(key) == :pending
  end

  def self.requested?(project)
    REQUESTS.read(identity(project).to_json)
  end

  def self.identity(project)
    project.values_at("name", "path", "hive_state_path")
  end

  def self.snapshot(project)
    stages = File.join(project.hive_state_path, "stages")
    revision = Dir.glob(File.join(stages, "*")).sort.map do |path|
      [ path, File.mtime(path).to_f ]
    rescue Errno::ENOENT
      [ path, nil ]
    end
    CACHE.fetch([ project.path, project.hive_state_path, revision ], expires_in: 1.minute) do
      Hive::Commands::Status.new(json: true, archive: true).json_payload([ project.attributes ])
    end
  end
end
