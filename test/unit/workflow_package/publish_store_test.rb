require "test_helper"
require "hive/workflow_package/canonical_yaml"
require "hive/workflow_package/publish_lock"
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

  def test_stale_writers_cannot_replace_newer_progress_or_lifecycle_evidence
    with_package do |package|
      with_tmp_dir do |state|
        store = Hive::WorkflowPackage::PublishStore.new(root: File.join(state, "publish"))
        receipt = store.create_or_load(package, registry: "owner/registry").advance(
          "pr_verified",
          submission_mode: "direct", destination_repository: "owner/registry",
          base_branch: "main", base_sha: "b" * 40,
          head_repository: "owner/registry", head_branch: "honeycomb-demo",
          owner: "owner", commit_oid: "c" * 40, pr_number: 1,
          pr_url: "https://github.com/owner/registry/pull/1"
        )
        store.save(receipt)
        stale = receipt.observe(
          state: "pending_review", observed_at: "2026-07-21T12:00:00Z",
          pr_url: receipt.data.fetch("pr_url"), pr_number: 1
        )
        listed = receipt.observe(
          state: "listed", observed_at: "2026-07-21T13:00:00Z",
          pr_url: receipt.data.fetch("pr_url"), pr_number: 1
        )
        store.save(listed)

        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) { store.save(stale) }
        loaded = store.load("owner/registry", "demo", "1.2.3")
        assert_equal "listed", loaded.observation.fetch("state")
        assert_equal "2026-07-21T13:00:00Z", loaded.observation.fetch("observed_at")
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          store.update("owner/registry", "demo", "1.2.3") { receipt }
        end
      end
    end
  end

  def test_listed_bundle_can_be_marked_gc_eligible_without_removing_receipt
    with_package do |package|
      with_tmp_dir do |state|
        store = Hive::WorkflowPackage::PublishStore.new(root: File.join(state, "publish"))
        receipt = store.create_or_load(package, registry: "owner/registry")
        receipt = receipt.advance(
          "pr_verified",
          submission_mode: "direct", destination_repository: "owner/registry",
          base_branch: "main", base_sha: "b" * 40,
          head_repository: "owner/registry", head_branch: "honeycomb-demo",
          owner: "owner", commit_oid: "c" * 40, pr_number: 1,
          pr_url: "https://github.com/owner/registry/pull/1"
        )
        store.save(receipt)
        listed = receipt.observe(
          state: "listed", observed_at: "2026-07-21T13:00:00Z",
          pr_url: receipt.data.fetch("pr_url"), pr_number: 1
        )
        store.save(listed)

        marker = store.mark_bundle_gc_eligible(listed)

        assert store.bundle_gc_eligible?(package.package_digest)
        assert_equal 0o600, File.stat(marker).mode & 0o777
        assert File.directory?(store.bundle_path(package.package_digest))
        assert_equal listed.data, store.load("owner/registry", "demo", "1.2.3").data
      end
    end
  end

  def test_retained_bundle_rejects_version_payload_and_state_file_drift
    with_package do |package|
      with_tmp_dir do |state|
        store = Hive::WorkflowPackage::PublishStore.new(root: File.join(state, "publish"))
        receipt = store.create_or_load(package, registry: "owner/registry")

        wrong_version = Hive::WorkflowPackage::PublishReceipt.from_h(
          receipt.to_h.merge("version" => "9.9.9")
        )
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          store.verify_bundle(wrong_version)
        end

        readme = File.join(store.bundle_path(receipt.package_digest), "README.md")
        File.write(readme, "changed")
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          store.verify_bundle(receipt)
        end
      end
    end
  end

  def test_retained_bundle_rechecks_the_validated_manifest_version
    with_package do |package|
      with_tmp_dir do |state|
        store = Hive::WorkflowPackage::PublishStore.new(root: File.join(state, "publish"))
        receipt = store.create_or_load(package, registry: "owner/registry")
        result = Struct.new(:manifest).new(
          Struct.new(:data).new({ "version" => "9.9.9" })
        )

        with_replaced_singleton_method(
          Hive::WorkflowPackage::Validator, :validate!, ->(*_args, **_options) { result }
        ) do
          assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
            store.verify_bundle(receipt)
          end
        end
      end
    end
  end

  def test_retention_rechecks_manifest_and_reuses_only_verified_bundle
    with_package do |package|
      with_tmp_dir do |state|
        store = Hive::WorkflowPackage::PublishStore.new(root: File.join(state, "publish"))
        receipt = store.create_or_load(package, registry: "owner/registry")
        assert_equal store.bundle_path(receipt.package_digest),
                     store.send(:persist_bundle, package)

        File.open(File.join(package.root, "manifest.yml"), "ab") { |file| file.write("changed") }
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          store.send(:persist_bundle, package)
        end

        missing = package.with(root: File.join(state, "missing"))
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          store.send(:persist_bundle, missing)
        end
      end
    end
  end

  def test_retention_maps_validation_io_and_copy_identity_failures
    with_package do |package|
      with_tmp_dir do |state|
        store = Hive::WorkflowPackage::PublishStore.new(root: File.join(state, "publish"))
        with_replaced_singleton_method(
          Hive::WorkflowPackage::Validator, :validate!,
          ->(*_args, **_options) { raise Errno::EACCES, "denied" }
        ) do
          assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
            store.send(:persist_bundle, package)
          end
        end

        destination = File.join(state, "copy")
        FileUtils.mkdir_p(destination)
        target = File.join(package.root, "README.md")
        original = Hive::WorkflowPackage::SafeFile.method(:read)
        replacement = lambda do |path, **options|
          bytes, stat = original.call(path, **options)
          next [ bytes, stat ] unless path == target

          changed = Struct.new(:dev, :ino).new(stat.dev + 1, stat.ino)
          [ bytes, changed ]
        end
        with_replaced_singleton_method(
          Hive::WorkflowPackage::SafeFile, :read, replacement
        ) do
          assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
            store.send(:copy_tree, package.root, destination)
          end
        end
      end
    end
  end

  def test_gc_marker_wraps_filesystem_failures
    with_package do |package|
      with_tmp_dir do |state|
        store = Hive::WorkflowPackage::PublishStore.new(root: File.join(state, "publish"))
        receipt = store.create_or_load(package, registry: "owner/registry")

        with_replaced_singleton_method(
          Hive::AtomicFile, :write,
          ->(*_args, **_options) { raise Errno::EACCES, "denied" }
        ) do
          assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
            store.mark_bundle_gc_eligible(receipt)
          end
        end
      end
    end
  end

  def test_receipt_and_bundle_files_fail_closed_on_canonical_link_and_missing_edges
    with_package do |package|
      with_tmp_dir do |state|
        store = Hive::WorkflowPackage::PublishStore.new(root: File.join(state, "publish"))
        receipt = store.create_or_load(package, registry: "owner/registry")
        receipt_path = store.receipt_path("owner/registry", "demo", "1.2.3")

        data = JSON.parse(File.read(receipt_path))
        File.write(receipt_path, JSON.pretty_generate(data))
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          store.load("owner/registry", "demo", "1.2.3")
        end
        File.write(receipt_path, "{not-json")
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          store.load("owner/registry", "demo", "1.2.3")
        end

        bundle = store.bundle_path(receipt.package_digest)
        File.chmod(0o755, bundle)
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          store.verify_bundle(receipt)
        end
        File.chmod(0o700, bundle)
        manifest = File.join(bundle, "manifest.yml")
        File.link(manifest, File.join(bundle, "manifest-copy.yml"))
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          store.verify_bundle(receipt)
        end
        FileUtils.rm_f(File.join(bundle, "manifest-copy.yml"))
        FileUtils.rm_rf(bundle)
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          store.verify_bundle(receipt)
        end
        assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          store.send(:secure_file!, File.join(state, "missing-state"))
        end

        assert_equal receipt.identity.transform_keys(&:to_sym), store.send(:symbol_identity, receipt)
      end
    end
  end

  def test_publish_lock_rejects_insecure_state_and_wraps_open_failures
    with_tmp_dir do |root|
      insecure = File.join(root, "insecure")
      FileUtils.mkdir_p(insecure)
      File.chmod(0o755, insecure)
      assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
        Hive::WorkflowPackage::PublishLock.ensure_private_directory!(insecure)
      end

      private_root = File.join(root, "private")
      replacement = ->(*_args, &_block) { raise Errno::ENOSPC, "full" }
      with_replaced_singleton_method(File, :open, replacement) do
        assert_raises(Hive::ConcurrentRunError) do
          Hive::WorkflowPackage::PublishLock.with_lock(private_root, "identity") { flunk }
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
