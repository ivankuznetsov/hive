# Project pages read history independently of the active fleet poller. Cache
# each project briefly; a stage move invalidates it immediately.
class ProjectArchive
  CACHE = ActiveSupport::Cache::MemoryStore.new(size: 16.megabytes)

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
