require "open3"
require "tempfile"

class Repository
  Registration = Data.define(:project, :warning)

  GITHUB_URL_RE = %r{\Ahttps://github\.com/[\w.-]+/[\w.-]+?(?:\.git)?\z}
  GITHUB_SSH_RE = %r{\Agit@github\.com:[\w.-]+/[\w.-]+?(?:\.git)?\z}
  GH_SHORTHAND_RE = %r{\A[\w.-]+/[\w.-]+\z}
  CLONE_TIMEOUT_SEC = Integer(ENV.fetch("HIVEBOX_CLONE_TIMEOUT_SEC", 180))

  attr_reader :source, :name, :path

  def initialize(source:, name: nil, token: nil, root: nil)
    @source = source.to_s.strip
    raise Hive::Error, "repo URL required" if @source.empty?
    raise Hive::Error, "invalid repo URL — use a github.com URL or owner/repo" unless valid_source?

    @name = normalized_name(name)
    @token = token
    @root = root || ENV["HIVEBOX_REPOS_DIR"] || File.join(Hive::Paths.data_home, "repos")
    @path = File.join(@root, @name)
  end

  def register!(setup:, workflow: nil)
    FileUtils.mkdir_p(@root)
    ensure_owned_target!
    clone! unless File.directory?(path)
    normalize_origin!

    project = Project.new("name" => name, "path" => path)
    Registration.new(project:, warning: project.setup!(setup, workflow:))
  end

  private

  def normalized_name(value)
    candidate = value.to_s.strip
    candidate = File.basename(source).delete_suffix(".git") if candidate.empty?
    candidate = File.basename(candidate)
    if candidate.empty? || candidate == "." || candidate == ".."
      raise Hive::Error, "invalid repo name"
    end

    candidate
  end

  def valid_source?
    return false if source.start_with?("-")

    GITHUB_URL_RE.match?(source) || GITHUB_SSH_RE.match?(source) || GH_SHORTHAND_RE.match?(source)
  end

  def ensure_owned_target!
    return unless File.symlink?(path) || (File.exist?(path) && !File.directory?(path))

    raise Hive::Error, "#{name} already exists under the repos root and is not a directory — remove it first"
  end

  def clone!
    raise Hive::Error, "clone target already exists: #{name}" if File.exist?(path)

    env = @token ? { "GH_TOKEN" => @token } : {}
    log = Tempfile.create("hivebox-clone")
    pid = Process.spawn(env, "gh", "repo", "clone", source, path,
                        pgroup: true, out: log.path, err: log.path)
    deadline = monotonic_now + CLONE_TIMEOUT_SEC
    status = wait_for_clone(pid, deadline)
    return if status.success?

    FileUtils.rm_rf(path)
    raise Hive::Error, "clone failed: #{File.read(log.path).strip}"
  ensure
    log&.close
    File.unlink(log.path) if log && File.exist?(log.path)
  end

  def wait_for_clone(pid, deadline)
    loop do
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      return status if status

      if monotonic_now > deadline
        Process.kill("KILL", -pid) rescue nil
        Process.waitpid2(pid) rescue nil
        FileUtils.rm_rf(path)
        raise Hive::Error, "clone timed out after #{CLONE_TIMEOUT_SEC}s — check the network and try again"
      end
      sleep 0.2
    end
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def normalize_origin!
    out, err, status = Open3.capture3("git", "-C", path, "remote", "get-url", "origin")
    unless status.success?
      Rails.logger.warn("origin not normalized for #{path}: #{err.strip.presence || out.strip}")
      return
    end

    url = out.strip
    https = url.sub(%r{\A(?:ssh://)?git@github\.com[:/]}, "https://github.com/")
    if https == url
      unless url.start_with?("https://github.com/")
        Rails.logger.warn("origin for #{path} is #{url.inspect} — the box can only push to https://github.com remotes")
      end
      return
    end

    _out, err, set_status = Open3.capture3("git", "-C", path, "remote", "set-url", "origin", https)
    raise Hive::Error, "failed to switch origin to https: #{err.strip}" unless set_status.success?
  end
end
