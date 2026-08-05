require "test_helper"
require "digest"
require "json"
require "shellwords"
require "yaml"
require_relative "../../../packaging/patrol_evidence/runner"
require_relative "../../../packaging/patrol_evidence/sandbox"

class PatrolEvidenceRunnerTest < Minitest::Test
  include HiveTestHelper

  Runner = HivePatrolEvidence::Runner
  Result = HivePatrolEvidence::Result
  ROOT = File.expand_path("../../..", __dir__)
  NOW = Time.utc(2026, 8, 5, 10, 0, 0)

  def test_closed_private_composition_publishes_one_mode_safe_terminal_result
    with_controller_repository do |fixture|
      calls = []
      outcome = run_test!(
        fixture, invocation_id: "manual-1", candidate_factory: ->(**) { fake_candidate(calls) },
        sandbox_factory: ->(**) { fake_sandbox(calls) },
        controller_factory: ->(**) { fake_controller(calls) },
        provider_probe_factory: ->(**) { fake_provider(calls) }
      )

      assert_equal %i[candidate sandbox external_smoke provider], calls
      assert_equal "installed_live_smoke_verified", outcome.fetch("status")
      result_path = outcome.fetch("result_path")
      assert_equal 0o600, File.stat(result_path).mode & 0o777
      assert_equal 0o700, File.stat(File.dirname(result_path)).mode & 0o777
      assert_equal [ "result.json" ], Dir.children(File.dirname(result_path))
      assert_equal outcome.fetch("result").canonical_bytes, File.binread(result_path)
      assert_equal Result::CLAIM_FENCES, JSON.parse(File.binread(result_path)).fetch("claim_fences")
    end
  end

  def test_public_run_interface_rejects_dependency_factories
    error = assert_raises(ArgumentError) do
      Runner.run!(candidate_factory: -> { flunk "factory must not be reachable" })
    end

    assert_match(/missing keyword|unknown keyword/, error.message)
  end

  def test_authority_and_store_checks_happen_before_candidate_or_credential_access
    with_controller_repository do |fixture|
      authorization = authorization_for(fixture, "manual-2")
      File.write(File.join(fixture.fetch(:repo), "dirty"), "dirty")
      touched = false

      error = assert_raises(Runner::AuthorityError) do
        run_test!(
          fixture, invocation_id: "manual-2", authorization:,
          candidate_factory: ->(**) { touched = true },
          provider_probe_factory: ->(**) { touched = true }
        )
      end

      assert_equal "controller_checkout_dirty", error.reason
      refute touched
      assert_empty Dir.children(fixture.fetch(:evidence))
    end
  end

  def test_expected_byte_publication_detects_a_competing_writer
    with_controller_repository do |fixture|
      candidate = fake_candidate([])
      prepared = prepared_candidate
      candidate.define_singleton_method(:prepare!) do |**|
        result_path = Dir.glob(File.join(fixture.fetch(:evidence), "*", "result.json")).fetch(0)
        File.binwrite(result_path, "competing bytes\n")
        prepared
      end

      error = assert_raises(Runner::PublicationError) do
        run_test!(
          fixture, invocation_id: "manual-3", candidate_factory: ->(**) { candidate },
          sandbox_factory: ->(**) { fake_sandbox([]) },
          controller_factory: ->(**) { fake_controller([]) },
          provider_probe_factory: ->(**) { fake_provider([]) }
        )
      end

      assert_equal "publication_conflict", error.reason
      result = Dir.glob(File.join(fixture.fetch(:evidence), "*", "result.json")).fetch(0)
      assert_equal "competing bytes\n", File.binread(result)
    end
  end

  def test_authorization_is_exact_scope_expiring_and_one_time
    with_controller_repository do |fixture|
      invocation = "manual-replay"
      authorization = authorization_for(fixture, invocation)
      factories = {
        candidate_factory: ->(**) { fake_candidate([]) },
        sandbox_factory: ->(**) { fake_sandbox([]) },
        controller_factory: ->(**) { fake_controller([]) },
        provider_probe_factory: ->(**) { fake_provider([]) }
      }

      assert_equal "installed_live_smoke_verified",
                   run_test!(fixture, invocation_id: invocation, authorization:, **factories).fetch("status")
      replay = assert_raises(Runner::AuthorityError) do
        run_test!(fixture, invocation_id: invocation, authorization:, **factories)
      end
      assert_equal "manual_authority_missing", replay.reason

      expired = JSON.parse(authorization).merge(
        "nonce" => "expired", "issued_at" => "2026-08-05T08:00:00.000000Z",
        "expires_at" => "2026-08-05T08:15:00.000000Z"
      )
      error = assert_raises(Runner::AuthorityError) do
        run_test!(
          fixture, invocation_id: "manual-expired", authorization: Result.canonical(expired), **factories
        )
      end
      assert_equal "manual_authority_missing", error.reason
    end
  end

  def test_project_drift_blocks_before_provider_access
    with_controller_repository do |fixture|
      touched = false
      controller = fake_controller([])
      smoke = smoke_record
      controller.define_singleton_method(:external_smoke) do |**|
        File.open(File.join(fixture.fetch(:project), ".hive-state", "config.yml"), "ab") { |file| file.write("# drift\n") }
        smoke
      end

      outcome = run_test!(
        fixture, invocation_id: "manual-project-drift",
        candidate_factory: ->(**) { fake_candidate([]) },
        sandbox_factory: ->(**) { fake_sandbox([]) }, controller_factory: ->(**) { controller },
        provider_probe_factory: ->(**) { touched = true }
      )

      assert_equal "failed", outcome.fetch("status")
      assert_equal "authority_binding", outcome.fetch("reason")
      refute touched
    end
  end

  def test_cleanup_is_explicit_owner_checked_retention_bounded_and_non_destructive
    with_controller_repository do |fixture|
      outcome = run_test!(
        fixture, invocation_id: "manual-cleanup",
        candidate_factory: ->(**) { fake_candidate([]) },
        sandbox_factory: ->(**) { fake_sandbox([]) },
        controller_factory: ->(**) { fake_controller([]) },
        provider_probe_factory: ->(**) { fake_provider([]) }
      )
      path = outcome.fetch("result_path")

      assert_raises(Runner::EvidenceError) do
        Runner.cleanup!(evidence_root: fixture.fetch(:evidence), result_path: path, now: Time.utc(2026, 8, 6))
      end
      old = Time.utc(2026, 8, 5)
      File.utime(old, old, path)
      extra = File.join(File.dirname(path), "candidate.tar")
      File.binwrite(extra, "must survive")
      assert_raises(Runner::EvidenceError) do
        Runner.cleanup!(evidence_root: fixture.fetch(:evidence), result_path: path, now: Time.utc(2026, 9, 6))
      end
      assert File.exist?(path), "cleanup must preserve evidence when the directory is contaminated"
      File.unlink(extra)
      assert Runner.cleanup!(
        evidence_root: fixture.fetch(:evidence), result_path: path, now: Time.utc(2026, 9, 6)
      )
      refute File.exist?(path)
      refute File.exist?(File.dirname(path))
    end
  end

  def test_full_store_returns_typed_blocked_without_touching_candidate_or_provider
    with_controller_repository do |fixture|
      128.times do |index|
        directory = File.join(fixture.fetch(:evidence), "u3c-existing-#{index}")
        Dir.mkdir(directory, 0o700)
        path = File.join(directory, "result.json")
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write("{}\n") }
      end
      touched = false

      outcome = run_test!(
        fixture, invocation_id: "manual-full-store",
        candidate_factory: ->(**) { touched = true },
        provider_probe_factory: ->(**) { touched = true }
      )

      assert_equal "blocked", outcome.fetch("status")
      assert_equal "evidence_store_full", outcome.fetch("reason")
      assert_nil outcome.fetch("result_path")
      refute touched
      assert_equal 128, Dir.children(fixture.fetch(:evidence)).size
    end
  end

  def test_provider_block_preserves_completed_candidate_sandbox_and_process_custody
    with_controller_repository do |fixture|
      provider = Object.new
      provider.define_singleton_method(:call) do
        error = StandardError.new("provider unavailable")
        error.define_singleton_method(:reason) { "provider_unavailable" }
        raise error
      end

      outcome = run_test!(
        fixture, invocation_id: "manual-provider-block",
        candidate_factory: ->(**) { fake_candidate([]) },
        sandbox_factory: ->(**) { fake_sandbox([]) },
        controller_factory: ->(**) { fake_controller([]) },
        provider_probe_factory: ->(**) { provider }
      )

      result = outcome.fetch("result").to_h
      assert_equal "blocked", outcome.fetch("status")
      assert_equal "provider_unavailable", outcome.fetch("reason")
      assert_equal "verified", result.dig("candidate", "status")
      assert_equal "passed", result.dig("sandbox", "status")
      assert_equal "passed", result.dig("smoke", "status")
      assert_nil result.fetch("provider")
      assert_equal "reaped", result.dig("process_evidence", 0, "status")
    end
  end

  def test_sandbox_failure_retains_prepared_candidate_and_teardown_evidence
    with_controller_repository do |fixture|
      evidence = process_record.merge("outcome" => "failed", "exit_code" => 7)
      sandbox = Object.new
      sandbox.define_singleton_method(:run!) do |**|
        raise HivePatrolEvidence::Sandbox::Error.new(
          "sandbox_contract", "candidate failed", process_evidence: [ evidence ]
        )
      end

      outcome = run_test!(
        fixture, invocation_id: "manual-sandbox-failure",
        candidate_factory: ->(**) { fake_candidate([]) },
        sandbox_factory: ->(**) { sandbox },
        controller_factory: ->(**) { flunk "controller must not run" },
        provider_probe_factory: ->(**) { flunk "provider must not run" }
      )

      result = outcome.fetch("result").to_h
      assert_equal "failed", outcome.fetch("status")
      assert_equal "sandbox_contract", outcome.fetch("reason")
      assert_equal "prepared", result.dig("candidate", "status")
      assert_equal evidence, result.fetch("process_evidence").fetch(0)
    end
  end

  private

  def run_test!(fixture, invocation_id:, authorization: nil, **factories)
    authorization ||= authorization_for(fixture, invocation_id)
    Runner.send(
      :new, **runner_options(fixture, invocation_id:, authorization:), **factories,
      clock: fixed_clock
    ).send(:run)
  end

  def runner_options(fixture, invocation_id:, authorization:)
    {
      repo_root: fixture.fetch(:repo), evidence_root: fixture.fetch(:evidence),
      hive_home: fixture.fetch(:hive_home), controller_sha: fixture.fetch(:controller_sha),
      candidate_sha: fixture.fetch(:candidate_sha), authorization:, invocation_id:,
      project_root: fixture.fetch(:project), observations_path: fixture.fetch(:observations),
      image: fixture.fetch(:image)
    }
  end

  def authorization_for(fixture, invocation_id)
    Runner.authorization_template!(
      **runner_options(fixture, invocation_id:, authorization: "").except(:authorization),
      now: NOW, nonce: "nonce-#{invocation_id}"
    )
  end

  def fake_candidate(calls)
    prepared = prepared_candidate
    verified = verified_candidate
    Object.new.tap do |object|
      object.define_singleton_method(:prepare!) do |**|
        calls << :candidate
        prepared
      end
      object.define_singleton_method(:verify!) { |receipt:| receipt.fetch("candidate") && verified }
    end
  end

  def fake_sandbox(calls)
    candidate = verified_candidate
    sandbox = sandbox_record
    process = process_record
    Object.new.tap do |object|
      object.define_singleton_method(:run!) do |**|
        calls << :sandbox
        {
          "candidate" => candidate,
          "sandbox" => sandbox,
          "payload" => { "receipts" => [] },
          "process_evidence" => [ process ]
        }
      end
    end
  end

  def fake_controller(calls)
    smoke = smoke_record
    Object.new.tap do |object|
      object.define_singleton_method(:external_smoke) do |**|
        calls << :external_smoke
        smoke
      end
    end
  end

  def fake_provider(calls)
    provider = provider_record
    Object.new.tap do |object|
      object.define_singleton_method(:call) do
        calls << :provider
        provider
      end
      object.define_singleton_method(:validate_retained!) { |_| true }
    end
  end

  def with_controller_repository
    with_tmp_dir do |root|
      repo = File.join(root, "repo")
      FileUtils.mkdir_p(repo)
      system("git", "init", "-b", "main", "--quiet", repo) or raise
      Runner::CONTROL_PATHS.each do |relative|
        target = File.join(repo, relative)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(File.join(ROOT, relative), target)
      end
      File.write(File.join(repo, "tracked"), "controller\n")
      git_commit_all(repo, "controller")
      controller_sha = git(repo, "rev-parse", "HEAD")
      File.write(File.join(repo, "tracked"), "candidate\n")
      git_commit_all(repo, "candidate")
      candidate_sha = git(repo, "rev-parse", "HEAD")
      system("git", "-C", repo, "remote", "add", "origin", "https://github.com/ivankuznetsov/hive.git") or raise
      system("git", "-C", repo, "update-ref", "refs/remotes/origin/main", candidate_sha) or raise
      system("git", "-C", repo, "checkout", "--detach", "--quiet", controller_sha) or raise

      project = File.join(root, "project")
      project_remote = File.join(root, "project-origin.git")
      system("git", "init", "--bare", "--quiet", project_remote) or raise
      system("git", "init", "-b", "main", "--quiet", project) or raise
      File.write(File.join(project, "README.md"), "disposable project\n")
      git_commit_all(project, "project")
      system("git", "-C", project, "remote", "add", "origin", project_remote) or raise
      state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(File.join(state, "module-runtime", "migration"))
      File.binwrite(File.join(state, "config.yml"), { "hive_state_path" => ".hive-state" }.to_yaml)
      File.binwrite(File.join(state, "module-runtime", "migration", "report.json"), "{}\n")

      hive_home = File.join(root, "hive-home")
      evidence = File.join(root, "evidence")
      FileUtils.mkdir_p(hive_home, mode: 0o700)
      FileUtils.mkdir_p(evidence, mode: 0o700)
      registration = {
        "name" => "disposable", "path" => project, "real_path" => File.realpath(project),
        "hive_state_path" => state, "project_id" => "11111111-1111-4111-8111-111111111111",
        "registration_id" => "22222222-2222-4222-8222-222222222222",
        "registered_at" => "2026-08-05T09:00:00.000000Z",
        "repository_identity" => "local:#{File.realpath(project_remote)}"
      }
      File.binwrite(File.join(hive_home, "config.yml"), { "registered_projects" => [ registration ] }.to_yaml)
      observations = File.join(root, "observations.json")
      File.binwrite(observations, "{}\n")
      image = "ruby@sha256:#{digest('image')}"
      yield repo:, evidence:, hive_home:, project:, observations:, image:, controller_sha:, candidate_sha:
    ensure
      FileUtils.chmod_R(0o700, root) if root && File.exist?(root)
    end
  end

  def git_commit_all(repo, message)
    system("git", "-C", repo, "-c", "user.name=Hive", "-c", "user.email=hive@example.invalid",
           "add", ".") or raise
    system("git", "-C", repo, "-c", "user.name=Hive", "-c", "user.email=hive@example.invalid",
           "commit", "-m", message, "--quiet") or raise
  end

  def git(repo, *arguments)
    output = `git -C #{Shellwords.escape(repo)} #{arguments.map { |arg| Shellwords.escape(arg) }.join(" ")}`
    raise unless $?.success?

    output.strip
  end

  def fixed_clock
    times = [ NOW, NOW + 1, NOW + 2, NOW + 3, NOW + 4 ]
    -> { times.shift || times.last }
  end

  def digest(value) = Digest::SHA256.hexdigest(value)

  class << self
    def prepared_candidate
      {
        "candidate_sha" => "b" * 40, "archive_sha256" => Digest::SHA256.hexdigest("archive"),
        "archive_member_count" => 10, "archive_total_bytes" => 100,
        "module_manifest_sha256" => Digest::SHA256.hexdigest("manifests"),
        "source_tree_sha256" => Digest::SHA256.hexdigest("source"),
        "archive_path" => "/transient/candidate.tar", "source_path" => "/transient/source"
      }
    end

    def verified_candidate
      prepared_candidate.except("archive_path", "source_path").merge(
        "gem_sha256" => Digest::SHA256.hexdigest("gem"),
        "installed_hive_sha256" => Digest::SHA256.hexdigest("hive"),
        "dependency_closure_sha256" => Digest::SHA256.hexdigest("closure"),
        "toolchain_sha256" => Digest::SHA256.hexdigest("toolchain")
      )
    end

    def sandbox_record
      {
        "status" => "passed", "engine" => "docker", "engine_version" => "Docker 28.0",
        "engine_sha256" => Digest::SHA256.hexdigest("engine"),
        "image" => "ruby@sha256:#{Digest::SHA256.hexdigest('image')}",
        "image_id" => "sha256:#{Digest::SHA256.hexdigest('rootfs')}", "network" => "none",
        "root_filesystem" => "read_only", "writable_bytes" => 536_870_912,
        "writable_inodes" => 16_384, "process_limit" => 64, "memory" => "2g", "cpus" => "2"
      }
    end

    def smoke_record
      {
        "status" => "passed", "modules" => %w[architecture-patrol patrol], "receipt_count" => 4,
        "catalog_digest" => Digest::SHA256.hexdigest("catalog"),
        "scenario_manifest_digest" => Digest::SHA256.hexdigest("scenario"),
        "report_sha256" => Digest::SHA256.hexdigest("report")
      }
    end

    def provider_record
      {
        "status" => "passed", "provider" => "openrouter", "model" => "openai/gpt-5.6-terra",
        "response_sha256" => Digest::SHA256.hexdigest("response"),
        "usage" => { "prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2 }
      }
    end

    def process_record
      {
        "owner" => "sandbox", "status" => "reaped", "outcome" => "success",
        "teardown" => "verified", "exit_code" => 0,
        "container_id_sha256" => Digest::SHA256.hexdigest("container"),
        "stdout_sha256" => Digest::SHA256.hexdigest("stdout"),
        "stderr_sha256" => Digest::SHA256.hexdigest("stderr")
      }
    end
  end

  def prepared_candidate = self.class.prepared_candidate
  def verified_candidate = self.class.verified_candidate
  def sandbox_record = self.class.sandbox_record
  def smoke_record = self.class.smoke_record
  def provider_record = self.class.provider_record
  def process_record = self.class.process_record
end
