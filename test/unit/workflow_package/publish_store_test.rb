require "test_helper"
require "hive/workflow_package/canonical_yaml"
require "hive/workflow_package/publish_store"
require "hive/workflow_package/publisher"

class WorkflowPackagePublishStoreTest < Minitest::Test
  include HiveTestHelper

  def test_persists_one_private_receipt_and_validated_digest_bundle
    with_package do |package|
      with_tmp_dir do |state|
        store = Hive::WorkflowPackage::PublishStore.new(root: File.join(state, "publish"))
        receipt = store.create_or_load(package, registry: "owner/registry")
        loaded = store.load("owner/registry", "demo", "1.2.3")

        assert_equal receipt.data, loaded.data
        assert_equal 0o600, File.stat(store.receipt_path("owner/registry", "demo", "1.2.3")).mode & 0o777
        assert_equal 0o700, File.stat(store.root).mode & 0o777
        bundle = store.verify_bundle(loaded)
        assert File.file?(File.join(bundle, "manifest.yml"))
      end
    end
  end

  def test_same_digest_converges_and_different_digest_never_replaces_identity
    with_package do |package|
      with_tmp_dir do |state|
        store = Hive::WorkflowPackage::PublishStore.new(root: File.join(state, "publish"))
        first = store.create_or_load(package, registry: "owner/registry")
        assert_equal first.data, store.create_or_load(package, registry: "owner/registry").data

        changed = package.with(package_digest: "f" * 64, release_digest: "e" * 64)
        assert_raises(Hive::WorkflowPackage::PublishConflict) do
          store.create_or_load(changed, registry: "owner/registry")
        end
        assert_equal first.data, store.load("owner/registry", "demo", "1.2.3").data
      end
    end
  end

  def test_corrupt_bundle_and_receipt_permissions_fail_closed_without_cleanup
    with_package do |package|
      with_tmp_dir do |state|
        store = Hive::WorkflowPackage::PublishStore.new(root: File.join(state, "publish"))
        receipt = store.create_or_load(package, registry: "owner/registry")
        manifest = File.join(store.bundle_path(receipt.package_digest), "manifest.yml")
        File.open(manifest, "ab") { |file| file.write("tamper") }
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) { store.verify_bundle(receipt) }
        assert File.exist?(manifest), "corrupt evidence must be preserved for diagnosis"

        path = store.receipt_path("owner/registry", "demo", "1.2.3")
        File.chmod(0o644, path)
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          store.load("owner/registry", "demo", "1.2.3")
        end
      end
    end
  end

  private

  def with_package
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, "instructions"))
      File.write(File.join(root, "README.md"), "# Demo\n")
      File.write(File.join(root, "instructions", "work.md"), "Read files only.\n")
      File.write(File.join(root, "workflow.yml"), <<~YAML)
        id: demo
        stages:
          - name: work
            kind: agent
            state_file: work.md
            instruction: instructions/work.md
            mapping_role: development
            mapping_contract: demo-work-v1
            permissions: read-only
      YAML
      prefix = "packages/demo/1.2.3/"
      files = %w[README.md instructions/work.md workflow.yml].to_h do |relative|
        [ "#{prefix}#{relative}", Digest::SHA256.file(File.join(root, relative)).hexdigest ]
      end
      document = {
        "schema" => "honeycomb-manifest/v1", "name" => "demo", "version" => "1.2.3",
        "description" => "Demo", "author" => { "name" => "Test", "url" => "https://example.test/test" },
        "license" => "MIT", "hive_min_version" => Hive::VERSION,
        "source" => { "url" => "https://example.test/source", "revision" => "c" * 40 },
        "permissions" => {
          "risk" => "low", "capabilities" => [ "filesystem-read" ], "network_hosts" => [],
          "filesystem_read" => %w[repository task], "filesystem_write" => [], "secrets" => []
        },
        "files" => files,
        "x-hive" => { "tools" => [], "prompt_assets" => [], "optional_inputs" => [], "external_skills" => [] }
      }
      document["release_sha256"] = Digest::SHA256.hexdigest(
        Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document, include_release: false)
      )
      manifest = Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document)
      File.binwrite(File.join(root, "manifest.yml"), manifest)
      package = Hive::WorkflowPackage::Publisher::Package.new(
        name: "demo", version: "1.2.3", root: root,
        package_digest: Digest::SHA256.hexdigest(manifest),
        release_digest: document.fetch("release_sha256"), warnings: [], findings: [],
        lint_contract: {
          "version" => "v1", "upstream_commit" => "c" * 40,
          "upstream_policy_sha256" => "e" * 64,
          "fixture_corpus_sha256" => "f" * 64,
          "expected_output_sha256" => "0" * 64,
          "contract_sha256" => "d" * 64
        }
      )
      yield package
    end
  end
end
