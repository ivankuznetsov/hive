require "test_helper"
require "digest"
require "hive/commands/workflow"
require "hive/honeycomb/lockfile"

class WorkflowHoneycombTest < Minitest::Test
  include HiveTestHelper

  TtyInput = Class.new(StringIO) do
    def tty? = true
  end

  FakeTransaction = Struct.new(:calls) do
    def apply(**kwargs)
      calls << kwargs
      Hive::Honeycomb::TransactionResult.new(changed: true, partial: false, names: [ "demo" ], commit: :committed)
    end
  end

  FakeRegistry = Struct.new(:pin, :catalog_value, :calls) do
    def resolve(reference, refresh:)
      calls << [ :resolve, reference, refresh ]
      pin
    end

    def refresh!
      calls << [ :refresh ]
      catalog_value
    end
  end

  FakeVerifier = Struct.new(:package, :calls) do
    def verify(pin, staging_parent:)
      calls << [ pin, staging_parent ]
      package
    end
  end

  def test_install_previews_before_interactive_confirmation_and_applies
    package = nil
    with_project do |project, workflows|
      package = verified_package(workflows)
      registry = FakeRegistry.new(package.pin, nil, [])
      verifier = FakeVerifier.new(package, [])
      transaction = FakeTransaction.new([])
      out = StringIO.new

      payload = Hive::Commands::Workflow.new(
        "install", "honeycomb/demo", project_root: project, stdout: out, stdin: TtyInput.new("y\n"),
        registry: registry, package_verifier: verifier, transaction: transaction
      ).call!

      assert_equal true, payload.fetch("changed")
      assert_includes out.string, "source: github.com/ivankuznetsov/honeycomb"
      assert_includes out.string, "immutable sha: #{package.pin.sha}"
      assert_includes out.string, "shell-capable: no"
      assert_equal true, transaction.calls.first.fetch(:installs).one?
    end
  ensure
    FileUtils.rm_rf(package&.staging_dir)
  end

  def test_non_tty_install_without_yes_prints_preview_and_never_transacts
    with_project do |project, workflows|
      package = verified_package(workflows)
      transaction = FakeTransaction.new([])
      out = StringIO.new
      command = Hive::Commands::Workflow.new(
        "install", "honeycomb/demo", project_root: project, stdout: out, stdin: StringIO.new,
        registry: FakeRegistry.new(package.pin, nil, []), package_verifier: FakeVerifier.new(package, []),
        transaction: transaction
      )

      error = assert_raises(Hive::Honeycomb::ApprovalError) { command.call! }
      assert_includes error.message, "--yes"
      assert_includes out.string, "Install honeycomb/demo"
      assert_empty transaction.calls
    end
  end

  def test_list_is_local_and_does_not_touch_registry
    with_project do |project, workflows|
      root = File.join(workflows, "demo")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "workflow.yml"), "demo\n")
      hash = Digest::SHA256.file(File.join(root, "workflow.yml")).hexdigest
      write_lock(workflows, hash: hash)
      registry = Object.new
      registry.define_singleton_method(:method_missing) { |name, *| raise "network collaborator called: #{name}" }
      out = StringIO.new

      payload = Hive::Commands::Workflow.new(
        "list", nil, project_root: project, stdout: out, registry: registry,
        catalog_path: File.join(project, "missing-catalog.yml")
      ).call!

      row = payload.fetch("workflows").first
      assert_equal "demo", row.fetch("name")
      assert_nil row.fetch("update_available")
      assert_equal "clean", row.fetch("integrity")
      assert_includes out.string, "unknown"
      assert_includes out.string, "workflows/.honeycomb.lock#workflows.demo.security"
    end
  end

  def test_remote_and_outdated_modes_refresh_explicitly
    with_project do |project, workflows|
      current = "1" * 40
      latest = "2" * 40
      root = File.join(workflows, "demo")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "workflow.yml"), "demo\n")
      write_lock(workflows, hash: Digest::SHA256.file(File.join(root, "workflow.yml")).hexdigest, sha: current)
      catalog = Hive::Honeycomb::Catalog.load({
        "version" => 1,
        "workflows" => {
          "demo" => {
            "latest" => "2.0.0",
            "releases" => [
              { "version" => "2.0.0", "tag" => "demo/v2.0.0", "sha" => latest, "digest" => "e" * 64 }
            ]
          }
        }
      }.to_yaml)
      registry = FakeRegistry.new(nil, catalog, [])

      remote = Hive::Commands::Workflow.new(
        "list", nil, project_root: project, stdout: StringIO.new, registry: registry, remote: true
      ).call!
      outdated = Hive::Commands::Workflow.new(
        "list", nil, project_root: project, stdout: StringIO.new, registry: registry, outdated: true
      ).call!

      assert_equal "2.0.0", remote.fetch("workflows").first.fetch("version")
      assert_equal [ "demo" ], outdated.fetch("workflows").map { |row| row.fetch("name") }
      assert_equal [ [ :refresh ], [ :refresh ] ], registry.calls
    end
  end

  def test_rejects_invalid_subcommand_flag_combinations
    with_project do |project, _workflows|
      assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new("list", nil, project_root: project, remote: true, outdated: true).call!
      end
      assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new("install", nil, project_root: project).call!
      end
      assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new("new", "demo", project_root: project, yes: true).call!
      end
    end
  end

  def test_install_and_list_json_payloads_validate_against_published_schemas
    require "json_schemer"
    with_project do |project, workflows|
      package = verified_package(workflows)
      install_out, install_err, install_status = with_captured_exit do
        Hive::Commands::Workflow.new(
          "install", "honeycomb/demo", project_root: project, json: true, yes: true,
          registry: FakeRegistry.new(package.pin, nil, []), package_verifier: FakeVerifier.new(package, []),
          transaction: FakeTransaction.new([])
        ).call
      end
      assert_equal Hive::ExitCodes::SUCCESS, install_status
      assert_empty install_err
      install_payload = JSON.parse(install_out)
      install_schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-workflow-install"))))
      assert_empty install_schema.validate(install_payload).to_a

      list_out, list_err, list_status = with_captured_exit do
        Hive::Commands::Workflow.new(
          "list", nil, project_root: project, json: true, catalog_path: File.join(project, "none.yml")
        ).call
      end
      assert_equal Hive::ExitCodes::SUCCESS, list_status
      assert_empty list_err
      list_payload = JSON.parse(list_out)
      list_schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-workflow-list"))))
      assert_empty list_schema.validate(list_payload).to_a
    end
  end

  private

  def with_project
    with_tmp_dir do |project|
      workflows = File.join(project, ".hive-state", "workflows")
      FileUtils.mkdir_p(workflows)
      yield project, workflows
    end
  end

  def verified_package(workflows)
    stage = Dir.mktmpdir(".honeycomb-demo-", workflows)
    File.write(File.join(stage, "workflow.yml"), <<~YAML)
      id: demo
      stages:
        - name: done
          kind: terminal
          state_file: done.md
    YAML
    hash = Digest::SHA256.file(File.join(stage, "workflow.yml")).hexdigest
    manifest = Hive::Honeycomb::Manifest.load({ "version" => 1, "files" => { "workflow.yml" => hash } }.to_yaml)
    pin = Hive::Honeycomb::ResolvedPin.new(
      source: Hive::Honeycomb::SOURCE, name: "demo", sha: "1" * 40, version: "1.0.0",
      tag: "demo/v1.0.0", digest: manifest.package_digest, selector_kind: "latest", selector_value: nil
    )
    descriptor = Hive::Workflows::DescriptorParser.parse_file(File.join(stage, "workflow.yml"), expected_id: "demo")
    report = Hive::Honeycomb::SecurityReport.build(workflow: descriptor, package_root: stage)
    Hive::Honeycomb::VerifiedPackage.new(
      pin: pin, manifest: manifest, files: { "workflow.yml" => File.binread(File.join(stage, "workflow.yml")) },
      hashes: { "workflow.yml" => hash }, modes: { "workflow.yml" => "100644" }, descriptor: descriptor,
      security_report: report, staging_dir: stage
    )
  end

  def write_lock(workflows, hash:, sha: "1" * 40)
    entry = Hive::Honeycomb::LockEntry.new(
      source: Hive::Honeycomb::SOURCE, name: "demo", sha: sha, version: "1.0.0", tag: "demo/v1.0.0",
      selector_kind: "latest", selector_value: nil, digest: "d" * 64,
      files: { "workflow.yml" => hash }, modes: { "workflow.yml" => "100644" },
      security: { "summary" => { "presets" => [], "tools" => [], "dirs" => [], "bash" => false,
                                   "yolo" => false, "shell_capable" => false, "locations" => [] },
                  "findings" => [] }
    )
    Hive::Honeycomb::Lockfile.new(File.join(workflows, ".honeycomb.lock")).write("demo" => entry)
  end
end
