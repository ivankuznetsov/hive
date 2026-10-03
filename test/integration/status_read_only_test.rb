require "test_helper"
require "digest"
require "find"
require "json"
require "json_schemer"
require "open3"
require "securerandom"

class StatusReadOnlyIntegrationTest < Minitest::Test
  include HiveTestHelper

  ROOT = File.expand_path("../..", __dir__)
  DOCKERFILE = File.join(ROOT, "test", "support", "status_read_only.Dockerfile")
  FIXTURE = "/app/test/support/status_read_only_fixture.rb"
  CACHE_VARIANTS = %w[valid absent expired].freeze
  CLEAN_TASK = "clean-read-only-audit-task"
  WAL_TASK = "paired-wal-audit-task"
  GENERAL_ACTION = "Use a writable, accessible state root (HIVE_HOME).".freeze
  UNPAIRED_ACTION = "Use a writable state root (HIVE_HOME), or safely restore a matching WAL/SHM pair or remove the stray sidecar after verifying no committed data will be lost.".freeze

  def test_operational_status_on_real_read_only_mounts
    assert_docker_available!
    image = build_candidate_image!
    evidence = {
      "candidate_revision" => git_revision,
      "candidate_source_digest" => source_digest,
      "docker_server" => docker_server_version,
      "image" => image,
      "uid" => Process.uid,
      "gid" => Process.gid,
      "scenarios" => []
    }

    Dir.mktmpdir("hive-status-read-only") do |root|
      CACHE_VARIANTS.each do |variant|
        evidence.fetch("scenarios") << prove_clean_fixture(root, image, variant)
      end
      CACHE_VARIANTS.each do |variant|
        evidence.fetch("scenarios") << prove_paired_wal_fixture(root, image, variant)
      end
      %w[wal shm].each do |sidecar|
        evidence.fetch("scenarios") << prove_unpaired_fixture(root, image, sidecar)
      end
    end

    assert_equal 8, evidence.fetch("scenarios").size,
                 "every required cache and sidecar scenario must finish"
    evidence_path = File.join(ROOT, "tmp", "status-read-only-evidence.json")
    FileUtils.mkdir_p(File.dirname(evidence_path))
    File.write(evidence_path, JSON.pretty_generate(evidence) << "\n")
    puts "STATUS_READ_ONLY_EVIDENCE=#{JSON.generate(evidence)}"
  end

  private

  def prove_clean_fixture(root, image, variant)
    fixture = fixture_paths(root, "ae1-#{variant}")
    prepare_fixture(image, fixture, task_slug: CLEAN_TASK, cache_variant: variant)
    assert_no_sidecars(fixture)
    before = inventory(fixture)
    mount = assert_mount_proof(image, fixture)
    runtime = assert_runtime_success(run_hive(image, fixture, "runtime", "status", "--json"))
    operational = assert_operational_success(
      run_hive(image, fixture, "status", "--operational", "--json"),
      task_slug: CLEAN_TASK,
      expected_provenance: variant == "valid" ? "daemon_cache" : "fresh_scan"
    )
    assert_equal before, inventory(fixture), "AE1 #{variant} mutated mounted state"
    {
      "scenario" => "AE1",
      "cache" => variant,
      "mount" => mount,
      "runtime_exit" => runtime.fetch("exit"),
      "operational_exit" => operational.fetch("exit"),
      "task_slug" => CLEAN_TASK,
      "state_unchanged" => true
    }
  end

  def prove_paired_wal_fixture(root, image, variant)
    fixture = fixture_paths(root, "ae4-#{variant}")
    prepare_fixture(image, fixture, task_slug: WAL_TASK, cache_variant: "absent")
    assert_no_sidecars(fixture)
    database = File.join(fixture.fetch(:state), "runtime-control-plane.sqlite3")
    main_before_wal = Digest::SHA256.file(database).hexdigest
    result = docker_run(
      image, fixture, writable: true,
      command: fixture_command("publish-wal", variant, Process.pid.to_s)
    )
    assert_equal 0, result.fetch(:status), result.fetch(:stderr)
    wal = "#{database}-wal"
    shm = "#{database}-shm"
    assert_path_exists wal, "abnormal writer must retain WAL"
    assert_path_exists shm, "abnormal writer must retain SHM"
    assert_operator File.size(wal), :>, 0, "retained WAL must contain committed frames"
    assert_equal main_before_wal, Digest::SHA256.file(database).hexdigest,
                 "the committed observation must remain WAL-only before the audit"

    before = inventory(fixture)
    mount = assert_mount_proof(image, fixture)
    runtime = assert_ae4_outcome(
      run_hive(image, fixture, "runtime", "status", "--json"),
      command: "runtime status", task_slug: nil
    )
    operational = assert_ae4_outcome(
      run_hive(image, fixture, "status", "--operational", "--json"),
      command: "status --operational", task_slug: WAL_TASK,
      expected_provenance: variant == "valid" ? "daemon_cache" : "fresh_scan"
    )
    assert_equal before, inventory(fixture), "AE4 #{variant} mutated retained state or sidecars"
    {
      "scenario" => "AE4",
      "cache" => variant,
      "mount" => mount,
      "wal_bytes" => File.size(wal),
      "main_database_unchanged_before_audit" => true,
      "runtime" => runtime,
      "operational" => operational,
      "state_unchanged" => true
    }
  end

  def prove_unpaired_fixture(root, image, sidecar)
    fixture = fixture_paths(root, "unpaired-#{sidecar}")
    prepare_fixture(image, fixture, task_slug: "unpaired-#{sidecar}-task", cache_variant: "absent")
    assert_no_sidecars(fixture)
    database = File.join(fixture.fetch(:state), "runtime-control-plane.sqlite3")
    path = "#{database}-#{sidecar}"
    File.binwrite(path, "unpaired #{sidecar} proof\n")
    File.chmod(0o600, path)
    before = inventory(fixture)
    mount = assert_mount_proof(image, fixture)
    runtime = assert_unpaired_error(
      run_hive(image, fixture, "runtime", "status", "--json"), sidecar: sidecar
    )
    operational = assert_unpaired_error(
      run_hive(image, fixture, "status", "--operational", "--json"), sidecar: sidecar
    )
    assert_equal before, inventory(fixture), "#{sidecar}-only audit mutated state"
    counterpart = sidecar == "wal" ? "#{database}-shm" : "#{database}-wal"
    refute_path_exists counterpart, "#{sidecar}-only audit must not create its missing pair"
    {
      "scenario" => "unpaired-#{sidecar}",
      "mount" => mount,
      "runtime_exit" => runtime.fetch("exit"),
      "operational_exit" => operational.fetch("exit"),
      "state_unchanged" => true
    }
  end

  def fixture_paths(root, name)
    fixture = {
      state: File.join(root, name, "state"),
      project: File.join(root, name, "project")
    }
    fixture.each_value { |path| FileUtils.mkdir_p(path, mode: 0o700) }
    fixture
  end

  def prepare_fixture(image, fixture, task_slug:, cache_variant:)
    result = docker_run(
      image, fixture, writable: true,
      command: fixture_command(
        "prepare", task_slug, cache_variant, Process.pid.to_s
      )
    )
    assert_equal 0, result.fetch(:status), result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout).lines.last)
    assert_equal true, payload.fetch("prepared")
  end

  def assert_mount_proof(image, fixture)
    result = docker_run(image, fixture, command: fixture_command("mount-proof"))
    assert_equal 0, result.fetch(:status), result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    [ "/", "/state", "/project" ].each do |path|
      proof = payload.fetch(path)
      assert_equal true, proof.fetch("read_only"), "#{path} is not mounted read-only"
      refute_equal "write_succeeded", proof.fetch("write_probe"),
                   "write probe unexpectedly succeeded on #{path}"
    end
    payload
  end

  def run_hive(image, fixture, *arguments)
    docker_run(
      image, fixture,
      command: [ "/app/bin/hive", *arguments ]
    )
  end

  def assert_runtime_success(result)
    assert_equal 0, result.fetch(:status), result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "hive-runtime-maintenance", payload.fetch("schema")
    assert_equal true, payload.fetch("ok")
    assert schema_for(payload.fetch("schema")).valid?(payload),
           schema_for(payload.fetch("schema")).validate(payload).to_a.inspect
    { "exit" => result.fetch(:status), "outcome" => "success" }
  end

  def assert_operational_success(result, task_slug:, expected_provenance: nil)
    assert_equal 0, result.fetch(:status), result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal true, payload.fetch("ok")
    assert operational_schema.valid?(payload), operational_schema.validate(payload).to_a.inspect
    task = payload.fetch("tasks").find { |candidate| candidate.dig("identity", "slug") == task_slug }
    assert task, "operational output omitted #{task_slug}: #{payload.inspect}"
    assert_equal "current", task.dig("freshness", "scheduler_status"),
                 "the task row committed with the daemon observation was not joined"
    if expected_provenance
      assert_equal expected_provenance, payload.dig("source", "task_graph", "provenance")
    end
    { "exit" => result.fetch(:status), "outcome" => "success" }
  end

  def assert_ae4_outcome(result, command:, task_slug:, expected_provenance: nil)
    return assert_operational_success(
      result, task_slug: task_slug, expected_provenance: expected_provenance
    ).merge("command" => command) if result.fetch(:status).zero? && task_slug
    return assert_runtime_success(result).merge("command" => command) if
      result.fetch(:status).zero?

    payload = JSON.parse(result.fetch(:stdout))
    assert_storage_error(payload, result, action: GENERAL_ACTION)
    puts "AE4_DEGRADED=#{JSON.generate(
      "command" => command,
      "exit" => result.fetch(:status),
      "payload" => payload,
      "stderr" => result.fetch(:stderr)
    )}"
    { "command" => command, "exit" => result.fetch(:status), "outcome" => "wal_index_recovery_blocked" }
  end

  def assert_unpaired_error(result, sidecar:)
    refute_equal 0, result.fetch(:status), "#{sidecar}-only inspection unexpectedly succeeded"
    payload = JSON.parse(result.fetch(:stdout))
    assert_storage_error(payload, result, action: UNPAIRED_ACTION)
    { "exit" => result.fetch(:status), "outcome" => "state_storage_read_only" }
  end

  def assert_storage_error(payload, result, action:)
    code = payload["runtime_code"] || payload["code"]
    assert_equal "state_storage_read_only", code, payload.inspect
    assert_equal action, payload.fetch("next_action")
    assert schema_for(payload.fetch("schema")).valid?(payload),
           schema_for(payload.fetch("schema")).validate(payload).to_a.inspect
    combined = [ payload, result.fetch(:stderr) ].join(" ")
    assert_match(/read.?only/i, combined, "failure must identify read-only storage")
    refute_match(/backup|recover from/i, combined, "storage failure must not prescribe backup recovery")
  end

  def assert_no_sidecars(fixture)
    database = File.join(fixture.fetch(:state), "runtime-control-plane.sqlite3")
    refute_path_exists "#{database}-wal"
    refute_path_exists "#{database}-shm"
  end

  def inventory(fixture)
    fixture.sort.to_h do |label, root|
      entries = {}
      Find.find(root) do |path|
        stat = File.lstat(path)
        relative = path.delete_prefix("#{root}/")
        relative = "." if path == root
        entries[relative] = {
          "type" => stat.ftype,
          "mode" => stat.mode & 0o7777,
          "uid" => stat.uid,
          "gid" => stat.gid,
          "size" => stat.size,
          "sha256" => stat.file? ? Digest::SHA256.file(path).hexdigest : nil,
          "target" => stat.symlink? ? File.readlink(path) : nil
        }
      end
      [ label.to_s, entries ]
    end
  end

  def fixture_command(*arguments)
    [ "ruby", "-I/app/lib", "-I/app/components/agent-cli-runtime/lib", FIXTURE, *arguments ]
  end

  def docker_run(image, fixture, command:, writable: false)
    argv = [
      "docker", "run", "--rm", "--pid=host", "--user", "#{Process.uid}:#{Process.gid}",
      "--env", "HIVE_HOME=/state", "--env", "HOME=/tmp",
      "--env", "HIVE_SKIP_LLM_WIKI_SCHEDULER=1",
      "--env", "HIVE_SKIP_LLM_WIKI_SYSTEMCTL=1",
      "--env", "HIVE_SKIP_LLM_WIKI_POST_COMMIT=1",
      "--volume", "#{fixture.fetch(:state)}:/state:#{writable ? 'rw' : 'ro'}",
      "--volume", "#{fixture.fetch(:project)}:/project:#{writable ? 'rw' : 'ro'}"
    ]
    unless writable
      argv.concat([
        "--read-only",
        "--tmpfs", "/tmp:rw,nosuid,nodev,uid=#{Process.uid},gid=#{Process.gid},mode=1777"
      ])
    end
    stdout, stderr, status = Open3.capture3(*argv, image, *command, chdir: ROOT)
    { stdout: stdout, stderr: stderr, status: status.exitstatus }
  end

  def assert_docker_available!
    stdout, stderr, status = Open3.capture3("docker", "version", "--format", "{{.Server.Version}}")
    assert status.success?, "Docker server is required: #{stderr}#{stdout}"
    refute_empty stdout.strip, "Docker server version was empty"
  rescue Errno::ENOENT => error
    flunk "Docker is required for the read-only mount gate: #{error.message}"
  end

  def build_candidate_image!
    image = "hive-status-read-only:#{source_digest[0, 16]}"
    stdout, stderr, status = Open3.capture3(
      "docker", "build", "--file", DOCKERFILE, "--tag", image, ROOT,
      chdir: ROOT
    )
    assert status.success?, "Docker image build failed:\n#{stderr}\n#{stdout}"
    image
  end

  def operational_schema
    schema_for("hive-operational-status")
  end

  def schema_for(name)
    @schemas ||= {}
    @schemas[name] ||= JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path(name)))
    )
  end

  def git_revision
    stdout, = Open3.capture2("git", "rev-parse", "HEAD", chdir: ROOT)
    stdout.strip
  end

  def docker_server_version
    stdout, = Open3.capture2("docker", "version", "--format", "{{.Server.Version}}")
    stdout.strip
  end

  def source_digest
    @source_digest ||= begin
      paths = %w[
        Gemfile Gemfile.lock hive.gemspec bin lib schemas components/agent-cli-runtime
        test/support/status_read_only.Dockerfile test/support/status_read_only_fixture.rb
      ]
      digest = Digest::SHA256.new
      paths.each do |relative|
        absolute = File.join(ROOT, relative)
        files = File.directory?(absolute) ? Dir.glob(File.join(absolute, "**", "*")) : [ absolute ]
        files.select { |path| File.file?(path) }.sort.each do |path|
          digest << path.delete_prefix("#{ROOT}/") << "\0" << File.binread(path) << "\0"
        end
      end
      digest.hexdigest
    end
  end
end
