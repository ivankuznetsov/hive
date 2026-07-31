# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "json"
require "open3"
require "rubygems/package"
require_relative "../../../packaging/patrol_evidence/candidate"
require "hive/modules/migration/qualification_installed_target"

class PatrolEvidenceCandidateTest < Minitest::Test
  include HiveTestHelper

  ROOT = File.expand_path("../../..", __dir__)

  def test_builds_canonical_exact_head_inputs_and_materializable_target_offline
    with_candidate_fixture do |fixture|
      result = fixture.fetch(:preparer).call

      assert_equal fixture.fetch(:sha), result.candidate_sha
      assert_equal "1.0.0", result.version
      assert_equal(
        Hive::WorkflowPackage::CanonicalJSON.generate(
          JSON.parse(result.manifest_bytes)
        ),
        result.manifest_bytes
      )
      assert_equal(
        result.manifest_bytes,
        result.inputs.fetch("inputs/candidate/manifest.json").fetch(:bytes)
      )
      assert_equal(
        %w[
          artifact_manifest_sha256 candidate_gem_sha256
          installed_tree_sha256 skills_archive_sha256
          source_archive_sha256
        ],
        result.digests.keys.sort
      )
      result.inputs.each do |ref, snapshot|
        expected =
          ref == "inputs/installed-target/bin/hive" ? 0o700 : 0o600
        assert_equal expected, snapshot.fetch(:mode), ref
      end

      installed = result.inputs.select do |ref, _snapshot|
        ref.start_with?("inputs/installed-target/")
      end
      materialized =
        Hive::Modules::Migration::QualificationInstalledTarget.new.materialize(
          files: installed,
          destination: File.join(fixture.fetch(:root), "materialized"),
          expected_tree_sha256:
            result.digests.fetch("installed_tree_sha256"),
          expected_gem_sha256:
            result.digests.fetch("candidate_gem_sha256"),
          expected_skills_sha256:
            result.digests.fetch("skills_archive_sha256"),
          expected_executable: "bin/hive"
        )
      assert_equal(
        result.digests.fetch("installed_tree_sha256"),
        materialized.tree_sha256
      )

      stdout, stderr, status = Open3.capture3(
        {
          "GEM_HOME" => materialized.root,
          "GEM_PATH" => materialized.root
        },
        materialized.executable
      )
      assert status.success?, stderr
      assert_equal "fixture hive\n", stdout
    end
  end

  def test_refuses_dirty_checkout_before_artifact_builder_runs
    with_candidate_fixture do |fixture|
      File.write(
        File.join(fixture.fetch(:repo), "untracked.txt"),
        "dirty\n"
      )

      error = assert_raises(HivePatrolEvidence::Error) do
        fixture.fetch(:preparer).call
      end

      assert_includes error.message, "must be clean"
      refute fixture.fetch(:artifacts_class).called
    end
  end

  def test_normalizes_release_candidate_errors_and_preserves_the_cause
    with_candidate_fixture do |fixture|
      original = HiveReleaseCandidate::UnavailableError.new(
        "fixture artifact builder unavailable"
      )
      artifacts_class = Class.new do
        define_method(:initialize) do |**_keywords|
          nil
        end
        define_method(:call) { raise original }
      end
      preparer = HivePatrolEvidence::CandidatePreparer.new(
        repo_root: fixture.fetch(:repo),
        workspace: fixture.fetch(:workspace),
        gem_cache_roots: [
          File.dirname(fixture.fetch(:dependency_gem))
        ],
        artifacts_class: artifacts_class
      )

      error = assert_raises(HivePatrolEvidence::Error) do
        preparer.call
      end

      assert_equal original.message, error.message
      assert_equal original.exit_code, error.exit_code
      assert_equal original.kind, error.kind
      assert_same original, error.cause
    end
  end

  def test_staging_cleanup_failure_preserves_install_failure_as_cause
    with_tmp_dir do |root|
      repo = File.join(root, "repo")
      workspace = File.join(root, "workspace")
      FileUtils.mkdir_p(repo)
      Dir.mkdir(workspace, 0o700)
      preparer = HivePatrolEvidence::CandidatePreparer.new(
        repo_root: repo,
        workspace: workspace,
        stage_remover: ->(_path) { nil }
      )

      error = assert_raises(
        HivePatrolEvidence::CleanupFailure
      ) do
        preparer.send(
          :install_candidate!,
          destination: File.join(workspace, "installed-target"),
          candidate_gem: File.join(root, "missing.gem"),
          dependency_gems: [],
          version: "1.0.0",
          gem_sha256: "a" * 64,
          skills_sha256: "b" * 64
        )
      end

      assert_same error.primary, error.cause
      assert_instance_of HivePatrolEvidence::Error,
                         error.primary
      assert_includes error.primary.message,
                      "offline gem install failed"
      assert_instance_of HivePatrolEvidence::Error,
                         error.cleanup
      assert_includes error.cleanup.message,
                      "did not remove its exact root"
    ensure
      if workspace && File.directory?(workspace)
        Dir.children(workspace).each do |name|
          FileUtils.remove_entry_secure(
            File.join(workspace, name)
          )
        end
      end
    end
  end

  def test_refuses_missing_or_hardlinked_cached_dependency
    with_candidate_fixture do |fixture|
      dependency = fixture.fetch(:dependency_gem)
      shadow = File.join(fixture.fetch(:root), "dependency-shadow.gem")
      File.link(dependency, shadow)

      error = assert_raises(HivePatrolEvidence::Error) do
        fixture.fetch(:preparer).call
      end

      assert_includes error.message, "cached gem is unsafe"
    end

    with_candidate_fixture do |fixture|
      FileUtils.rm_f(fixture.fetch(:dependency_gem))

      error = assert_raises(HivePatrolEvidence::Error) do
        fixture.fetch(:preparer).call
      end

      assert_includes error.message, "is missing"
    end
  end

  def test_selects_native_variant_and_rejects_unavailable_platform
    with_tmp_dir do |dir|
      repo = File.join(dir, "repo")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(repo)
      Dir.mkdir(workspace, 0o700)
      preparer = HivePatrolEvidence::CandidatePreparer.new(
        repo_root: repo, workspace: workspace
      )
      local = Gem::Platform.local.to_s
      rows = [
        dependency_row(platform: "ruby"),
        dependency_row(platform: local)
      ]

      selected =
        preparer.send(:select_installable_dependencies, rows)

      assert_equal 1, selected.length
      assert_equal local, selected.first.fetch("platform")

      error = assert_raises(HivePatrolEvidence::Error) do
        preparer.send(
          :select_installable_dependencies,
          [ dependency_row(platform: "arm64-darwin") ]
        )
      end
      assert_includes error.message, "no installable"
    end
  end

  def test_installed_snapshot_rejects_symlinks_and_excessive_file_count
    with_tmp_dir do |dir|
      repo = File.join(dir, "repo")
      workspace = File.join(dir, "workspace")
      target = File.join(dir, "target")
      FileUtils.mkdir_p(repo)
      Dir.mkdir(workspace, 0o700)
      FileUtils.mkdir_p(File.join(target, "bin"))
      File.write(File.join(target, "bin/hive"), "fixture")
      File.write(File.join(target, "target.json"), "{}")
      outside = File.join(dir, "outside")
      File.write(outside, "outside")
      File.symlink(outside, File.join(target, "linked"))
      preparer = HivePatrolEvidence::CandidatePreparer.new(
        repo_root: repo, workspace: workspace
      )

      error = assert_raises(HivePatrolEvidence::Error) do
        preparer.send(:snapshot_installed_target, target)
      end
      assert_includes error.message, "contains a symlink"

      FileUtils.rm_f(File.join(target, "linked"))
      limit =
        Hive::Modules::Migration::MigrationRepository::
          MAX_QUALIFICATION_FILES
      limit.times do |index|
        File.write(File.join(target, format("file-%04d", index)), "")
      end
      error = assert_raises(HivePatrolEvidence::Error) do
        preparer.send(:snapshot_installed_target, target)
      end
      assert_includes error.message, "bounded file count"
    end
  end

  private

  def with_candidate_fixture
    with_tmp_dir do |root|
      repo = File.join(root, "repo")
      workspace = File.join(root, "workspace")
      cache = File.join(root, "cache")
      gems = File.join(root, "gems")
      FileUtils.mkdir_p(repo)
      Dir.mkdir(workspace, 0o700)
      FileUtils.mkdir_p(cache)
      FileUtils.mkdir_p(gems)
      initialize_repo(repo)
      dependency_gem = build_gem(
        gems, name: "fixture-dep", version: "1.0.0"
      )
      FileUtils.cp(dependency_gem, cache)
      dependency_gem = File.join(cache, File.basename(dependency_gem))
      candidate_gem = build_gem(
        gems, name: "hive-cli", version: "1.0.0",
        executable: true
      )
      sha = git(repo, "rev-parse", "HEAD").strip
      artifacts_class = fixture_artifacts_class(
        candidate_gem: candidate_gem
      )
      preparer = HivePatrolEvidence::CandidatePreparer.new(
        repo_root: repo,
        workspace: workspace,
        gem_cache_roots: [ cache ],
        artifacts_class: artifacts_class
      )
      yield(
        root: root,
        repo: repo,
        workspace: workspace,
        dependency_gem: dependency_gem,
        candidate_gem: candidate_gem,
        artifacts_class: artifacts_class,
        sha: sha,
        preparer: preparer
      )
    end
  end

  def initialize_repo(repo)
    git(repo, "init", "-b", "main")
    git(repo, "config", "user.email", "test@example.com")
    git(repo, "config", "user.name", "Hive Test")
    FileUtils.mkdir_p(
      File.join(repo, "packaging/release_candidate")
    )
    FileUtils.cp(
      File.join(
        ROOT, "packaging/release_candidate/baselines.yml"
      ),
      File.join(
        repo, "packaging/release_candidate/baselines.yml"
      )
    )
    File.write(File.join(repo, "Gemfile.lock"), <<~LOCK)
      PATH
        remote: .
        specs:
          hive-cli (1.0.0)
            fixture-dep (= 1.0.0)

      GEM
        remote: https://rubygems.org/
        specs:
          fixture-dep (1.0.0)

      PLATFORMS
        ruby

      DEPENDENCIES
        hive-cli!

      BUNDLED WITH
         2.7.2
    LOCK
    git(repo, "add", ".")
    git(repo, "commit", "-m", "fixture candidate")
  end

  def build_gem(directory, name:, version:, executable: false)
    root = File.join(directory, "#{name}-source")
    FileUtils.mkdir_p(File.join(root, "lib"))
    files = [ "lib/#{name.tr('-', '_')}.rb" ]
    File.write(File.join(root, files.first), "module FixtureGem; end\n")
    if executable
      FileUtils.mkdir_p(File.join(root, "bin"))
      files << "bin/hive"
      File.write(
        File.join(root, "bin/hive"),
        "#!/usr/bin/env ruby\nputs \"fixture hive\"\n"
      )
      File.chmod(0o755, File.join(root, "bin/hive"))
    end
    spec = Gem::Specification.new do |value|
      value.name = name
      value.version = version
      value.summary = "fixture"
      value.authors = [ "Hive Test" ]
      value.files = files
      value.bindir = "bin"
      value.executables = [ "hive" ] if executable
      value.require_paths = [ "lib" ]
    end
    filename = nil
    _stdout, _stderr = capture_io do
      Dir.chdir(root) { filename = Gem::Package.build(spec) }
    end
    path = File.join(root, filename)
    destination = File.join(directory, filename)
    FileUtils.mv(path, destination)
    destination
  end

  def fixture_artifacts_class(candidate_gem:)
    Class.new do
      class << self
        attr_accessor :called
      end
      self.called = false

      define_method(:initialize) do |repo_root:, candidate_sha:, candidate_dir:|
        @candidate_sha = candidate_sha
        @candidate_dir = candidate_dir
        @candidate_gem = candidate_gem
      end

      define_method(:call) do
        self.class.called = true
        FileUtils.mkdir_p(@candidate_dir)
        files = {
          "hive-cli-1.0.0.gem" => [ "gem", File.binread(@candidate_gem) ],
          "hive-source-#{@candidate_sha}.tar.gz" =>
            [ "source", "source archive" ],
          "hive-agent-skills-#{@candidate_sha}.tar.gz" =>
            [ "skills", "skills archive" ],
          "hive-web-1.0.0.tar.gz" => [ "web", "web archive" ]
        }
        records = files.to_h do |name, (kind, bytes)|
          File.binwrite(File.join(@candidate_dir, name), bytes)
          [
            name,
            {
              "kind" => kind,
              "sha256" => Digest::SHA256.hexdigest(bytes),
              "size" => bytes.bytesize
            }
          ]
        end
        @manifest = {
          "schema" =>
            HiveReleaseCandidate::Artifacts::MANIFEST_SCHEMA,
          "schema_version" => HiveReleaseCandidate::SCHEMA_VERSION,
          "candidate_sha" => @candidate_sha,
          "hive_version" => "1.0.0",
          "skill_version" => "1",
          "canonical_digest" => "a" * 64,
          "builder_revision" => "b" * 64,
          "files" => records
        }
        File.write(
          File.join(@candidate_dir, "manifest.json"),
          JSON.pretty_generate(@manifest)
        )
        @manifest
      end

      define_method(:verify!) { @manifest }
    end
  end

  def dependency_row(platform:)
    suffix = platform == "ruby" ? "" : "-#{platform}"
    {
      "name" => "fixture-dep",
      "version" => "1.0.0",
      "platform" => platform,
      "filename" => "fixture-dep-1.0.0#{suffix}.gem"
    }
  end

  def git(repo, *argv)
    stdout, stderr, status =
      Open3.capture3("git", *argv, chdir: repo)
    assert status.success?, stderr
    stdout
  end
end
