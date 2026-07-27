# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "json"
require "open3"
require "rubygems/package"
require "rbconfig"
require "tmpdir"
require "zlib"
require_relative "../../../packaging/release_candidate/release_selector"

class ReleaseCandidateReleaseSelectorTest < Minitest::Test
  CANDIDATE_SHA = "a" * 40
  WORKFLOW_SHA = "b" * 40
  ACTION_LOCK = "c" * 64
  EVIDENCE_SHA = "d" * 64
  ARTIFACT_DIGEST = "sha256:#{'e' * 64}"
  EVIDENCE_ARTIFACT_DIGEST = "sha256:#{'f' * 64}"
  REPOSITORY = "ivankuznetsov/hive"
  VERSION = "0.7.0"
  WRAPPER = File.expand_path(
    "../../../packaging/release_candidate/select_release_candidate.rb", __dir__
  )

  def test_selects_exact_terminal_candidate_evidence
    fixture = fixture()
    result = selector(fixture).select

    assert_equal CANDIDATE_SHA, result.fetch("candidate_sha")
    assert_equal WORKFLOW_SHA, result.fetch("workflow_revision")
    assert_equal "req-release1", result.fetch("request_id")
    assert_equal 42, result.fetch("evidence_run_id")
    assert_equal 2, result.fetch("evidence_run_attempt")
    assert_equal 81, result.fetch("evidence_artifact_id")
    assert_equal EVIDENCE_ARTIFACT_DIGEST, result.fetch("evidence_artifact_digest")
    assert_equal EVIDENCE_SHA, result.fetch("evidence_sha256")
  end

  def test_cli_wrapper_exposes_pure_check_selection
    Dir.mktmpdir("release-selector-cli") do |dir|
      checks = File.join(dir, "checks.json")
      File.write(checks, JSON.generate(fixture.fetch(:checks)))
      out, err, status = Open3.capture3(
        RbConfig.ruby, WRAPPER, "check", CANDIDATE_SHA, REPOSITORY, VERSION,
        checks
      )

      assert status.success?, err
      result = JSON.parse(out)
      assert_equal 42, result.fetch("evidence_run_id")
      assert_equal EVIDENCE_SHA, result.fetch("evidence_sha256")
    end
  end

  def test_verifies_trusted_evidence_artifact_producer_and_ordinary_ci
    fixture = fixture()
    selected = selector(fixture).select
    result = selector(fixture).verify(
      selection: selected,
      evidence: fixture.fetch(:evidence),
      producer_run: fixture.fetch(:producer_run),
      producer_artifact: fixture.fetch(:producer_artifact),
      ordinary_ci_run: fixture.fetch(:ordinary_run),
      expected_action_lock_sha256: ACTION_LOCK
    )

    assert_equal 77, result.fetch("candidate_artifact_id")
    assert_equal ARTIFACT_DIGEST, result.fetch("candidate_artifact_digest")
    assert_equal 11, result.dig("ordinary_ci", "run_id")
  end

  def test_accepts_chained_retry_evidence_without_rebinding_original_artifact
    fixture = fixture()
    replacement = HiveReleaseCandidate::Aggregate::REQUIRED_JOBS.fetch(0)
    fixture[:evidence]["provenance"] = {
      "run_id" => 42, "run_attempt" => 2,
      "source_run_id" => 41, "source_run_attempt" => 1,
      "source_request_id" => "req-parent01",
      "source_evidence_sha256" => "9" * 64,
      "selector" => { "mode" => "named", "gates" => [ replacement ] },
      "replacement_gates" => [ replacement ]
    }
    fixture[:evidence]["effective_gate_set"].each do |row|
      next if row["name"] == replacement

      row["run_id"] = 39
      row["run_attempt"] = 3
    end
    selected = selector(fixture).select
    result = selector(fixture).verify(
      selection: selected, evidence: fixture.fetch(:evidence),
      producer_run: fixture.fetch(:producer_run),
      producer_artifact: fixture.fetch(:producer_artifact),
      ordinary_ci_run: fixture.fetch(:ordinary_run),
      expected_action_lock_sha256: ACTION_LOCK
    )

    assert_equal 40, result.fetch("candidate_artifact_producer_run_id")
    assert_equal 1, result.fetch("candidate_artifact_producer_run_attempt")
  end

  def test_selection_rejects_each_untrusted_check_run_and_evidence_artifact_identity
    mutations = {
      "repository app" => ->(f) { f.dig(:checks, "check_runs", 0, "app")["slug"] = "other" },
      "candidate SHA" => ->(f) { f.dig(:checks, "check_runs", 0)["head_sha"] = "9" * 40 },
      "check conclusion" => ->(f) { f.dig(:checks, "check_runs", 0)["conclusion"] = "failure" },
      "external ID" => ->(f) { f.dig(:checks, "check_runs", 0)["external_id"] = "invalid" },
      "details URL" => ->(f) { f.dig(:checks, "check_runs", 0)["details_url"] = "https://example.test" },
      "workflow path" => ->(f) { f[:run]["path"] = ".github/workflows/other.yml" },
      "workflow revision" => ->(f) { f[:run]["head_sha"] = "short" },
      "branch" => ->(f) { f[:run]["head_branch"] = "feature" },
      "event" => ->(f) { f[:run]["event"] = "push" },
      "run repository" => ->(f) { f.dig(:run, "head_repository")["full_name"] = "other/repo" },
      "run attempt" => ->(f) { f[:run]["run_attempt"] = 3 },
      "request ID" => ->(f) { f[:run]["display_title"] = "not-bound" },
      "required attest job" => ->(f) { f.dig(:jobs, "jobs").reject! { |row| row["name"].start_with?("Attest ") } },
      "required aggregate job" => ->(f) { f.dig(:jobs, "jobs").last["conclusion"] = "skipped" },
      "expired evidence" => ->(f) { f.dig(:artifacts, "artifacts", 0)["expired"] = true },
      "evidence digest" => ->(f) { f.dig(:artifacts, "artifacts", 0)["digest"] = "sha256:short" },
      "ambiguous evidence" => lambda do |f|
        f.dig(:artifacts, "artifacts") << f.dig(:artifacts, "artifacts", 0).dup
      end
    }

    mutations.each do |label, mutate|
      changed = fixture()
      mutate.call(changed)
      assert_raises(HiveReleaseCandidate::Error, label) { selector(changed).select }
    end
  end

  def test_verification_rejects_each_evidence_and_downstream_identity_substitution
    mutations = {
      "trust scope" => ->(f) { f[:evidence]["trust_scope"] = "local" },
      "QA status" => ->(f) { f[:evidence]["qa_status"] = "qa_blocked" },
      "action lock" => ->(f) { f[:evidence]["action_lock_sha256"] = "0" * 64 },
      "request ID" => ->(f) { f[:evidence]["request_id"] = "req-other1" },
      "gate set" => ->(f) { f[:evidence]["effective_gate_set"].shift },
      "gate run identity" => ->(f) { f.dig(:evidence, "effective_gate_set", 0)["run_id"] = 99 },
      "summary" => ->(f) { f.dig(:evidence, "summary")["passed"] -= 1 },
      "artifact ID" => ->(f) { f[:producer_artifact]["id"] = 999 },
      "artifact expiry" => ->(f) { f[:producer_artifact]["expired"] = true },
      "producer attempt" => ->(f) { f[:producer_run]["run_attempt"] = 3 },
      "producer workflow" => ->(f) { f[:producer_run]["path"] = ".github/workflows/other.yml" },
      "ordinary check" => ->(f) { f.dig(:checks, "check_runs", 1)["name"] = "other" },
      "ordinary run" => ->(f) { f[:ordinary_run]["run_attempt"] = 4 }
    }

    mutations.each do |label, mutate|
      changed = fixture()
      selected = selector(changed).select
      mutate.call(changed)
      assert_raises(HiveReleaseCandidate::Error, label) do
        selector(changed).verify(
          selection: selected,
          evidence: changed.fetch(:evidence),
          producer_run: changed.fetch(:producer_run),
          producer_artifact: changed.fetch(:producer_artifact),
          ordinary_ci_run: changed.fetch(:ordinary_run),
          expected_action_lock_sha256: ACTION_LOCK
        )
      end
    end
  end

  def test_verifies_archive_digest_and_rejects_zip_traversal
    Dir.mktmpdir("release-archive-test") do |dir|
      safe_root = File.join(dir, "safe")
      FileUtils.mkdir_p(safe_root)
      File.write(File.join(safe_root, "evidence.json"), "{}")
      safe_zip = File.join(dir, "safe.zip")
      _out, err, status = Open3.capture3("zip", "-q", safe_zip, "evidence.json", chdir: safe_root)
      assert status.success?, err
      digest = "sha256:#{Digest::SHA256.file(safe_zip).hexdigest}"
      assert_equal digest, HiveReleaseCandidate::ReleaseArchive.verify_digest!(digest, safe_zip)
      extracted = File.join(dir, "extracted")
      HiveReleaseCandidate::ReleaseArchive.extract_zip!(safe_zip, extracted)
      assert_equal "{}", File.binread(File.join(extracted, "evidence.json"))

      unsafe_zip = File.join(dir, "unsafe.zip")
      script = <<~'PYTHON'
        import sys, zipfile
        with zipfile.ZipFile(sys.argv[1], "w") as archive:
            archive.writestr("../escape", "no")
      PYTHON
      _out, err, status = Open3.capture3("python3", "-c", script, unsafe_zip)
      assert status.success?, err
      assert_raises(HiveReleaseCandidate::Error) do
        HiveReleaseCandidate::ReleaseArchive.extract_zip!(
          unsafe_zip, File.join(dir, "unsafe-extract")
        )
      end

      link_root = File.join(dir, "link")
      FileUtils.mkdir_p(link_root)
      File.symlink("target", File.join(link_root, "link"))
      link_zip = File.join(dir, "link.zip")
      _out, err, status = Open3.capture3("zip", "-yq", link_zip, "link", chdir: link_root)
      assert status.success?, err
      assert_raises(HiveReleaseCandidate::Error) do
        HiveReleaseCandidate::ReleaseArchive.extract_zip!(
          link_zip, File.join(dir, "link-extract")
        )
      end
    end
  end

  def test_candidate_verifier_accepts_exact_manifest_and_rejects_not_newer_version
    Dir.mktmpdir("release-candidate-verifier") do |dir|
      candidate = build_candidate_fixture(dir, VERSION)
      manifest = HiveReleaseCandidate::ReleaseCandidateVerifier.new.call(
        repo_root: ROOT, candidate_dir: candidate,
        candidate_sha: CANDIDATE_SHA, tag_version: VERSION
      )
      assert_equal "0.6.9", manifest.fetch("latest_stable_version")
      assert_equal(
        %W[
          hive-cli-#{VERSION}.gem
          hive-agent-skills-#{CANDIDATE_SHA}.tar.gz
          hive-web-#{VERSION}.tar.gz
        ].sort,
        manifest.fetch("public_files").values.sort
      )

      old = build_candidate_fixture(dir, "0.6.9", suffix: "-old")
      assert_raises(HiveReleaseCandidate::Error) do
        HiveReleaseCandidate::ReleaseCandidateVerifier.new.call(
          repo_root: ROOT, candidate_dir: old,
          candidate_sha: CANDIDATE_SHA, tag_version: "0.6.9"
        )
      end
    end
  end

  def test_publication_verifier_rehashes_only_exact_manifest_bound_public_bytes
    Dir.mktmpdir("release-publication-verifier") do |dir|
      candidate = build_candidate_fixture(dir, VERSION)
      selected = File.join(dir, "selected")
      FileUtils.mkdir_p(File.join(selected, "dist"))
      FileUtils.mkdir_p(File.join(selected, "proof"))
      manifest = JSON.parse(File.binread(File.join(candidate, "manifest.json")))
      FileUtils.cp(
        File.join(candidate, "manifest.json"),
        File.join(selected, "proof", "manifest.json")
      )
      manifest.fetch("files").each do |name, row|
        next if row["kind"] == "source"

        FileUtils.cp(File.join(candidate, name), File.join(selected, "dist", name))
      end
      result = HiveReleaseCandidate::ReleasePublicationVerifier.new.call(
        selected_root: selected, candidate_sha: CANDIDATE_SHA,
        tag_version: VERSION
      )
      assert_equal %w[gem skills web], result.fetch("files").keys

      gem_name = result.dig("files", "gem", "filename")
      File.binwrite(File.join(selected, "dist", gem_name), "substituted")
      assert_raises(HiveReleaseCandidate::Error) do
        HiveReleaseCandidate::ReleasePublicationVerifier.new.call(
          selected_root: selected, candidate_sha: CANDIDATE_SHA,
          tag_version: VERSION
        )
      end
    end
  end

  private

  ROOT = File.expand_path("../../..", __dir__)

  def selector(fixture)
    HiveReleaseCandidate::ReleaseSelector.new(
      candidate_sha: CANDIDATE_SHA, repository: REPOSITORY,
      tag_version: VERSION, checks: fixture.fetch(:checks),
      run: fixture.fetch(:run), jobs: fixture.fetch(:jobs),
      artifacts: fixture.fetch(:artifacts)
    )
  end

  def fixture
    external = "hive-release-candidate:v1:42:2:#{EVIDENCE_SHA}"
    jobs = HiveReleaseCandidate::ReleaseSelector::REQUIRED_RUN_JOBS.map do |name|
      {
        "name" => name, "run_id" => 42, "run_attempt" => 2,
        "status" => "completed", "conclusion" => "success"
      }
    end
    artifact = {
      "id" => 77, "name" => "hive-release-candidate-40-1",
      "digest" => ARTIFACT_DIGEST, "producer_run_id" => 40,
      "producer_run_attempt" => 1
    }
    gates = HiveReleaseCandidate::Aggregate::REQUIRED_JOBS.map do |name|
      {
        "name" => name, "status" => "completed", "conclusion" => "success",
        "run_id" => 42, "run_attempt" => 2,
        "candidate_sha" => CANDIDATE_SHA, "workflow_sha" => WORKFLOW_SHA,
        "workflow_path" => ".github/workflows/release-candidate.yml",
        "action_lock_sha256" => ACTION_LOCK, "artifact_id" => 77,
        "artifact_digest" => ARTIFACT_DIGEST,
        "artifact_producer_run_id" => 40,
        "artifact_producer_run_attempt" => 1
      }
    end
    ordinary = {
      "repository" => REPOSITORY, "head_sha" => CANDIDATE_SHA,
      "workflow" => ".github/workflows/ci.yml", "app" => "github-actions",
      "check_name" => "rake test (Ruby 3.4)", "run_id" => 11,
      "run_attempt" => 1, "status" => "completed", "conclusion" => "success"
    }
    {
      checks: {
        "check_runs" => [
          {
            "name" => "hive-release-candidate", "head_sha" => CANDIDATE_SHA,
            "status" => "completed", "conclusion" => "success",
            "app" => { "slug" => "github-actions" },
            "external_id" => external,
            "details_url" => "https://github.com/#{REPOSITORY}/actions/runs/42"
          },
          {
            "name" => "rake test (Ruby 3.4)", "head_sha" => CANDIDATE_SHA,
            "status" => "completed", "conclusion" => "success",
            "app" => { "slug" => "github-actions" },
            "details_url" => "https://github.com/#{REPOSITORY}/actions/runs/11"
          }
        ]
      },
      run: {
        "id" => 42, "run_attempt" => 2, "head_sha" => WORKFLOW_SHA,
        "path" => ".github/workflows/release-candidate.yml",
        "event" => "workflow_dispatch", "head_branch" => "main",
        "status" => "completed", "conclusion" => "success",
        "display_title" => "hive-release-candidate:req-release1:#{CANDIDATE_SHA}",
        "head_repository" => { "full_name" => REPOSITORY }
      },
      jobs: { "jobs" => jobs },
      artifacts: {
        "artifacts" => [ {
          "id" => 81, "name" => "hive-release-candidate-evidence-42-2",
          "digest" => EVIDENCE_ARTIFACT_DIGEST, "expired" => false,
          "workflow_run" => { "id" => 42, "head_sha" => WORKFLOW_SHA }
        } ]
      },
      evidence: {
        "trust_scope" => "trusted_remote", "repository" => REPOSITORY,
        "candidate_sha" => CANDIDATE_SHA, "workflow_sha" => WORKFLOW_SHA,
        "run_id" => 42, "run_attempt" => 2, "request_id" => "req-release1",
        "action_lock_sha256" => ACTION_LOCK, "artifact" => artifact,
        "scope_status" => "passed", "qa_status" => "qa_ready", "blockers" => [],
        "effective_gate_set" => gates, "ordinary_ci" => ordinary,
        "summary" => {
          "required" => HiveReleaseCandidate::Aggregate::REQUIRED_JOBS.size + 1,
          "passed" => HiveReleaseCandidate::Aggregate::REQUIRED_JOBS.size + 1,
          "failed" => 0, "advisory" => 0
        },
        "provenance" => {
          "run_id" => 42, "run_attempt" => 2,
          "replacement_gates" => HiveReleaseCandidate::Aggregate::REQUIRED_JOBS
        }
      },
      producer_run: {
        "id" => 40, "run_attempt" => 1, "head_sha" => WORKFLOW_SHA,
        "path" => ".github/workflows/release-candidate.yml",
        "event" => "workflow_dispatch", "head_branch" => "main",
        "status" => "completed", "conclusion" => "failure",
        "display_title" => "hive-release-candidate:req-source01:#{CANDIDATE_SHA}",
        "head_repository" => { "full_name" => REPOSITORY }
      },
      producer_artifact: {
        "id" => 77, "name" => "hive-release-candidate-40-1",
        "digest" => ARTIFACT_DIGEST, "expired" => false,
        "workflow_run" => { "id" => 40, "head_sha" => WORKFLOW_SHA }
      },
      ordinary_run: {
        "id" => 11, "run_attempt" => 1, "head_sha" => CANDIDATE_SHA,
        "path" => ".github/workflows/ci.yml", "head_branch" => "main",
        "status" => "completed", "conclusion" => "success",
        "head_repository" => { "full_name" => REPOSITORY }
      }
    }
  end

  def build_candidate_fixture(root, version, suffix: "")
    directory = File.join(root, "candidate#{suffix}")
    FileUtils.mkdir_p(directory)
    source_name = "hive-source-#{CANDIDATE_SHA}.tar.gz"
    files = {
      "hive-cli-#{version}.gem" => [ "gem", "gem" ],
      "hive-agent-skills-#{CANDIDATE_SHA}.tar.gz" => [ "skills", "skills" ],
      "hive-web-#{version}.tar.gz" => [ "web", "web" ]
    }
    source_path = File.join(directory, source_name)
    write_source_archive(source_path, version)
    files[source_name] = [ "source", File.binread(source_path) ]
    files.each do |name, (_kind, content)|
      path = File.join(directory, name)
      File.binwrite(path, content) unless File.exist?(path)
    end
    records = files.to_h do |name, (kind, _content)|
      path = File.join(directory, name)
      [
        name,
        {
          "kind" => kind, "sha256" => Digest::SHA256.file(path).hexdigest,
          "size" => File.size(path)
        }
      ]
    end
    File.write(
      File.join(directory, "manifest.json"),
      JSON.generate(
        "schema" => "hive-release-candidate-artifacts", "schema_version" => 1,
        "candidate_sha" => CANDIDATE_SHA, "hive_version" => version,
        "skill_version" => "1.0.0", "canonical_digest" => "1" * 64,
        "builder_revision" => builder_revision, "files" => records
      )
    )
    directory
  end

  def write_source_archive(path, version)
    entries = {
      "lib/hive/version.rb" => "module Hive\n  VERSION = \"#{version}\"\nend\n",
      "packaging/release_candidate/baselines.yml" =>
        File.binread(File.join(ROOT, "packaging/release_candidate/baselines.yml")),
      "packaging/live_agent_skills/proof.rb" =>
        File.binread(File.join(ROOT, "packaging/live_agent_skills/proof.rb")),
      "packaging/live_agent_skills/build.rb" =>
        File.binread(File.join(ROOT, "packaging/live_agent_skills/build.rb"))
    }
    Zlib::GzipWriter.open(path) do |gzip|
      Gem::Package::TarWriter.new(gzip) do |tar|
        entries.each do |name, content|
          tar.add_file_simple(name, 0o600, content.bytesize) { |io| io.write(content) }
        end
      end
    end
  end

  def builder_revision
    digest = Digest::SHA256.new
    %w[
      packaging/live_agent_skills/proof.rb
      packaging/live_agent_skills/build.rb
      packaging/managed_web_archive.rb
    ].each do |path|
      digest << File.basename(path) << "\0" <<
        File.binread(File.join(ROOT, path)) << "\0"
    end
    digest.hexdigest
  end
end
