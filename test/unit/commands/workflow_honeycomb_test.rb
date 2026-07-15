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

  PartialTransaction = Struct.new(:calls) do
    def apply(**kwargs)
      calls << kwargs
      Hive::Honeycomb::TransactionResult.new(changed: true, partial: true, names: [ "demo" ], commit: :committed)
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

  MultiRegistry = Struct.new(:pins, :calls) do
    def refresh!
      calls << [ :refresh ]
      true
    end

    def resolve(reference, refresh:)
      name = Hive::Honeycomb::Reference.parse(reference).name
      calls << [ :resolve, name, refresh ]
      pins.fetch(name)
    end
  end

  MultiVerifier = Struct.new(:packages, :calls) do
    def verify(pin, staging_parent:)
      calls << [ pin.name, staging_parent ]
      packages.fetch(pin.name)
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

  def test_update_renders_permission_and_full_instruction_diff_then_applies
    with_project do |project, workflows|
      old_package = update_package(workflows, body: "old line\n", sha: "1" * 40, version: "1.0.0", tools: [ "Read" ])
      install_package_fixture(workflows, old_package)
      candidate = update_package(workflows, body: "new line\nextra\n", sha: "2" * 40,
                                 version: "2.0.0", tools: %w[Read Bash])
      transaction = FakeTransaction.new([])
      out = StringIO.new

      payload = Hive::Commands::Workflow.new(
        "update", "demo", project_root: project, stdout: out, yes: true,
        registry: FakeRegistry.new(candidate.pin, nil, []), package_verifier: FakeVerifier.new(candidate, []),
        transaction: transaction
      ).call!

      assert_equal true, payload.fetch("changed")
      assert_includes out.string, "PERMISSION ESCALATION"
      assert_includes out.string, "-old line"
      assert_includes out.string, "+new line"
      assert_includes out.string, "+extra"
      assert_equal [ candidate.pin.sha ], transaction.calls.first.fetch(:installs).map { |package| package.pin.sha }
    end
  end

  def test_update_noops_for_equal_sha_and_untargeted_sha_pin
    with_project do |project, workflows|
      old_package = update_package(workflows, body: "same\n", sha: "1" * 40, version: "1.0.0", tools: [ "Read" ])
      install_package_fixture(workflows, old_package)
      transaction = FakeTransaction.new([])
      registry = FakeRegistry.new(old_package.pin, nil, [])

      equal = Hive::Commands::Workflow.new(
        "update", "demo", project_root: project, stdout: StringIO.new, yes: true,
        registry: registry, package_verifier: FakeVerifier.new(nil, []), transaction: transaction
      ).call!
      assert_equal false, equal.fetch("changed")
      assert_equal "up_to_date", equal.fetch("noops").first.fetch("reason")
      assert_empty transaction.calls

      entry = Hive::Honeycomb::LockEntry.from_verified(old_package).with(selector_kind: "sha", selector_value: old_package.pin.sha)
      Hive::Honeycomb::Lockfile.new(File.join(workflows, ".honeycomb.lock")).write("demo" => entry)
      registry.calls.clear
      pinned = Hive::Commands::Workflow.new(
        "update", "demo", project_root: project, stdout: StringIO.new,
        registry: registry, package_verifier: FakeVerifier.new(nil, []), transaction: transaction
      ).call!
      assert_equal "pinned", pinned.fetch("noops").first.fetch("reason")
      assert_empty registry.calls
    end
  end

  def test_update_all_verifies_every_candidate_and_transacts_once
    with_project do |project, workflows|
      old_demo = update_package(workflows, name: "demo", body: "d1\n", sha: "1" * 40,
                                version: "1.0.0", tools: [ "Read" ])
      old_beta = update_package(workflows, name: "beta", body: "b1\n", sha: "3" * 40,
                                version: "1.0.0", tools: [ "Read" ])
      install_package_fixture(workflows, old_demo)
      install_package_fixture(workflows, old_beta)
      new_demo = update_package(workflows, name: "demo", body: "d2\n", sha: "2" * 40,
                                version: "2.0.0", tools: [ "Read" ])
      new_beta = update_package(workflows, name: "beta", body: "b2\n", sha: "4" * 40,
                                version: "2.0.0", tools: [ "Read" ])
      registry = MultiRegistry.new({ "demo" => new_demo.pin, "beta" => new_beta.pin }, [])
      verifier = MultiVerifier.new({ "demo" => new_demo, "beta" => new_beta }, [])
      transaction = FakeTransaction.new([])

      payload = Hive::Commands::Workflow.new(
        "update", nil, project_root: project, stdout: StringIO.new, yes: true, all: true,
        registry: registry, package_verifier: verifier, transaction: transaction
      ).call!

      assert_equal true, payload.fetch("changed")
      assert_equal [ [ :refresh ], [ :resolve, "beta", false ], [ :resolve, "demo", false ] ], registry.calls
      assert_equal %w[beta demo], verifier.calls.map(&:first)
      assert_equal 1, transaction.calls.length
      assert_equal %w[beta demo], transaction.calls.first.fetch(:installs).map { |package| package.pin.name }
    end
  end

  def test_explicit_downgrade_is_previewed_and_requires_approval
    with_project do |project, workflows|
      old_package = update_package(workflows, body: "new\n", sha: "2" * 40, version: "2.0.0", tools: [ "Read" ])
      install_package_fixture(workflows, old_package)
      candidate = update_package(workflows, body: "old\n", sha: "1" * 40, version: "1.0.0", tools: [ "Read" ])
      out = StringIO.new

      error = assert_raises(Hive::Honeycomb::ApprovalError) do
        Hive::Commands::Workflow.new(
          "update", "demo@1.0.0", project_root: project, stdout: out, stdin: StringIO.new,
          registry: FakeRegistry.new(candidate.pin.with(selector_kind: "version", selector_value: "1.0.0"), nil, []),
          package_verifier: FakeVerifier.new(candidate, []), transaction: FakeTransaction.new([])
        ).call!
      end
      assert_includes error.message, "--yes"
      assert_includes out.string, "(DOWNGRADE)"
    end
  end

  def test_remove_previews_dirty_state_and_partial_cleanup_stays_nonzero
    with_project do |project, workflows|
      package = update_package(workflows, body: "managed\n", sha: "1" * 40, version: "1.0.0", tools: [ "Read" ])
      install_package_fixture(workflows, package)
      File.write(File.join(workflows, "demo", "instructions", "work.md"), "local edit\n")
      out = StringIO.new

      assert_raises(Hive::Honeycomb::CollisionError) do
        Hive::Commands::Workflow.new(
          "remove", "demo", project_root: project, stdout: out, yes: true, transaction: FakeTransaction.new([])
        ).call!
      end
      assert_includes out.string, "ownership: dirty"

      FileUtils.rm_f(File.join(workflows, ".honeycomb.lock"))
      partial = PartialTransaction.new([])
      error = assert_raises(Hive::Honeycomb::PartialRemovalError) do
        Hive::Commands::Workflow.new(
          "remove", "demo", project_root: project, stdout: StringIO.new, yes: true, force: true,
          transaction: partial
        ).call!
      end
      assert_includes error.message, "best-effort"
      assert_equal true, partial.calls.first.fetch(:allow_unknown_removals)
    end
  end

  def test_update_and_remove_json_contracts_validate
    require "json_schemer"
    with_project do |project, workflows|
      package = update_package(workflows, body: "same\n", sha: "1" * 40, version: "1.0.0", tools: [ "Read" ])
      install_package_fixture(workflows, package)
      update_out, update_err, update_status = with_captured_exit do
        Hive::Commands::Workflow.new(
          "update", "demo", project_root: project, json: true,
          registry: FakeRegistry.new(package.pin, nil, []), package_verifier: FakeVerifier.new(nil, []),
          transaction: FakeTransaction.new([])
        ).call
      end
      assert_equal 0, update_status
      assert_empty update_err
      update_payload = JSON.parse(update_out)
      update_schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-workflow-update"))))
      assert_empty update_schema.validate(update_payload).to_a

      remove_out, remove_err, remove_status = with_captured_exit do
        Hive::Commands::Workflow.new(
          "remove", "demo", project_root: project, json: true, yes: true, transaction: FakeTransaction.new([])
        ).call
      end
      assert_equal 0, remove_status
      assert_empty remove_err
      remove_payload = JSON.parse(remove_out)
      remove_schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-workflow-remove"))))
      assert_empty remove_schema.validate(remove_payload).to_a
    end
  end

  def test_update_refuses_dirty_install_and_untargeted_downgrade
    with_project do |project, workflows|
      old_package = update_package(
        workflows, body: "old\n", sha: "2" * 40, version: "2.0.0", tools: [ "Read" ]
      )
      install_package_fixture(workflows, old_package)
      File.write(File.join(workflows, "demo", "instructions", "work.md"), "dirty\n")
      candidate = update_package(
        workflows, body: "new\n", sha: "3" * 40, version: "3.0.0", tools: [ "Read" ]
      )
      assert_raises(Hive::Honeycomb::CollisionError) do
        Hive::Commands::Workflow.new(
          "update", "demo", project_root: project, stdout: StringIO.new, yes: true,
          registry: FakeRegistry.new(candidate.pin, nil, []),
          package_verifier: FakeVerifier.new(candidate, []), transaction: FakeTransaction.new([])
        ).call!
      end

      File.write(File.join(workflows, "demo", "instructions", "work.md"), "old\n")
      downgrade = update_package(
        workflows, body: "older\n", sha: "1" * 40, version: "1.0.0", tools: [ "Read" ]
      )
      assert_raises(Hive::Honeycomb::ResolutionError) do
        Hive::Commands::Workflow.new(
          "update", "demo", project_root: project, stdout: StringIO.new,
          registry: FakeRegistry.new(downgrade.pin, nil, []), transaction: FakeTransaction.new([])
        ).call!
      end
    end
  end

  def test_remove_rejects_selectors_unknown_ownership_and_corrupt_lock_is_partial
    with_project do |project, workflows|
      assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new("remove", "demo@1.0.0", project_root: project).call!
      end
      assert_raises(Hive::Honeycomb::CollisionError) do
        Hive::Commands::Workflow.new(
          "remove", "demo", project_root: project, stdout: StringIO.new, yes: true
        ).call!
      end

      root = File.join(workflows, "demo")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "workflow.yml"), "id: demo\n")
      File.write(File.join(workflows, ".honeycomb.lock"), "version: 99\n")
      assert_raises(Hive::Honeycomb::PartialRemovalError) do
        Hive::Commands::Workflow.new(
          "remove", "demo", project_root: project, stdout: StringIO.new, yes: true, force: true,
          transaction: PartialTransaction.new([])
        ).call!
      end
    end
  end

  def test_private_render_list_collision_cache_and_error_classification_paths
    with_project do |project, workflows|
      package = update_package(workflows, body: "$ echo safe\n", sha: "1" * 40,
                               version: "1.0.0", tools: [ "Read" ])
      install_package_fixture(workflows, package)
      command = Hive::Commands::Workflow.new("install", "honeycomb/demo", project_root: project, stdout: StringIO.new)
      collision = command.send(:install_collision, "demo")
      assert_equal "clean", collision.fetch("state")
      assert_equal false, collision.fetch("blocked")

      preview = command.send(:install_preview, package, collision)
      preview["findings"] = [
        { "path" => "instructions/work.md", "line" => 1, "kind" => "command_line", "high_risk" => [] }
      ]
      command.send(:render_install_preview, preview)
      assert_includes command.instance_variable_get(:@stdout).string, "instruction: instructions/work.md:1"

      tty = TtyInput.new("no\n")
      cancelling = Hive::Commands::Workflow.new(
        "remove", "demo", project_root: project, stdout: StringIO.new, stdin: tty
      )
      assert_raises(Hive::Honeycomb::ApprovalError) { cancelling.send(:approval!, "Remove") }

      sha_entry = Hive::Honeycomb::LockEntry.from_verified(package).with(selector_kind: "sha")
      other_catalog = Hive::Honeycomb::Catalog.load({
        "version" => 1,
        "workflows" => {
          "other" => {
            "latest" => "1.0.0",
            "releases" => [
              { "version" => "1.0.0", "tag" => "other/v1.0.0", "sha" => "f" * 40, "digest" => "e" * 64 }
            ]
          }
        }
      }.to_yaml)
      rows = command.send(:local_rows, { "demo" => sha_entry }, catalog: other_catalog)
      assert_equal false, rows.first.fetch("update_available")

      bad_catalog = File.join(project, "bad-catalog.yml")
      File.write(bad_catalog, "version: 99\n")
      cached = Hive::Commands::Workflow.new(
        "list", nil, project_root: project, catalog_path: bad_catalog
      )
      assert_nil cached.send(:cached_catalog)

      errors = [
        Hive::Commands::Workflow::UsageError.new("usage"),
        Hive::Honeycomb::ApprovalError.new("approval"),
        Hive::Honeycomb::CollisionError.new("collision"),
        Hive::Honeycomb::RegistryError.new("network"),
        Hive::Honeycomb::IntegrityError.new("integrity"),
        Hive::Honeycomb::LockfileError.new("lock"),
        Hive::ConcurrentRunError.new("busy"),
        Hive::GitError.new("git"),
        Hive::ConfigError.new("config"),
        Hive::InternalError.new("other")
      ]
      kinds = errors.map { |error| command.send(:error_kind_for, error) }
      assert_equal %w[usage approval collision network integrity integrity concurrent_run git config error], kinds
    end
  end

  def test_update_requires_exactly_one_target_form
    with_project do |project, _workflows|
      assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new("update", nil, project_root: project).call!
      end
      assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new("update", "demo", project_root: project, all: true).call!
      end
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


  def update_package(workflows, body:, sha:, version:, tools:, name: "demo")
    stage = Dir.mktmpdir(".honeycomb-#{name}-update-", workflows)
    FileUtils.mkdir_p(File.join(stage, "instructions"))
    File.write(File.join(stage, "instructions", "work.md"), body)
    File.write(File.join(stage, "workflow.yml"), <<~YAML)
      id: #{name}
      stages:
        - name: work
          kind: agent
          state_file: work.md
          instruction: ./instructions/work.md
          permissions:
            preset: scoped
            tools: [#{tools.join(', ')}]
        - name: done
          kind: terminal
          state_file: done.md
    YAML
    files = %w[workflow.yml instructions/work.md].to_h do |path|
      [ path, Digest::SHA256.file(File.join(stage, path)).hexdigest ]
    end
    manifest = Hive::Honeycomb::Manifest.load({
      "version" => 1, "files" => files,
      "permissions" => { "presets" => [ "scoped" ], "tools" => tools, "dirs" => [],
                           "bash" => tools.include?("Bash"), "yolo" => false }
    }.to_yaml)
    pin = Hive::Honeycomb::ResolvedPin.new(
      source: Hive::Honeycomb::SOURCE, name: name, sha: sha, version: version,
      tag: "#{name}/v#{version}", digest: manifest.package_digest, selector_kind: "latest", selector_value: nil
    )
    descriptor = Hive::Workflows::DescriptorParser.parse_file(File.join(stage, "workflow.yml"), expected_id: name)
    report = Hive::Honeycomb::SecurityReport.build(workflow: descriptor, package_root: stage)
    Hive::Honeycomb::VerifiedPackage.new(
      pin: pin, manifest: manifest, files: files.keys.to_h { |path| [ path, File.binread(File.join(stage, path)) ] },
      hashes: files, modes: files.keys.to_h { |path| [ path, "100644" ] }, descriptor: descriptor,
      security_report: report, staging_dir: stage
    )
  end

  def install_package_fixture(workflows, package)
    root = File.join(workflows, package.pin.name)
    FileUtils.rm_rf(root)
    FileUtils.mkdir_p(root)
    package.files.each do |path, bytes|
      target = File.join(root, path)
      FileUtils.mkdir_p(File.dirname(target))
      File.binwrite(target, bytes)
    end
    entry = Hive::Honeycomb::LockEntry.from_verified(package)
    lockfile = Hive::Honeycomb::Lockfile.new(File.join(workflows, ".honeycomb.lock"))
    entries = lockfile.read
    entries = entries.merge(package.pin.name => entry)
    lockfile.write(entries)
  end
end
