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

      blocked = Hive::Modules::TargetExecutor.new(first_party_loader: -> { true })
      error = assert_raises(Hive::Modules::TargetExecutor::WorkflowAdmissionUnavailable) do
        blocked.call(
          target: descriptor.hooks.first.fetch("target"), target_snapshot: snapshot,
          project: { "name" => "demo", "path" => root }, module_name: "demo",
          hook_id: "review", event: { "event_id" => "evt-1" },
          configuration: configuration
        )
      end
      assert_equal "workflow_admission_unavailable", error.reason
      assert_match(/module-pinned workflow task admission is unavailable/, error.message)
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

      capture = Hive::Modules::TargetExecutor::CommandRunner::CapturedOutput.new(
        bytes: "token=super-secret\n".b, truncated: false
      )
      output = StringIO.new
      runner.send(:emit_redacted, capture, output, [ "super-secret" ])
      assert_equal "token=[REDACTED]\n", output.string
    end
  end

  def test_command_output_capture_is_bounded_and_redacts_a_secret_crossing_the_limit
    runner = Hive::Modules::TargetExecutor::CommandRunner.new
    limit = Hive::Modules::TargetExecutor::CommandRunner::MAX_OUTPUT_BYTES
    secret = "boundary-secret"
    prefix = "x" * (limit - 5)
    capture = runner.send(:capture_bounded, StringIO.new(prefix + secret + ("y" * 32_768)))

    assert capture.truncated
    assert_operator capture.bytes.bytesize, :<=, limit + 1
    output = StringIO.new
    runner.send(:emit_redacted, capture, output, [ secret ])
    assert_operator output.string.bytesize, :<=,
                    limit + "\n[hive: module command output truncated]\n".bytesize
    assert_includes output.string, "[REDACTED]"
    refute_includes output.string, secret
    refute_includes output.string, secret.byteslice(0, 6)
    assert_includes output.string, "[hive: module command output truncated]"
  end

  def test_command_runner_concurrently_captures_and_redacts_both_streams
    runner = Hive::Modules::TargetExecutor::CommandRunner.new
    runner.define_singleton_method(:preflight!) { |grants:| grants.fetch("external_commands") }
    runner.define_singleton_method(:sandbox_argv) do |**|
      [
        RbConfig.ruby, "-e",
        "STDOUT.write('out=stream-secret'); STDERR.write('err=stream-secret')"
      ]
    end
    result = nil
    stdout, stderr = capture_io do
      result = runner.call(
        argv: [ "ignored" ], chdir: Dir.pwd, grants: permissions(
          "external_commands" => [ "ignored" ]
        ), secret_values: [ "stream-secret" ]
      )
    end

    assert_equal 0, result
    assert_equal "out=[REDACTED]", stdout
    assert_equal "err=[REDACTED]", stderr
  end

  def test_command_runner_maps_spawn_failures_to_a_closed_error
    runner = Hive::Modules::TargetExecutor::CommandRunner.new
    runner.define_singleton_method(:preflight!) { |grants:| grants }
    runner.define_singleton_method(:sandbox_argv) { |**| [ "/definitely/missing/hive-module-command" ] }

    error = assert_raises(Hive::ConfigError) do
      runner.call(argv: [ "ignored" ], chdir: Dir.pwd, grants: permissions)
    end
    assert_match(/could not start/, error.message)
  end

  def test_command_filesystem_grants_reject_symlinks_outside_the_project
    runner = Hive::Modules::TargetExecutor::CommandRunner.new
    with_tmp_dir do |root|
      project = File.join(root, "project")
      outside = File.join(root, "outside")
      FileUtils.mkdir_p([ project, outside ])
      File.symlink(outside, File.join(project, "docs"))
      grants = permissions("filesystem_read" => [ "docs/**" ])

      error = assert_raises(Hive::ConfigError) do
        runner.send(:sandbox_argv, argv: %w[git status], chdir: project, grants: grants)
      end
      assert_match(/filesystem grant escapes project/, error.message)

      logical = assert_raises(Hive::ConfigError) do
        runner.send(:confined_project_path!, outside, project)
      end
      assert_match(/filesystem grant escapes project/, logical.message)

      broken = File.join(project, "broken")
      File.symlink(File.join(root, "missing"), broken)
      unresolved = assert_raises(Hive::ConfigError) do
        runner.send(:confined_project_path!, broken, project)
      end
      assert_match(/filesystem grant cannot be resolved/, unresolved.message)
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
