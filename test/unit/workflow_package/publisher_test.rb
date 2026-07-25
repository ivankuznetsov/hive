require "test_helper"
require "hive/workflow_package/publisher"

class WorkflowPackagePublisherTest < Minitest::Test
  include HiveTestHelper

  Package = Hive::WorkflowPackage::Publisher::Package
  RetainedReceipt = Data.define(
    :name, :version, :package_digest, :release_digest, :lint_contract
  )

  def test_builds_only_the_canonical_immutable_version_payload_deterministically
    with_authored_workflow do |project, authored_dir|
      File.write(File.join(authored_dir, "ignored.txt"), "do not publish\n")
      manifests = 2.times.map do
        Dir.mktmpdir("publisher-test-") do |destination|
          package = publisher(project).package(destination: destination)
          assert_equal %w[README.md instructions/work.md manifest.yml workflow.yml],
                       Dir.glob(File.join(destination, "**", "*"), File::FNM_DOTMATCH)
                          .select { |path| File.file?(path) }
                          .map { |path| path.delete_prefix("#{destination}/") }.sort
          assert_includes File.read(File.join(destination, "workflow.yml")), "instructions/work.md"
          document = YAML.safe_load(File.binread(File.join(destination, "manifest.yml")))
          assert_equal "honeycomb-manifest/v1", document.fetch("schema")
          assert_equal "demo", document.fetch("name")
          assert_equal "1.2.3", document.fetch("version")
          assert document.fetch("files").keys.all? { |path| path.start_with?("packages/demo/1.2.3/") }
          assert_equal package.release_digest, document.fetch("release_sha256")
          assert_equal package.package_digest, Digest::SHA256.file(File.join(destination, "manifest.yml")).hexdigest
          File.binread(File.join(destination, "manifest.yml"))
        end
      end

      assert_equal manifests.first, manifests.last
    end
  end

  def test_secret_fails_preflight_without_leaking_secret_material
    secret = "sk-ant-#{'x' * 30}"
    with_authored_workflow(instruction: "Use #{secret}\n") do |project, _authored_dir|
      error = Dir.mktmpdir("publisher-test-") do |destination|
        assert_raises(Hive::WorkflowPackage::PackageError) do
          publisher(project).package(destination: destination)
        end
      end
      refute_includes error.message, secret
    end
  end

  def test_reviewable_high_risk_permissions_are_not_rejected_by_runtime_admission
    with_authored_workflow do |project, authored_dir|
      descriptor = File.join(File.dirname(authored_dir), "demo.yml")
      File.write(descriptor, File.read(descriptor).sub("permissions: read-only", "permissions: yolo"))

      package = Dir.mktmpdir("publisher-test-") do |destination|
        publisher(project).package(destination: destination)
      end

      assert_includes package.warnings.map { |warning| warning.fetch("rule_id") },
                      "permission.broad-declaration"
      assert_equal false, package.mutation_blocked?
    end
  end

  def test_missing_or_placeholder_metadata_stops_before_submission
    with_authored_workflow do |project, authored_dir|
      File.write(File.join(authored_dir, "honeycomb.yml"), "summary: Describe what this workflow does\nauthor:\n  name: Your name\n")
      assert_raises(Hive::ConfigError) do
        Dir.mktmpdir("publisher-test-") { |destination| publisher(project).package(destination: destination) }
      end
    end
  end

  def test_publish_delegates_to_the_registry_submission
    submitted = nil
    allowed = nil
    submission = Object.new
    receipt = Object.new
    submission.define_singleton_method(:submit) do |package, allow_mutation:|
      submitted = package
      allowed = allow_mutation
      Struct.new(:receipt).new(receipt)
    end
    resolver = Object.new
    resolver.define_singleton_method(:resolve) { |value| value.equal?(receipt) ? "submitted" : raise("wrong receipt") }
    store = Object.new
    store.define_singleton_method(:load) { |_registry, _name, _version| nil }
    package = Package.new(name: "demo", version: "1.2.3", root: Dir.pwd,
                          manifest_digest: "a" * 64, warnings: [])
    instance = Hive::WorkflowPackage::Publisher.new(
      "demo", project_root: Dir.pwd, version: "1.2.3",
      submission: submission, resolver: resolver, store: store
    )

    assert_equal "submitted", instance.publish(package)
    assert_same package, submitted
    assert_equal true, allowed
  end

  def test_publish_reconciles_a_verified_receipt_before_any_new_submission
    package = Package.new(name: "demo", version: "1.2.3", root: Dir.pwd,
                          manifest_digest: "a" * 64, warnings: [])
    receipt = Struct.new(:last_completed_step).new("pr_verified")
    store = Object.new
    store.define_singleton_method(:load) { |_registry, _name, _version| receipt }
    submission = Object.new
    submission.define_singleton_method(:submit) { |_package| raise "must not mutate" }
    resolver = Object.new
    resolver.define_singleton_method(:resolve) { |value| value.equal?(receipt) ? "current" : raise("wrong receipt") }
    instance = Hive::WorkflowPackage::Publisher.new(
      "demo", project_root: Dir.pwd, version: "1.2.3",
      submission: submission, resolver: resolver, store: store
    )

    assert_equal "current", instance.publish(package)
  end

  def test_current_policy_findings_allow_observation_but_not_new_mutation
    finding = {
      "rule_id" => "deny.pipe-to-shell", "severity" => "error",
      "path" => "instructions/work.md", "message" => "blocked"
    }
    package = Package.new(
      name: "demo", version: "1.2.3", root: Dir.pwd,
      manifest_digest: "a" * 64, warnings: [ finding ], findings: [ finding ]
    )
    store = Object.new
    store.define_singleton_method(:load) { |_registry, _name, _version| nil }
    submission = Object.new
    submission.define_singleton_method(:submit) do |_package, allow_mutation:|
      raise "mutation was allowed" if allow_mutation
      Struct.new(:receipt).new(:discovered)
    end
    resolver = Object.new
    resolver.define_singleton_method(:resolve) { |receipt| receipt == :discovered ? "observed" : raise }
    instance = Hive::WorkflowPackage::Publisher.new(
      "demo", project_root: Dir.pwd, version: "1.2.3",
      submission: submission, resolver: resolver, store: store
    )

    assert package.mutation_blocked?
    assert_equal "observed", instance.publish(package)
  end

  def test_package_rejects_invalid_identity_and_nonempty_destination
    with_tmp_dir do |project|
      assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::Publisher.new("Bad Name", project_root: project, version: "1.0.0")
                                                .package(destination: File.join(project, "out"))
      end
      assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::Publisher.new("demo", project_root: project, version: "latest")
                                                .package(destination: File.join(project, "out"))
      end
      destination = File.join(project, "occupied")
      FileUtils.mkdir_p(destination)
      File.write(File.join(destination, "file"), "occupied")
      assert_raises(Hive::ConfigError) { publisher(project).package(destination: destination) }
    end
  end

  def test_package_reports_missing_and_invalid_authored_inputs
    with_authored_workflow do |project, authored_dir|
      workflows = File.dirname(authored_dir)
      descriptor = File.join(workflows, "demo.yml")
      FileUtils.rm_f(descriptor)
      assert_raises(Hive::ConfigError) do
        Dir.mktmpdir { |destination| publisher(project).package(destination: destination) }
      end
      File.write(descriptor, "id: [invalid")
      assert_raises(Hive::ConfigError) do
        Dir.mktmpdir { |destination| publisher(project).package(destination: destination) }
      end

      metadata = File.join(authored_dir, "honeycomb.yml")
      File.write(descriptor, valid_descriptor)
      FileUtils.rm_f(metadata)
      assert_raises(Hive::ConfigError) do
        Dir.mktmpdir { |destination| publisher(project).package(destination: destination) }
      end
      File.write(metadata, "summary: [invalid")
      assert_raises(Hive::ConfigError) do
        Dir.mktmpdir { |destination| publisher(project).package(destination: destination) }
      end
    end
  end

  def test_package_requires_nonempty_and_readable_readme
    with_authored_workflow do |project, authored_dir|
      readme = File.join(authored_dir, "README.md")
      File.write(readme, "  \n")
      assert_raises(Hive::ConfigError) do
        Dir.mktmpdir { |destination| publisher(project).package(destination: destination) }
      end

      File.write(readme, "# Demo\n")
      assert_raises(Hive::ConfigError) do
        Dir.mktmpdir { |destination| publisher(project).package(destination: destination) }
      end
    end
  end

  def test_prepare_revalidates_a_retained_bundle_and_asserts_authored_bytes
    with_authored_workflow do |project, authored_dir|
      with_retained_package(project) do |retained, receipt|
        store = retained_store(receipt, retained)
        instance = recovery_publisher(project, store)

        Dir.mktmpdir("publisher-rebuild-") do |destination|
          package = instance.prepare(destination: destination)

          assert_equal retained, package.root
          assert_equal receipt.package_digest, package.package_digest
          assert_equal receipt.release_digest, package.release_digest
          assert_equal receipt, instance.receipt_for(package)
        end

        FileUtils.rm_f(File.join(authored_dir, "README.md"))
        Dir.mktmpdir("publisher-no-inputs-") do |destination|
          package = instance.prepare(destination: destination)

          assert_equal retained, package.root
          assert_empty Dir.children(destination)
        end
      end
    end
  end

  def test_prepare_fails_closed_when_retained_recovery_evidence_changes
    with_authored_workflow do |project, authored_dir|
      with_retained_package(project) do |retained, receipt|
        missing_store = retained_store(nil, retained)
        error = assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          recovery_publisher(project, missing_store).prepare(destination: File.join(project, "missing"))
        end
        assert_match(/receipt disappeared/, error.message)

        changed_contract = receipt.lint_contract.merge("contract_sha256" => "f" * 64).freeze
        changed_receipt = receipt.with(lint_contract: changed_contract)
        error = assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
          recovery_publisher(project, retained_store(changed_receipt, retained))
            .prepare(destination: File.join(project, "policy"))
        end
        assert_match(/policy evidence/, error.message)

        invalid_lint = Object.new
        invalid_lint.define_singleton_method(:valid?) { false }
        with_replaced_singleton_method(
          Hive::WorkflowPackage::AuthoringLint,
          :verify,
          ->(_root, manifest:, policy:) { invalid_lint }
        ) do
          error = assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
            recovery_publisher(project, retained_store(receipt, retained))
              .prepare(destination: File.join(project, "lint"))
          end
          assert_match(/recorded lint evidence/, error.message)
        end

        File.write(File.join(authored_dir, "work.md"), "Inspect the changed task safely.\n")
        error = assert_raises(Hive::WorkflowPackage::PublishConflict) do
          recovery_publisher(project, retained_store(receipt, retained))
            .prepare(destination: File.join(project, "changed"))
        end
        assert_match(/authored workflow bytes conflict/, error.message)
      end
    end
  end

  def test_registry_configuration_is_closed_and_trusted
    valid = Hive::WorkflowPackage::Publisher.new(
      "demo", project_root: Dir.pwd, version: "1.2.3",
      config: { "honeycomb" => { "repository" => "owner/registry", "base_branch" => "release/v1" } }
    )
    assert_equal [ "owner/registry", "release/v1" ], valid.send(:publication_destination)

    [
      { "honeycomb" => { "repository" => "https://example.test/registry" } },
      { "honeycomb" => { "base_branch" => "bad..branch" } },
      { "honeycomb" => [] }
    ].each do |config|
      instance = Hive::WorkflowPackage::Publisher.new(
        "demo", project_root: Dir.pwd, version: "1.2.3", config: config
      )
      assert_raises(Hive::WorkflowPackage::PublishConfigurationError) do
        instance.send(:publication_destination)
      end
    end
  end

  def test_publication_findings_are_normalized_for_the_result_contract
    diagnostic = Hive::WorkflowPackage::Diagnostic.new(
      rule_id: "permissions.warning", severity: :warning, path: "workflow.yml",
      line: 3, column: 5, message: "review disclosure"
    )

    assert_equal(
      {
        "rule_id" => "permissions.warning", "severity" => "warning",
        "path" => "workflow.yml", "line" => 3, "column" => 5,
        "message" => "review disclosure"
      },
      publisher(Dir.pwd).send(:publication_finding, diagnostic)
    )
  end

  private

  def valid_descriptor
    <<~YAML
      id: demo
      stages:
        - name: inbox
          kind: terminal
          state_file: idea.md
        - name: work
          kind: agent
          state_file: work.md
          instruction: ./demo/work.md
          mapping_role: development
          mapping_contract: demo-work-v1
          permissions: read-only
        - name: done
          kind: terminal
          state_file: done.md
    YAML
  end

  def publisher(project)
    Hive::WorkflowPackage::Publisher.new("demo", project_root: project, version: "1.2.3")
  end

  def with_retained_package(project)
    Dir.mktmpdir("publisher-retained-") do |retained|
      package = publisher(project).package(destination: retained)
      receipt = RetainedReceipt.new(
        name: package.name, version: package.version,
        package_digest: package.package_digest, release_digest: package.release_digest,
        lint_contract: package.lint_contract
      )
      yield retained, receipt
    end
  end

  def retained_store(receipt, retained)
    Object.new.tap do |store|
      store.define_singleton_method(:load) { |_registry, _name, _version| receipt }
      store.define_singleton_method(:verify_bundle) { |_value| retained }
    end
  end

  def recovery_publisher(project, store)
    publisher = Hive::WorkflowPackage::Publisher.new(
      "demo", project_root: project, version: "1.2.3", store: store
    )
    publisher.instance_variable_set(
      :@publication_components,
      { registry: "ivankuznetsov/honeycomb", store: store, submission: nil, resolver: nil }.freeze
    )
    publisher.define_singleton_method(:retained_receipt_path?) { |_registry| true }
    publisher
  end

  def with_authored_workflow(instruction: "Inspect the task and write a concise result.\n")
    with_tmp_dir do |project|
      workflows = File.join(project, ".hive-state", "workflows")
      authored = File.join(workflows, "demo")
      FileUtils.mkdir_p(authored)
      File.write(File.join(project, ".hive-state", "config.yml"),
                 Hive::Config::DEFAULTS.merge("hive_state_path" => ".hive-state").to_yaml)
      File.write(File.join(workflows, "demo.yml"), <<~YAML)
        id: demo
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
          - name: work
            kind: agent
            state_file: work.md
            instruction: ./demo/work.md
            mapping_role: development
            mapping_contract: demo-work-v1
            permissions: read-only
          - name: done
            kind: terminal
            state_file: done.md
      YAML
      File.write(File.join(authored, "work.md"), instruction)
      File.write(File.join(authored, "README.md"), <<~MARKDOWN)
        # Demo

        ## Behavior
        Produces a concise result.
        ## Prerequisites
        Requires readable task files.
        ## Inputs
        Reads the task brief.
        ## Outputs
        Writes a concise result.
        ## Permissions and Risks
        Uses read-only file access.
        ## Recovery
        Retry from the same immutable inputs.
      MARKDOWN
      File.write(File.join(authored, "honeycomb.yml"), <<~YAML)
        description: Produce a concise result
        author:
          name: Test Author
          url: https://example.test/authors/test
        license: MIT
        hive_min_version: #{Hive::VERSION}
        source:
          url: https://example.test/source/demo
          revision: #{"a" * 40}
        assets: []
      YAML
      yield project, authored
    end
  end
end
