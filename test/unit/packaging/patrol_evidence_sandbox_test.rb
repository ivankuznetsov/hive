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
      assert argv.grep(/\A--tmpfs=/).any? { |value| value.include?("size=536870912") && value.include?("nr_inodes=16384") }
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
    image = "ruby@sha256:#{digest('image')}"
    {
      controller:, project:, run_root:, observations:, image:,
      candidate: {
        "controller_sha" => "a" * 40, "candidate_sha" => "b" * 40, "archive_path" => archive,
        "archive_sha256" => Digest::SHA256.file(archive).hexdigest,
        "module_manifest_sha256" => digest("manifests")
      }
    }
  end

  def engine_identity(image)
    { "engine" => "docker", "engine_version" => "Docker 28.0",
      "image" => image, "image_id" => "sha256:#{digest('rootfs')}" }
  end

  def sandbox_payload(fixture)
    {
      "payload" => { "receipts" => [] },
      "candidate" => { "candidate_sha" => "b" * 40,
        "archive_sha256" => fixture.dig(:candidate, "archive_sha256"),
        "identity_before" => {}, "identity_after" => {} },
      "process_evidence" => [ { "owner" => "sandbox", "status" => "reaped",
                                 "container_id_sha256" => digest("container") } ]
    }
  end

  def digest(value) = Digest::SHA256.hexdigest(value)
end
