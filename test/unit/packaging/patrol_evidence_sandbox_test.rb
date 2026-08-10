require "test_helper"
require "digest"
require_relative "../../../packaging/patrol_evidence/sandbox"

class PatrolEvidenceSandboxTest < Minitest::Test
  include HiveTestHelper

  Sandbox = HivePatrolEvidence::Sandbox

  def test_exact_container_contract_is_networkless_read_only_and_resource_bounded
    with_tmp_dir do |root|
      fixture = sandbox_fixture(root)
      captured = nil
      sandbox = Sandbox.new(
        image: fixture.fetch(:image),
        engine_probe: -> { engine_identity(fixture.fetch(:image)) },
        executor: ->(argv:, **options) do
          captured = { argv:, options: }
          sandbox_payload(fixture)
        end
      )

      receipt = sandbox.run!(
        candidate: fixture.fetch(:candidate), project_root: fixture.fetch(:project),
        observations_path: fixture.fetch(:observations), controller_root: fixture.fetch(:controller),
        run_root: fixture.fetch(:run_root), image: fixture.fetch(:image)
      )

      argv = captured.fetch(:argv)
      %w[--network=none --read-only --cap-drop=ALL --pids-limit=64 --pull=never].each do |flag|
        assert_includes argv, flag
      end
      assert_includes argv, "no-new-privileges"
      assert_includes argv, "--memory=2g"
      assert_includes argv, "--cpus=2"
      tmpfs = argv.grep(/\A--tmpfs=/)
      assert tmpfs.any? { |value| value.include?("/state") && value.include?("size=535822336") }
      assert tmpfs.any? { |value| value.include?("/dev/shm") && value.include?("size=1048576") }
      assert argv.any? { |value| value.include?("target=/input/source,readonly") }
      assert argv.any? { |value| value.include?("target=/control/test/e2e/lib/patrol_qualification.rb,readonly") }
      assert argv.any? { |value| value.include?("target=/control/lib/hive/secret_patterns.rb,readonly") }
      assert_includes argv, "-r/control/test/e2e/lib/patrol_qualification"
      refute_includes argv, "-r/state/candidate/test/e2e/lib/patrol_qualification"
      refute argv.any? { |value| value.include?("docker.sock") || value.include?(ENV.fetch("HOME")) }
      assert_equal "passed", receipt.dig("sandbox", "status")
      assert_equal "reaped", receipt.dig("process_evidence", 0, "status")
    end
  end

  def test_runtime_or_container_identity_drift_fails_closed
    with_tmp_dir do |root|
      fixture = sandbox_fixture(root)
      probes = [ engine_identity(fixture.fetch(:image)), engine_identity(fixture.fetch(:image)).merge("image_id" => "sha256:#{digest('drift')}") ]
      sandbox = Sandbox.new(
        image: fixture.fetch(:image), engine_probe: -> { probes.shift },
        executor: ->(**) { sandbox_payload(fixture) }
      )

      error = assert_raises(Sandbox::Error) do
        sandbox.run!(
          candidate: fixture.fetch(:candidate), project_root: fixture.fetch(:project),
          observations_path: fixture.fetch(:observations), controller_root: fixture.fetch(:controller),
          run_root: fixture.fetch(:run_root), image: fixture.fetch(:image)
        )
      end
      assert_equal "runtime_identity", error.reason
    end
  end

  def test_same_candidate_runs_receive_distinct_owned_container_names
    with_tmp_dir do |root|
      fixture = sandbox_fixture(root)
      second_run = File.join(root, "run-2")
      FileUtils.mkdir_p(second_run, mode: 0o700)
      names = []
      sandbox = Sandbox.new(
        image: fixture.fetch(:image), engine_probe: -> { engine_identity(fixture.fetch(:image)) },
        executor: ->(name:, **_options) do
          names << name
          sandbox_payload(fixture)
        end
      )

      [ fixture.fetch(:run_root), second_run ].each do |run_root|
        sandbox.run!(
          candidate: fixture.fetch(:candidate), project_root: fixture.fetch(:project),
          observations_path: fixture.fetch(:observations), controller_root: fixture.fetch(:controller),
          run_root:, image: fixture.fetch(:image)
        )
      end

      assert_equal 2, names.uniq.size
      assert names.all? { |name| name.match?(/\Ahive-patrol-u3c-[0-9a-f]{20}\z/) }
    end
  end

  def test_hostile_default_executor_reaps_detached_descendants_on_every_terminal_path
    skip "run rake test:hostile for detached process custody" unless ENV["HIVE_HOSTILE_TESTS"] == "1"

    %w[success failure timeout].each do |behavior|
      with_tmp_dir do |root|
        fixture = sandbox_fixture(root)
        owner_label = digest(File.basename(fixture.fetch(:run_root)))
        payload = HivePatrolEvidence::Result.canonical(
          "candidate" => {}, "payload" => {}
        )
        engine, pid_path = hostile_engine(root, owner_label:, payload:, behavior:)
        identity = engine_identity(fixture.fetch(:image)).merge(
          "engine_path" => engine, "engine_sha256" => Digest::SHA256.file(engine).hexdigest
        )
        sandbox = Sandbox.new(
          image: fixture.fetch(:image), engine_probe: -> { identity },
          timeout: behavior == "timeout" ? 0.2 : 5
        )

        if behavior == "success"
          receipt = sandbox.run!(
            candidate: fixture.fetch(:candidate), project_root: fixture.fetch(:project),
            observations_path: fixture.fetch(:observations), controller_root: fixture.fetch(:controller),
            run_root: fixture.fetch(:run_root), image: fixture.fetch(:image)
          )
          assert_equal "reaped", receipt.dig("process_evidence", 0, "status")
        else
          error = assert_raises(Sandbox::Error) do
            sandbox.run!(
              candidate: fixture.fetch(:candidate), project_root: fixture.fetch(:project),
              observations_path: fixture.fetch(:observations), controller_root: fixture.fetch(:controller),
              run_root: fixture.fetch(:run_root), image: fixture.fetch(:image)
            )
          end
          assert_equal "reaped", error.process_evidence.dig(0, "status")
          assert_equal behavior == "timeout" ? "timeout" : "failed",
                       error.process_evidence.dig(0, "outcome")
        end

        pid = Integer(File.binread(pid_path), 10)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        while process_alive?(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          sleep 0.02
        end
        refute process_alive?(pid), "#{behavior} detached process survived verified teardown"
      end
    end
  end

  private

  def sandbox_fixture(root)
    controller = File.join(root, "controller")
    project = File.join(root, "project")
    run_root = File.join(root, "run")
    [ controller, project, run_root ].each { |path| FileUtils.mkdir_p(path, mode: 0o700) }
    FileUtils.mkdir_p(File.join(controller, "test/e2e/fixtures/patrol_qualification"))
    FileUtils.mkdir_p(File.join(controller, "test/e2e/lib"))
    FileUtils.mkdir_p(File.join(controller, "lib/hive"))
    catalog = File.join(controller, "test/e2e/fixtures/patrol_qualification/catalog.json")
    File.binwrite(catalog, "{}\n")
    File.binwrite(File.join(controller, "test/e2e/lib/patrol_qualification.rb"), "# trusted controller\n")
    File.binwrite(File.join(controller, "lib/hive/secret_patterns.rb"), "# trusted support\n")
    observations = File.join(root, "observations.json")
    File.binwrite(observations, "{}\n")
    archive = File.join(root, "candidate.tar")
    File.binwrite(archive, "candidate")
    source = File.join(root, "candidate-source")
    FileUtils.mkdir_p(source)
    File.binwrite(File.join(source, "tracked"), "candidate")
    File.chmod(0o444, File.join(source, "tracked"))
    File.chmod(0o555, source)
    image = "ruby@sha256:#{digest('image')}"
    {
      controller:, project:, run_root:, observations:, image:,
      candidate: {
        "controller_sha" => "a" * 40, "candidate_sha" => "b" * 40, "archive_path" => archive,
        "source_path" => source, "source_tree_sha256" => digest("source"),
        "archive_sha256" => Digest::SHA256.file(archive).hexdigest,
        "module_manifest_sha256" => digest("manifests")
      }
    }
  end

  def engine_identity(image)
    { "engine" => "docker", "engine_path" => "/usr/bin/docker", "engine_sha256" => digest("engine"),
      "engine_version" => "Docker 28.0",
      "image" => image, "image_id" => "sha256:#{digest('rootfs')}" }
  end

  def hostile_engine(root, owner_label:, payload:, behavior:)
    path = File.join(root, "docker")
    pid_path = File.join(root, "detached.pid")
    state_path = File.join(root, "container.state")
    script = <<~RUBY
      #!/usr/bin/ruby
      behavior = #{behavior.dump}
      owner_label = #{owner_label.dump}
      payload = #{payload.dump}
      pid_path = #{pid_path.dump}
      state_path = #{state_path.dump}
      command = ARGV.fetch(0, "")
      exit 0 if command == "info"
      if command == "run"
        cidfile = ARGV.find { |arg| arg.start_with?("--cidfile=") }.split("=", 2).last
        File.binwrite(cidfile, "f" * 64 + "\n")
        child = Process.spawn("/usr/bin/setsid", "/bin/sh", "-c", "trap '' HUP; sleep 60",
                              in: :close, out: File::NULL, err: File::NULL)
        File.binwrite(pid_path, child.to_s)
        File.binwrite(state_path, child.to_s)
        case behavior
        when "success" then STDOUT.write(payload)
        when "failure" then exit 7
        when "timeout" then sleep 30
        end
        exit 0
      end
      if %w[kill rm].include?(command)
        if File.exist?(state_path)
          pid = Integer(File.binread(state_path), 10)
          begin Process.kill("TERM", -pid); rescue Errno::ESRCH; end
          sleep 0.05
          begin Process.kill("KILL", -pid); rescue Errno::ESRCH; end
          File.unlink(state_path) rescue nil
        end
        exit 0
      end
      if command == "container" && ARGV.fetch(1, "") == "inspect"
        alive = File.exist?(state_path)
        STDOUT.write("#{owner_label}\n") if alive && ARGV.include?("--format")
        exit(alive ? 0 : 1)
      end
      exit 1
    RUBY
    File.binwrite(path, script)
    File.chmod(0o700, path)
    [ path, pid_path ]
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def sandbox_payload(fixture)
    {
      "payload" => { "receipts" => [] },
      "candidate" => { "candidate_sha" => "b" * 40,
        "archive_sha256" => fixture.dig(:candidate, "archive_sha256"),
        "identity_before" => {}, "identity_after" => {} },
      "process_evidence" => [ {
        "owner" => "sandbox", "status" => "reaped", "outcome" => "success",
        "teardown" => "verified", "exit_code" => 0,
        "container_id_sha256" => digest("container"), "stdout_sha256" => digest("stdout"),
        "stderr_sha256" => digest("stderr")
      } ]
    }
  end

  def digest(value) = Digest::SHA256.hexdigest(value)
end
