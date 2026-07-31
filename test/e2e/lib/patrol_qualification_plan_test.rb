require_relative "../../test_helper"
require "digest"
require "fileutils"
require "open3"
require "tmpdir"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/workflow_package/canonical_json"
require_relative "patrol_qualification_plan"

class E2EPatrolQualificationPlanTest < Minitest::Test
  Candidate = Data.define(
    :candidate_sha, :manifest_bytes, :inputs, :digests
  )
  NOW = Time.utc(2026, 7, 31, 9, 30, 0)

  class CommittedReader
    def initialize(files)
      @files = files
    end

    def read(repo_root:, candidate_sha:, ref:)
      raise "unexpected root" unless repo_root == "/fixture/repo"
      raise "unexpected SHA" unless candidate_sha == "c" * 40

      @files.fetch(ref)
    end
  end

  def test_compiles_committed_expectations_without_exposing_them_to_candidate
    result = plan.call(
      candidate: candidate,
      repo_root: "/fixture/repo"
    )

    descriptor =
      Hive::Modules::Migration::
        QualificationRunDescriptor.load(
          result.descriptor_bytes
        )
    assert_equal result.run_id, descriptor.run_id
    assert_equal NOW.iso8601(6),
                 descriptor.payload.fetch("prepared_at")
    assert_equal(
      "d" * 64,
      descriptor.expectations
        .fetch("decision_expectations")
        .fetch(0)
        .fetch("decision_id")
    )
    scenario_ref =
      "inputs/scenarios/ordinary-clean.yml"
    assert_equal scenario_bytes,
                 result.inputs.fetch(scenario_ref).fetch(:bytes)
    request_facing = result.inputs.fetch(scenario_ref).fetch(:bytes)
    refute_includes request_facing, "decision_expectations"
    refute_includes request_facing, "decision_class"
    refute result.inputs.key?("inputs/scenarios/catalog.json")
    assert_equal(
      candidate.inputs.keys.sort + [
        "inputs/scenarios/manifest.json",
        scenario_ref
      ],
      result.inputs.keys.sort
    )
  end

  def test_rejects_scenario_drift_from_the_host_catalog
    files = committed_files.merge(
      scenario_ref =>
        scenario_bytes.sub("timer_due", "same_commit")
    )
    error = assert_raises(Hive::ConfigError) do
      plan(files).call(
        candidate: candidate,
        repo_root: "/fixture/repo"
      )
    end

    assert_equal "patrol qualification catalog is malformed",
                 error.message
  end

  def test_rejects_a_noncanonical_catalog
    files = committed_files.merge(
      Hive::E2E::PatrolQualificationPlan::DEFAULT_CATALOG_REF =>
        "#{JSON.pretty_generate(catalog)}\n"
    )

    assert_raises(Hive::ConfigError) do
      plan(files).call(
        candidate: candidate,
        repo_root: "/fixture/repo"
      )
    end
  end

  def test_committed_reader_ignores_dirty_bytes_and_rejects_a_symlink
    Dir.mktmpdir("patrol-plan-repository") do |repo|
      run_git(repo, "init", "-b", "main")
      run_git(repo, "config", "user.email", "test@example.com")
      run_git(repo, "config", "user.name", "Hive Test")
      FileUtils.mkdir_p(File.join(repo, "evidence"))
      path = File.join(repo, "evidence", "catalog.json")
      File.binwrite(path, "committed")
      link = File.join(repo, "evidence", "linked.yml")
      File.symlink("catalog.json", link)
      run_git(repo, "add", ".")
      run_git(repo, "commit", "-m", "fixture")
      sha = run_git(repo, "rev-parse", "HEAD").strip
      File.binwrite(path, "dirty")
      reader =
        Hive::E2E::PatrolQualificationPlan::CommittedReader.new

      assert_equal(
        "committed",
        reader.read(
          repo_root: repo,
          candidate_sha: sha,
          ref: "evidence/catalog.json"
        )
      )
      error = assert_raises(Hive::ConfigError) do
        reader.read(
          repo_root: repo,
          candidate_sha: sha,
          ref: "evidence/linked.yml"
        )
      end
      assert_match(/committed input is unavailable/, error.message)
    end
  end

  private

  def plan(files = committed_files)
    Hive::E2E::PatrolQualificationPlan.new(
      clock: -> { NOW },
      committed_reader: CommittedReader.new(files)
    )
  end

  def committed_files
    {
      Hive::E2E::PatrolQualificationPlan::DEFAULT_CATALOG_REF =>
        canonical(catalog),
      scenario_ref => scenario_bytes
    }
  end

  def scenario_ref
    "test/e2e/fixtures/patrol_qualification/" \
      "scenarios/ordinary.yml"
  end

  def candidate
    sha = "c" * 40
    source_name = "hive-source-#{sha}.tar.gz"
    gem_name = "hive-cli-0.7.0.gem"
    skills_name = "hive-agent-skills-#{sha}.tar.gz"
    web_name = "hive-web-0.7.0.tar.gz"
    artifacts = {
      source_name => [ "source", "source" ],
      gem_name => [ "gem", "gem" ],
      skills_name => [ "skills", "skills" ],
      web_name => [ "web", "web" ]
    }
    manifest = {
      "schema" => "hive-release-candidate-artifacts",
      "schema_version" => 1,
      "candidate_sha" => sha,
      "hive_version" => "0.7.0",
      "skill_version" => "1",
      "canonical_digest" => "8" * 64,
      "builder_revision" => "9" * 64,
      "files" => artifacts.to_h do |name, (kind, bytes)|
        [
          name,
          {
            "kind" => kind,
            "sha256" => Digest::SHA256.hexdigest(bytes),
            "size" => bytes.bytesize
          }
        ]
      end
    }
    manifest_bytes = canonical(manifest)
    installed = {
      "inputs/installed-target/bin/hive" => {
        bytes: "#!/usr/bin/env ruby\n",
        mode: 0o700
      },
      "inputs/installed-target/target.json" => {
        bytes: "{}",
        mode: 0o600
      }
    }
    inputs = artifacts.to_h do |name, (_kind, bytes)|
      [
        "inputs/candidate/#{name}",
        { bytes: bytes, mode: 0o600 }
      ]
    end.merge(
      "inputs/candidate/manifest.json" => {
        bytes: manifest_bytes,
        mode: 0o600
      }
    ).merge(installed)
    Candidate.new(
      candidate_sha: sha,
      manifest_bytes: manifest_bytes,
      inputs: inputs,
      digests: {
        "artifact_manifest_sha256" =>
          Digest::SHA256.hexdigest(manifest_bytes),
        "source_archive_sha256" =>
          Digest::SHA256.hexdigest("source"),
        "candidate_gem_sha256" =>
          Digest::SHA256.hexdigest("gem"),
        "skills_archive_sha256" =>
          Digest::SHA256.hexdigest("skills"),
        "installed_tree_sha256" => "7" * 64
      }
    )
  end

  def catalog
    {
      "schema" =>
        Hive::E2E::PatrolQualificationPlan::CATALOG_SCHEMA,
      "schema_version" => 1,
      "project" => {
        "project_id" => "qualification-project",
        "name" => "patrol-qualification",
        "repository" =>
          "github.com/example/patrol-qualification"
      },
      "module_selections" => %w[
        architecture-patrol patrol
      ].to_h do |name|
        marker = name == "patrol" ? "a" : "b"
        [
          name,
          {
            "selection_epoch" => 1,
            "active" => {
              "version" => "0.1.0",
              "catalog_commit" => marker * 40,
              "source_commit" => marker * 40,
              "manifest_digest" => marker * 64,
              "configuration_digest" =>
                (name == "patrol" ? "e" : "f") * 64
            }
          }
        ]
      end,
      "lanes" => %w[deterministic installed].to_h do |lane|
        [
          lane,
          {
            "repository_sha" =>
              (lane == "deterministic" ? "1" : "2") * 40,
            "timeout_seconds" => 300
          }
        ]
      end,
      "cases" => [
        {
          "case_id" => "ordinary-clean",
          "file" => "scenarios/ordinary.yml",
          "module" => "patrol",
          "operation" => "timer_due",
          "decision_expectations" => [
            {
              "control" => "none",
              "decision_class" => "ordinary-clean",
              "decision_id" => "d" * 64,
              "module" => "patrol",
              "repository" =>
                "github.com/example/patrol-qualification",
              "repository_sha" => "3" * 40,
              "trigger_digest" => "4" * 64
            }
          ],
          "expected_legacy_effect_keys" => [
            "effect-#{"5" * 64}"
          ],
          "matrix" => [ "timer_due" ],
          "faults" => [ "after_legacy_capture" ]
        }
      ]
    }
  end

  def scenario_bytes
    <<~YAML
      schema: hive-patrol-qualification-scenario
      schema_version: 1
      case_id: ordinary-clean
      module: patrol
      operation: timer_due
      clock: "2026-07-31T09:30:00.000000Z"
      faults:
        - after_legacy_capture
      reviewer:
        findings: []
    YAML
  end

  def canonical(value)
    Hive::WorkflowPackage::CanonicalJSON.generate(value)
  end

  def run_git(repo, *argv)
    output, error, status =
      Open3.capture3("git", *argv, chdir: repo)
    raise error unless status.success?

    output
  end
end
