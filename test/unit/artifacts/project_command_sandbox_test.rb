require "test_helper"
require "hive/artifacts/project_command_sandbox"

class ArtifactsProjectCommandSandboxTest < Minitest::Test
  include HiveTestHelper

  def test_builds_a_closed_reusable_command_boundary_and_removes_its_runtime
    Dir.mktmpdir("hive-project-command-sandbox") do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p([ source, File.join(source, "log") ])
      sandbox_binary = File.join(root, "bwrap")
      File.write(sandbox_binary, "#!/bin/sh\n")
      FileUtils.chmod(0o755, sandbox_binary)
      sandbox = Hive::Artifacts::ProjectCommandSandbox.new(
        source_root: source, sandbox_binary: sandbox_binary,
        environment: {
          "LANG" => "C.UTF-8", "DBUS_SESSION_BUS_ADDRESS" => "secret-bus",
          "SSH_AUTH_SOCK" => "secret-agent"
        },
        extra_environment: { "PORT" => "45678" }
      )

      first = sandbox.command_argv([ "/bin/true" ])
      second = sandbox.command_argv([ "/bin/false" ])
      runtime = sandbox.instance_variable_get(:@runtime_root)

      assert_equal sandbox_binary, first.first
      assert_equal "/bin/true", first.last
      assert_equal "/bin/false", second.last
      assert_includes first, "--unshare-all"
      refute_includes first, "--share-net"
      assert_includes first.each_cons(3).to_a, [ "--ro-bind", source, source ]
      log = File.join(source, "log")
      assert_includes first.each_cons(3).to_a, [ "--bind", log, log ]
      assert_includes first.each_cons(2).to_a, [ "--setenv", "PORT" ]
      refute_includes first, "secret-bus"
      refute_includes first, "secret-agent"
      assert_path_exists runtime
      assert sandbox.close
      refute_path_exists runtime
      assert sandbox.close
    end
  end

  def test_rejects_invalid_inputs_and_missing_or_changed_runtime_boundaries
    Dir.mktmpdir("hive-project-command-sandbox-invalid") do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p(source)
      sandbox_binary = File.join(root, "bwrap")
      File.write(sandbox_binary, "#!/bin/sh\n")
      FileUtils.chmod(0o755, sandbox_binary)

      assert_raises(Hive::Artifacts::ProjectCommandSandbox::SandboxError) do
        Hive::Artifacts::ProjectCommandSandbox.new(
          source_root: source, sandbox_binary: sandbox_binary,
          extra_environment: { "bad-key" => "value" }
        )
      end
      assert_raises(Hive::Artifacts::ProjectCommandSandbox::SandboxError) do
        Hive::Artifacts::ProjectCommandSandbox.new(
          source_root: File.join(root, "missing"), sandbox_binary: sandbox_binary
        )
      end

      missing = Hive::Artifacts::ProjectCommandSandbox.new(
        source_root: source, sandbox_binary: File.join(root, "missing-bwrap")
      )
      assert_raises(Hive::Artifacts::ProjectCommandSandbox::SandboxError) do
        missing.command_argv([ "/bin/true" ])
      end
      assert missing.close

      removed = Hive::Artifacts::ProjectCommandSandbox.new(
        source_root: source, sandbox_binary: sandbox_binary
      )
      removed.command_argv([ "/bin/true" ])
      FileUtils.remove_entry(removed.instance_variable_get(:@runtime_root))
      assert removed.close

      changed = Hive::Artifacts::ProjectCommandSandbox.new(
        source_root: source, sandbox_binary: sandbox_binary
      )
      changed.command_argv([ "/bin/true" ])
      runtime = changed.instance_variable_get(:@runtime_root)
      FileUtils.remove_entry(runtime)
      File.symlink(source, runtime)
      assert_raises(Hive::Artifacts::ProjectCommandSandbox::SandboxError) do
        changed.close
      end
    end
  end
end
