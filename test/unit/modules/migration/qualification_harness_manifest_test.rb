require "test_helper"
require "digest"
require "fileutils"
require "open3"
require "tmpdir"
require "hive/modules/migration/qualification_harness_manifest"
require "hive/modules/migration/trusted_qualification_control"
require "hive/workflow_package/canonical_json"

class ModulesMigrationQualificationHarnessManifestTest <
    Minitest::Test
  MANIFEST =
    Hive::Modules::Migration::QualificationHarnessManifest
  CONTROL =
    Hive::Modules::Migration::TrustedQualificationControl
  CATALOG =
    "test/e2e/fixtures/patrol_qualification/catalog.json".freeze
  SCENARIO =
    "test/e2e/fixtures/patrol_qualification/scenarios/one.yml".freeze

  def test_verifies_every_committed_manifest_entry_and_ignores_dirty_tree
    with_repository do |context|
      File.binwrite(
        File.join(context.fetch(:repo), CATALOG),
        "dirty"
      )

      result = MANIFEST.verify!(
        control: control(context)
      )

      assert_equal context.fetch(:manifest_sha256),
                   result.sha256
      assert_equal MANIFEST::SCHEMA,
                   result.payload.fetch("schema")
      assert result.payload.frozen?
      assert result.payload.fetch("files").frozen?
    end
  end

  def test_rejects_arbitrary_manifest_digest
    with_repository do |context|
      error = assert_raises(Hive::ConfigError) do
        MANIFEST.verify!(
          control: control(
            context,
            harness_manifest_sha256: "f" * 64
          )
        )
      end

      assert_equal(
        "patrol qualification harness manifest is malformed",
        error.message
      )
    end
  end

  def test_rejects_changed_entry_digest_mode_and_missing_scenario
    [
      :digest,
      :mode,
      :missing_scenario
    ].each do |mutation|
      with_repository(mutation: mutation) do |context|
        error = assert_raises(Hive::ConfigError) do
          MANIFEST.verify!(control: control(context))
        end
        assert_equal(
          "patrol qualification harness manifest is malformed",
          error.message,
          mutation
        )
      end
    end
  end

  private

  def with_repository(mutation: nil)
    Dir.mktmpdir("qualification-manifest") do |repo|
      git(repo, "init", "--quiet", "--initial-branch=main")
      paths =
        (
          MANIFEST::REQUIRED_PATHS +
            [ CATALOG, SCENARIO ]
        ).uniq.sort
      paths.each do |path|
        bytes = if path == CATALOG
          canonical(
            "cases" => [
              { "file" => "scenarios/one.yml" }
            ]
          )
        else
          "fixture #{path}\n"
        end
        write(repo, path, bytes)
      end
      File.chmod(
        0o755,
        File.join(repo, MANIFEST::REQUIRED_PATHS.fetch(0))
      ) if mutation == :mode
      rows = paths.filter_map do |path|
        next if mutation == :missing_scenario &&
                path == SCENARIO

        bytes = File.binread(File.join(repo, path))
        {
          "path" => path,
          "mode" => "100644",
          "blob_oid" =>
            git(repo, "hash-object", path).strip,
          "size" => bytes.bytesize,
          "sha256" => Digest::SHA256.hexdigest(bytes)
        }
      end
      rows.fetch(0)["sha256"] = "0" * 64 if mutation == :digest
      manifest = canonical(
        "schema" => MANIFEST::SCHEMA,
        "schema_version" => MANIFEST::SCHEMA_VERSION,
        "files" => rows
      )
      write(repo, MANIFEST::PATH, manifest)
      git(repo, "add", ".")
      git(
        repo,
        "-c", "user.name=Hive Test",
        "-c", "user.email=hive@example.invalid",
        "commit", "--quiet", "-m", "fixture"
      )
      yield(
        repo: repo,
        commit_sha: git(repo, "rev-parse", "HEAD").strip,
        tree_sha:
          git(repo, "rev-parse", "HEAD^{tree}").strip,
        catalog_sha256:
          Digest::SHA256.hexdigest(
            git(repo, "show", "HEAD:#{CATALOG}")
          ),
        manifest_sha256: Digest::SHA256.hexdigest(manifest)
      )
    end
  end

  def control(context, harness_manifest_sha256: nil)
    CONTROL.build(
      repository: "github.com/example/hive",
      ref: nil,
      commit_sha: context.fetch(:commit_sha),
      tree_sha: context.fetch(:tree_sha),
      trust_scope: "local",
      catalog_ref: CATALOG,
      catalog_sha256: context.fetch(:catalog_sha256),
      harness_manifest_sha256:
        harness_manifest_sha256 ||
          context.fetch(:manifest_sha256),
      provenance: {
        "workflow_path" => nil,
        "workflow_sha" => nil,
        "run_id" => nil,
        "run_attempt" => nil,
        "action_lock_sha256" => nil
      },
      checkout_root: context.fetch(:repo)
    )
  end

  def write(repo, relative, bytes)
    path = File.join(repo, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, bytes)
    File.chmod(0o644, path)
  end

  def canonical(value)
    Hive::WorkflowPackage::CanonicalJSON.generate(value)
  end

  def git(repo, *arguments)
    output, error, status =
      Open3.capture3("git", *arguments, chdir: repo)
    raise error unless status.success?
    output
  end
end
