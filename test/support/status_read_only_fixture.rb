#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "open3"
require "time"
require "yaml"

$LOAD_PATH.unshift(File.expand_path("../../components/agent-cli-runtime/lib", __dir__))
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "hive"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/status"
require "hive/daemon/operational_snapshot"
require "hive/runtime_control_plane/installation"
require "hive/runtime_control_plane/operational_repository"

module StatusReadOnlyFixture
  module_function

  STATE_HOME = "/state"
  PROJECT_ROOT = "/project"
  PROJECT_NAME = "project"

  def call(argv)
    command = argv.shift
    case command
    when "prepare"
      prepare(task_slug: argv.fetch(0), cache_variant: argv.fetch(1), daemon_pid: argv.fetch(2))
    when "publish-wal"
      publish_wal(cache_variant: argv.fetch(0), daemon_pid: argv.fetch(1))
    when "mount-proof"
      mount_proof
    else
      abort "unknown fixture command: #{command.inspect}"
    end
  end

  def prepare(task_slug:, cache_variant:, daemon_pid:)
    FileUtils.mkdir_p(STATE_HOME, mode: 0o700)
    FileUtils.mkdir_p(PROJECT_ROOT, mode: 0o700)
    File.chmod(0o700, STATE_HOME)
    File.chmod(0o700, PROJECT_ROOT)
    File.write(File.join(STATE_HOME, "config.yml"), { "registered_projects" => [] }.to_yaml)

    run!("git", "-C", PROJECT_ROOT, "init", "-b", "main", "--quiet")
    run!("git", "-C", PROJECT_ROOT, "config", "user.email", "readonly@example.com")
    run!("git", "-C", PROJECT_ROOT, "config", "user.name", "Read-only fixture")
    run!("git", "-C", PROJECT_ROOT, "config", "commit.gpgsign", "false")
    run!("git", "-C", PROJECT_ROOT, "config", "maintenance.auto", "false")
    run!("git", "-C", PROJECT_ROOT, "config", "gc.auto", "0")
    File.write(File.join(PROJECT_ROOT, "README.md"), "read-only status fixture\n")
    run!("git", "-C", PROJECT_ROOT, "add", "README.md")
    run!("git", "-C", PROJECT_ROOT, "commit", "-m", "initial", "--quiet")

    Hive::RuntimeControlPlane::Installation.setup(state_home: STATE_HOME)
    Hive::Commands::Init.new(
      PROJECT_ROOT, workflow: "coding", agent_skill_preflight: false
    ).call
    Hive::Commands::New.new(
      PROJECT_NAME, task_slug.tr("-", " "), slug_override: task_slug
    ).call!
    publish_observation(cache_variant: cache_variant, daemon_pid: daemon_pid)
    close_cleanly
    puts JSON.generate(
      "prepared" => true,
      "task_slug" => task_slug,
      "cache_variant" => cache_variant
    )
  end

  def publish_wal(cache_variant:, daemon_pid:)
    database = Hive::RuntimeControlPlane.database
    database.open!
    database.read { |db| db.run("PRAGMA wal_autocheckpoint=0") }
    publish_observation(cache_variant: cache_variant, daemon_pid: daemon_pid)
    $stdout.puts JSON.generate(
      "published" => true,
      "cache_variant" => cache_variant,
      "database_sha256" => Digest::SHA256.file(database.path).hexdigest
    )
    $stdout.flush
    Process.exit!(0)
  end

  def publish_observation(cache_variant:, daemon_pid:)
    pid = Integer(daemon_pid, 10)
    start_time = Hive::Lock.process_start_time(pid) ||
      raise("host daemon pid #{pid} is not visible in the container PID namespace")
    daemon = Hive::Daemon::OperationalSnapshot.daemon_identity(
      pid: pid, process_start_time: start_time
    )
    File.write(
      File.join(STATE_HOME, ".daemon.pid"),
      { "pid" => pid, "process_start_time" => start_time }.to_yaml
    )

    projects = Hive::Config.registered_projects
    payload = Hive::Commands::Status.new(json: true).active_payload(projects)
    repository = Hive::RuntimeControlPlane::OperationalRepository.new
    assembler = Hive::Daemon::OperationalSnapshot::Assembler.new(
      repository: repository,
      daemon_identity: daemon,
      poll_interval_sec: 120
    )
    now = Time.now.utc
    assembler.begin_tick(now: now)
    assembler.complete(
      rows: snapshot_rows(payload), controller: {}, queue: {}, recoveries: {},
      status_payload: cache_variant == "valid" ? payload : nil,
      now: now
    )
    return unless cache_variant == "expired"

    snapshot = repository.snapshot
    expired_at = now - 60
    repository.publish(
      snapshot,
      status_projection: {
        "schema" => Hive::Daemon::OperationalSnapshot::StatusCache::SCHEMA,
        "schema_version" => Hive::Daemon::OperationalSnapshot::StatusCache::SCHEMA_VERSION,
        "daemon" => daemon,
        "tick_sequence" => snapshot.fetch("tick_sequence"),
        "published_at" => expired_at.iso8601(6),
        "valid_until" => (expired_at + 1).iso8601(6),
        "runtime" => Hive::RuntimeIdentity.new.to_h,
        "payload" => payload
      }
    )
  end

  def snapshot_rows(payload)
    payload.fetch("projects").flat_map do |project|
      project.fetch("tasks").map do |task|
        task.merge(
          "project" => project.fetch("name"),
          "marker_attrs" => task.fetch("attrs"),
          "status_payload_mtime" => task.fetch("mtime"),
          "state_file_mtime" => task.fetch("observation_mtime")
        )
      end
    end
  end

  def close_cleanly
    path = Hive::Paths.runtime_control_plane_path(STATE_HOME)
    Hive::RuntimeControlPlane.disconnect
    raw = SQLite3::Database.new(path)
    raw.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    raw.close
  end

  def mount_proof
    results = [ "/", STATE_HOME, PROJECT_ROOT ].to_h do |path|
      mount = mount_for(path)
      probe = File.join(path, ".hive-read-only-probe-#{Process.pid}")
      error = begin
        File.write(probe, "must not be written\n")
        "write_succeeded"
      rescue SystemCallError => exception
        exception.class.name
      ensure
        FileUtils.rm_f(probe) if File.exist?(probe)
      end
      [
        path,
        {
          "mount_point" => mount.fetch(:mount_point),
          "mount_options" => mount.fetch(:mount_options),
          "super_options" => mount.fetch(:super_options),
          "read_only" => mount.fetch(:read_only),
          "write_probe" => error
        }
      ]
    end
    puts JSON.generate(results)
  end

  def mount_for(path)
    target = File.realpath(path)
    candidates = File.readlines("/proc/self/mountinfo", chomp: true).filter_map do |line|
      left, right = line.split(" - ", 2)
      next unless right

      fields = left.split
      mount_point = decode_mount_path(fields.fetch(4))
      next unless target == mount_point || target.start_with?("#{mount_point}/") || mount_point == "/"

      super_options = right.split.fetch(2).split(",")
      mount_options = fields.fetch(5).split(",")
      {
        mount_point: mount_point,
        mount_options: mount_options,
        super_options: super_options,
        read_only: mount_options.include?("ro") || super_options.include?("ro")
      }
    end
    candidates.max_by { |entry| entry.fetch(:mount_point).length } ||
      raise("no mountinfo entry for #{target}")
  end

  def decode_mount_path(value)
    value.gsub(/\\([0-7]{3})/) { Regexp.last_match(1).to_i(8).chr }
  end

  def run!(*command)
    stdout, stderr, status = Open3.capture3(*command)
    return stdout if status.success?

    raise "#{command.join(' ')} failed (#{status.exitstatus}): #{stderr}#{stdout}"
  end
end

StatusReadOnlyFixture.call(ARGV)
