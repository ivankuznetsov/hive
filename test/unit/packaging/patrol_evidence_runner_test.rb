require "test_helper"
require "digest"
require "json"
require_relative "../../../packaging/patrol_evidence/runner"

class PatrolEvidenceRunnerTest < Minitest::Test
  include HiveTestHelper

  Runner = HivePatrolEvidence::Runner
  Result = HivePatrolEvidence::Result

  def test_closed_composition_publishes_one_mode_safe_terminal_result
    with_controller_repository do |fixture|
      calls = []
      candidate = fake_candidate(calls)
      sandbox = fake_sandbox(calls)
      controller = fake_controller(calls)
      provider = fake_provider(calls)

      outcome = Runner.run!(
        repo_root: fixture.fetch(:repo), evidence_root: fixture.fetch(:evidence),
        controller_sha: fixture.fetch(:controller_sha), candidate_sha: fixture.fetch(:candidate_sha),
        authorization: "one exact authorized invocation", invocation_id: "manual-1",
        project_root: fixture.fetch(:project), observations_path: fixture.fetch(:observations),
        image: "ruby@sha256:#{digest('image')}",
        candidate_factory: ->(**) { candidate }, sandbox_factory: ->(**) { sandbox },
        controller_factory: ->(**) { controller }, provider_probe_factory: ->(**) { provider },
        clock: fixed_clock
      )

      assert_equal %i[candidate sandbox external_smoke provider], calls
      assert_equal "installed_live_smoke_verified", outcome.fetch("status")
      result_path = outcome.fetch("result_path")
      assert_equal 0o600, File.stat(result_path).mode & 0o777
      assert_equal 0o700, File.stat(File.dirname(result_path)).mode & 0o777
      assert_equal outcome.fetch("result").canonical_bytes, File.binread(result_path)
      assert_equal Result::CLAIM_FENCES, JSON.parse(File.binread(result_path)).fetch("claim_fences")
    end
  end

  def test_authority_and_store_checks_happen_before_candidate_or_credential_access
    with_controller_repository do |fixture|
      File.write(File.join(fixture.fetch(:repo), "dirty"), "dirty")
      touched = false

      error = assert_raises(Runner::AuthorityError) do
        Runner.run!(
          repo_root: fixture.fetch(:repo), evidence_root: fixture.fetch(:evidence),
          controller_sha: fixture.fetch(:controller_sha), candidate_sha: fixture.fetch(:candidate_sha),
          authorization: "authorized", invocation_id: "manual-2",
          project_root: fixture.fetch(:project), observations_path: fixture.fetch(:observations),
          image: "ruby@sha256:#{digest('image')}",
          candidate_factory: ->(**) { touched = true },
          provider_probe_factory: ->(**) { touched = true }, clock: fixed_clock
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
      candidate.define_singleton_method(:prepare!) do |run_root:, **|
        File.binwrite(File.join(run_root, "result.json"), "competing bytes\n")
        { "archive_sha256" => Digest::SHA256.hexdigest("archive"),
          "closure_sha256" => Digest::SHA256.hexdigest("closure") }
      end

      error = assert_raises(Runner::PublicationError) do
        Runner.run!(
          repo_root: fixture.fetch(:repo), evidence_root: fixture.fetch(:evidence),
          controller_sha: fixture.fetch(:controller_sha), candidate_sha: fixture.fetch(:candidate_sha),
          authorization: "authorized", invocation_id: "manual-3",
          project_root: fixture.fetch(:project), observations_path: fixture.fetch(:observations),
          image: "ruby@sha256:#{digest('image')}", candidate_factory: ->(**) { candidate },
          sandbox_factory: ->(**) { fake_sandbox([]) },
          controller_factory: ->(**) { fake_controller([]) },
          provider_probe_factory: ->(**) { fake_provider([]) }, clock: fixed_clock
        )
      end

      assert_equal "publication_conflict", error.reason
      result = Dir.glob(File.join(fixture.fetch(:evidence), "*", "result.json")).fetch(0)
      assert_equal "competing bytes\n", File.binread(result)
    end
  end

  def test_cleanup_is_explicit_owner_checked_and_retention_bounded
    with_controller_repository do |fixture|
      outcome = Runner.run!(
        repo_root: fixture.fetch(:repo), evidence_root: fixture.fetch(:evidence),
        controller_sha: fixture.fetch(:controller_sha), candidate_sha: fixture.fetch(:candidate_sha),
        authorization: "authorized", invocation_id: "manual-cleanup",
        project_root: fixture.fetch(:project), observations_path: fixture.fetch(:observations),
        image: "ruby@sha256:#{digest('image')}",
        candidate_factory: ->(**) { fake_candidate([]) },
        sandbox_factory: ->(**) { fake_sandbox([]) },
        controller_factory: ->(**) { fake_controller([]) },
        provider_probe_factory: ->(**) { fake_provider([]) }, clock: fixed_clock
      )
      path = outcome.fetch("result_path")

      assert_raises(Runner::EvidenceError) do
        Runner.cleanup!(
          evidence_root: fixture.fetch(:evidence), result_path: path,
          now: Time.utc(2026, 8, 6)
        )
      end
      old = Time.utc(2026, 8, 5)
      File.utime(old, old, path)
      assert Runner.cleanup!(
        evidence_root: fixture.fetch(:evidence), result_path: path,
        now: Time.utc(2026, 9, 6)
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

      outcome = Runner.run!(
        repo_root: fixture.fetch(:repo), evidence_root: fixture.fetch(:evidence),
        controller_sha: fixture.fetch(:controller_sha), candidate_sha: fixture.fetch(:candidate_sha),
        authorization: "authorized", invocation_id: "manual-full-store",
        project_root: fixture.fetch(:project), observations_path: fixture.fetch(:observations),
        image: "ruby@sha256:#{digest('image')}",
        candidate_factory: ->(**) { touched = true },
        provider_probe_factory: ->(**) { touched = true }, clock: fixed_clock
      )

      assert_equal "blocked", outcome.fetch("status")
      assert_equal "evidence_store_full", outcome.fetch("reason")
      assert_nil outcome.fetch("result_path")
      refute touched
      assert_equal 128, Dir.children(fixture.fetch(:evidence)).size
    end
  end

  def test_provider_block_preserves_completed_candidate_and_sandbox_custody
    with_controller_repository do |fixture|
      provider = Object.new
      provider.define_singleton_method(:call) do
        error = StandardError.new("provider unavailable")
        error.define_singleton_method(:reason) { "provider_unavailable" }
        raise error
      end

      outcome = Runner.run!(
        repo_root: fixture.fetch(:repo), evidence_root: fixture.fetch(:evidence),
        controller_sha: fixture.fetch(:controller_sha), candidate_sha: fixture.fetch(:candidate_sha),
        authorization: "authorized", invocation_id: "manual-provider-block",
        project_root: fixture.fetch(:project), observations_path: fixture.fetch(:observations),
        image: "ruby@sha256:#{digest('image')}",
        candidate_factory: ->(**) { fake_candidate([]) },
        sandbox_factory: ->(**) { fake_sandbox([]) },
        controller_factory: ->(**) { fake_controller([]) },
        provider_probe_factory: ->(**) { provider }, clock: fixed_clock
      )

      result = outcome.fetch("result").to_h
      assert_equal "blocked", outcome.fetch("status")
      assert_equal "provider_unavailable", outcome.fetch("reason")
      refute_nil result.fetch("candidate")
      refute_nil result.fetch("sandbox")
      refute_nil result.fetch("smoke")
      assert_nil result.fetch("provider")
      assert_equal "reaped", result.dig("process_evidence", 0, "status")
    end
  end

  private

  def fake_candidate(calls)
    Object.new.tap do |object|
      object.define_singleton_method(:prepare!) do |**|
        calls << :candidate
        { "archive_sha256" => Digest::SHA256.hexdigest("archive"),
          "closure_sha256" => Digest::SHA256.hexdigest("closure") }
      end
      object.define_singleton_method(:verify!) { |receipt:| receipt.fetch("candidate") }
    end
  end

  def fake_sandbox(calls)
    Object.new.tap do |object|
      object.define_singleton_method(:run!) do |**|
        calls << :sandbox
        { "candidate" => { "archive_sha256" => Digest::SHA256.hexdigest("archive"),
                            "closure_sha256" => Digest::SHA256.hexdigest("closure") },
          "sandbox" => { "status" => "passed", "image" => "ruby@sha256:#{Digest::SHA256.hexdigest('image')}" },
          "payload" => { "receipts" => [] },
          "process_evidence" => [ { "owner" => "sandbox", "status" => "reaped" } ] }
      end
    end
  end

  def fake_controller(calls)
    Object.new.tap do |object|
      object.define_singleton_method(:external_smoke) do |**|
        calls << :external_smoke
        { "status" => "passed", "modules" => %w[architecture-patrol patrol] }
      end
    end
  end

  def fake_provider(calls)
    Object.new.tap do |object|
      object.define_singleton_method(:call) do
        calls << :provider
        { "status" => "passed", "provider" => "openrouter",
          "model" => "openai/gpt-5.6-terra", "response_sha256" => Digest::SHA256.hexdigest("response"),
          "usage" => { "prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2 } }
      end
      object.define_singleton_method(:credential) { "operator-secret" }
    end
  end

  def with_controller_repository
    with_tmp_dir do |root|
      repo = File.join(root, "repo")
      FileUtils.mkdir_p(repo)
      system("git", "init", "-b", "main", "--quiet", repo) or raise
      FileUtils.mkdir_p(File.join(repo, "test/e2e/lib"))
      File.write(File.join(repo, "test/e2e/lib/patrol_qualification.rb"), "# controller\n")
      File.write(File.join(repo, "tracked"), "controller\n")
      system("git", "-C", repo, "-c", "user.name=Hive", "-c", "user.email=hive@example.invalid",
             "add", ".") or raise
      system("git", "-C", repo, "-c", "user.name=Hive", "-c", "user.email=hive@example.invalid",
             "commit", "-m", "controller", "--quiet") or raise
      controller_sha = `git -C #{Shellwords.escape(repo)} rev-parse HEAD`.strip
      File.write(File.join(repo, "tracked"), "candidate\n")
      system("git", "-C", repo, "-c", "user.name=Hive", "-c", "user.email=hive@example.invalid",
             "commit", "-am", "candidate", "--quiet") or raise
      candidate_sha = `git -C #{Shellwords.escape(repo)} rev-parse HEAD`.strip
      system("git", "-C", repo, "checkout", "--detach", "--quiet", controller_sha) or raise
      evidence = File.join(root, "evidence")
      project = File.join(root, "project")
      FileUtils.mkdir_p(evidence, mode: 0o700)
      FileUtils.mkdir_p(project, mode: 0o700)
      observations = File.join(root, "observations.json")
      File.binwrite(observations, "{}\n")
      yield repo:, evidence:, project:, observations:, controller_sha:, candidate_sha:
    end
  end

  def fixed_clock
    times = [
      Time.utc(2026, 8, 5, 10, 0, 0), Time.utc(2026, 8, 5, 10, 0, 1),
      Time.utc(2026, 8, 5, 10, 0, 2), Time.utc(2026, 8, 5, 10, 0, 3)
    ]
    -> { times.shift || times.last }
  end

  def digest(value) = Digest::SHA256.hexdigest(value)
end
