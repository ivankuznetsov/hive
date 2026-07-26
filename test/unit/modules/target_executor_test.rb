require "test_helper"
require_relative "../../support/module_helpers"
require "hive/module_package/configuration"
require "hive/modules/target_executor"

class ModulesTargetExecutorTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

  def teardown
    Hive::Modules::Entrypoints.reset!
    super
  end

  def test_dispatches_entrypoints_and_commands_through_explicit_boundaries
    with_tmp_dir do |root|
      entrypoint_calls = []
      command_calls = []
      Hive::Modules::Entrypoints.register("demo.run") { |context| entrypoint_calls << context; 7 }
      executor = Hive::Modules::TargetExecutor.new(
        first_party_loader: -> { true },
        command_runner: lambda do |argv:, chdir:, environment:, grants:, secret_values:|
          assert_empty environment
          assert_empty secret_values
          assert_equal [ "git" ], grants.fetch("external_commands")
          command_calls << [ argv, chdir ]
          9
        end
      )
      project = { "name" => "demo", "path" => root, "project_id" => "project-1" }
      event = { "event_id" => "evt-1", "event_name" => "task.completed" }

      assert_equal 7, executor.call(
        target: { "kind" => "entrypoint", "id" => "demo.run" },
        target_snapshot: { "kind" => "entrypoint", "id" => "demo.run" },
        project: project, module_name: "demo", hook_id: "task",
        event: event, configuration: configuration_for(root)
      )

      command_configuration = configuration_for(
        root,
        hooks: [ hook("command", "git status --short") ],
        permissions: permissions("external_commands" => [ "git" ])
      )
      assert_equal 9, executor.call(
        target: { "kind" => "command", "id" => "git status --short" },
        target_snapshot: {
          "kind" => "command", "id" => "git status --short",
          "argv" => [ "git", "status", "--short" ]
        },
        project: project, module_name: "demo", hook_id: "task",
        event: event, configuration: command_configuration
      )
      assert_equal [ [ %w[git status --short], root ] ], command_calls
      assert_equal 1, entrypoint_calls.length
    end
  end

  def test_command_requires_the_exact_executable_grant_and_never_uses_a_shell
    with_tmp_dir do |root|
      calls = []
      configuration = configuration_for(
        root,
        hooks: [ hook("command", "bin/check --safe") ],
        permissions: permissions("external_commands" => [ "bin/check" ])
      )
      executor = Hive::Modules::TargetExecutor.new(
        first_party_loader: -> { true },
        command_runner: ->(**values) { calls << values; 0 }
      )

      executor.call(
        target: { "kind" => "command", "id" => "bin/check --safe" },
        target_snapshot: {
          "kind" => "command", "id" => "bin/check --safe",
          "argv" => [ "bin/check", "--safe" ]
        },
        project: { "name" => "demo", "path" => root }, module_name: "demo",
        hook_id: "task", event: {}, configuration: configuration
      )
      assert_equal 1, calls.length
      assert_equal [ "bin/check", "--safe" ], calls.fetch(0).fetch(:argv)

      denied_data = configuration.to_h
      denied_data["contract"]["hooks"].first["target"] = {
        "kind" => "command", "id" => "other/check --safe"
      }
      denied_data["contract_digest"] = Digest::SHA256.hexdigest(
        Hive::WorkflowPackage::CanonicalJSON.generate(denied_data.fetch("contract"))
      )
      denied = Hive::ModulePackage::Configuration.new(denied_data)
      assert_raises(Hive::Modules::CapabilityDenied) do
        executor.call(
          target: { "kind" => "command", "id" => "other/check --safe" },
          target_snapshot: {
            "kind" => "command", "id" => "other/check --safe",
            "argv" => [ "other/check", "--safe" ]
          },
          project: { "name" => "demo", "path" => root }, module_name: "demo",
          hook_id: "task", event: {}, configuration: denied
        )
      end
      assert_equal 1, calls.length
    end
  end

  def test_workflow_snapshot_is_declarative_and_routes_only_through_injected_admission
    with_workflow_package do |root, resolution, descriptor|
      configuration = Hive::ModulePackage::Configuration.build(
        descriptor, generation: resolution, settings: {}, hooks: { "review" => true },
        grants: exact_grants(descriptor)
      )
      snapshot = Hive::Modules::TargetExecutor.capture_snapshot(
        target: descriptor.hooks.first.fetch("target"),
        configuration: configuration, package_root: root
      )
      calls = []
      executor = Hive::Modules::TargetExecutor.new(
        first_party_loader: -> { true },
        workflow_runner: lambda do |**values|
          calls << values.merge(descriptor_exists: File.file?(values.fetch(:descriptor_path)))
          11
        end
      )

      assert_equal 11, executor.call(
        target: descriptor.hooks.first.fetch("target"), target_snapshot: snapshot,
        project: { "name" => "demo", "path" => root }, module_name: "demo",
        hook_id: "review", event: { "event_id" => "evt-1" },
        configuration: configuration
      )
      assert_equal 1, calls.length
      assert_equal :review, calls.fetch(0).fetch(:workflow).id
      assert calls.fetch(0).fetch(:descriptor_exists)

      state = File.join(root, ".hive-state")
      admitted = []
      fake_command = Object.new
      fake_command.define_singleton_method(:call!) { admitted << true }
      replacement = lambda do |*args, **options|
        admitted << [ args, options ]
        fake_command
      end
      default_executor = Hive::Modules::TargetExecutor.new(first_party_loader: -> { true })
      with_replaced_singleton_method(Hive::Commands::New, :new, replacement) do
        assert_equal 0, default_executor.call(
          target: descriptor.hooks.first.fetch("target"), target_snapshot: snapshot,
          project: { "name" => "demo", "path" => root, "hive_state_path" => state },
          module_name: "demo", hook_id: "review",
          event: { "event_id" => "evt-1", "event_name" => "task.completed" },
          configuration: configuration
        )
      end
      assert_equal "demo", admitted.fetch(0).fetch(0).fetch(0)
      assert_match(/\Amodule-demo-review-/, admitted.fetch(0).fetch(1).fetch(:workflow))
      workflow_path = File.join(
        state, "workflows", "#{admitted.fetch(0).fetch(1).fetch(:workflow)}.yml"
      )
      assert File.file?(workflow_path)
      assert_equal admitted.fetch(0).fetch(1).fetch(:workflow),
                   YAML.safe_load(File.read(workflow_path)).fetch("id")
    end
  end

  def test_health_check_is_structural_and_side_effect_free
    with_workflow_package do |root, resolution, descriptor|
      configuration = Hive::ModulePackage::Configuration.build(
        descriptor, generation: resolution, settings: {}, hooks: { "review" => true },
        grants: exact_grants(descriptor)
      )
      executor = Hive::Modules::TargetExecutor.new(first_party_loader: -> { true })

      assert executor.health_check.call(root, configuration)
    end
  end

  def test_command_health_rejects_an_unavailable_sandbox_runtime
    runner = Object.new
    runner.define_singleton_method(:preflight!) do |grants:|
      raise Hive::ConfigError, "module command targets require bubblewrap"
    end
    with_tmp_dir do |root|
      configuration = configuration_for(
        root, hooks: [ hook("command", "git status") ],
        permissions: permissions("external_commands" => [ "git" ])
      )
      executor = Hive::Modules::TargetExecutor.new(
        first_party_loader: -> { true }, command_runner: runner
      )

      error = assert_raises(Hive::ConfigError) do
        executor.health_check.call(root, configuration)
      end
      assert_match(/require bubblewrap/, error.message)
    end
  end

  def test_command_sandbox_binds_only_granted_project_paths_and_redacts_output
    runner = Hive::Modules::TargetExecutor::CommandRunner.new
    with_tmp_dir do |root|
      readable = File.join(root, "docs")
      writable = File.join(root, ".hive-state", "module")
      FileUtils.mkdir_p(readable)
      FileUtils.mkdir_p(writable)
      grants = permissions(
        "external_commands" => [ "git" ],
        "filesystem_read" => [ "docs/**" ],
        "filesystem_write" => [ ".hive-state/module/**" ]
      )
      argv = runner.send(:sandbox_argv, argv: %w[git status], chdir: root, grants: grants)

      refute_includes argv.each_cons(3).to_a, [ "--ro-bind", "/", "/" ]
      assert_includes argv.each_cons(3).to_a, [ "--ro-bind", readable, readable ]
      assert_includes argv.each_cons(3).to_a, [ "--bind", writable, writable ]
      refute_includes argv, "--share-net"

      Tempfile.create("redaction") do |file|
        file.write("token=super-secret\n")
        output = StringIO.new
        runner.send(:emit_redacted, file, output, [ "super-secret" ])
        assert_equal "token=[REDACTED]\n", output.string
      end
    end
  end

  def test_exact_network_allowlist_fails_activation_until_enforceable
    runner = Hive::Modules::TargetExecutor::CommandRunner.new
    grants = permissions("network_hosts" => [ "api.example.test" ])

    error = assert_raises(Hive::ConfigError) { runner.preflight!(grants: grants) }
    assert_match(/host allowlists/, error.message)
    assert runner.preflight!(grants: grants.merge("network_hosts" => [ "*" ]))
  end

  private

  def hook(kind, id)
    {
      "id" => "task", "target" => { "kind" => kind, "id" => id },
      "default_enabled" => true, "schedules" => [],
      "events" => [ "task.completed" ], "concurrency" => "drop"
    }
  end

  def permissions(overrides = {})
    {
      "repository_write" => false, "github_mutations" => [], "external_commands" => [],
      "network_hosts" => [], "filesystem_read" => [], "filesystem_write" => [], "secrets" => []
    }.merge(overrides)
  end

  def configuration_for(root, hooks: [ hook("entrypoint", "demo.run") ],
                        permissions: permissions)
    package = File.join(root, "package-#{hooks.first.dig('target', 'kind')}-#{hooks.first.dig('target', 'id').hash.abs}")
    resolution, descriptor = write_module_package(
      package, hooks: hooks, settings: [], permissions: permissions
    )
    Hive::ModulePackage::Configuration.build(
      descriptor, generation: resolution, settings: {}, hooks: { "task" => true },
      grants: exact_grants(descriptor)
    )
  end

  def with_workflow_package
    with_tmp_dir do |root|
      File.write(File.join(root, "review.yml"), <<~YAML)
        id: review
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
      YAML
      document = {
        "schema" => "hive-module/v1", "name" => "demo", "version" => "1.0.0",
        "description" => "Demo module", "type" => "workflow",
        "author" => { "name" => "Hive", "url" => "https://hivecli.sh" }, "license" => "MIT",
        "hive_min_version" => "0.6.7",
        "source" => { "url" => "https://example.test/demo", "revision" => "a" * 40 },
        "workflows" => [ { "id" => "review", "descriptor" => "review.yml" } ],
        "hooks" => [ hook("workflow", "review").merge("id" => "review") ],
        "settings" => [], "permissions" => permissions, "templates" => [], "docs" => [],
        "files" => { "review.yml" => Digest::SHA256.file(File.join(root, "review.yml")).hexdigest }
      }
      document["release_sha256"] = Digest::SHA256.hexdigest(
        Hive::WorkflowPackage::CanonicalYAML.dump(document)
      )
      File.binwrite(
        File.join(root, "module.yml"),
        Hive::WorkflowPackage::CanonicalYAML.dump(document)
      )
      result = Hive::ModulePackage::Validator.validate!(root, catalog_commit: "a" * 40)
      resolution = Hive::ModulePackage::CatalogClient::Resolution.new(
        name: "demo", version: "1.0.0", type: "workflow",
        source_commit: "a" * 40, catalog_commit: "a" * 40,
        source_revision: "a" * 40, manifest_digest: result.manifest_digest,
        summary: "Demo module", package_path: "modules/demo/1.0.0",
        descriptor: result.descriptor
      )
      yield root, resolution, result.descriptor
    end
  end
end
