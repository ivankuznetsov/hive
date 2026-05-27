require "test_helper"
require "hive/invoked_binary"

class InvokedBinaryTest < Minitest::Test
  include HiveTestHelper

  def write_executable(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\n")
    FileUtils.chmod(0o755, path)
    path
  end

  def test_prefers_executable_wrapper_path_from_environment
    with_tmp_dir do |dir|
      wrapper = write_executable(File.join(dir, "bin", "hive"))
      shim = File.join(dir, "gems", "shims", "hive")
      env = { "HIVE_INVOKED_BIN" => wrapper, "PATH" => "" }

      assert_equal wrapper, Hive::InvokedBinary.path(program_name: shim, env: env)
    end
  end

  def test_ignores_invalid_wrapper_path_and_resolves_invoked_hv_from_path
    with_tmp_dir do |dir|
      apache = write_executable(File.join(dir, "apache", "hive"))
      hv = write_executable(File.join(dir, "hive", "hv"))
      env = {
        "HIVE_INVOKED_BIN" => File.join(dir, "missing", "hive"),
        "PATH" => [ File.dirname(apache), File.dirname(hv) ].join(File::PATH_SEPARATOR)
      }

      assert_equal hv, Hive::InvokedBinary.path(program_name: "hv", env: env)
      assert_nil Hive::InvokedBinary.which("missing-hive", env: env)
    end
  end

  def test_absolute_hive_and_hv_program_paths_are_preserved
    assert_equal "/opt/hive/bin/hive",
                 Hive::InvokedBinary.path(program_name: "/opt/hive/bin/hive", env: { "PATH" => "" })
    assert_equal "/opt/hive/bin/hv",
                 Hive::InvokedBinary.path(program_name: "/opt/hive/bin/hv", env: { "PATH" => "" })
  end

  def test_unknown_program_and_non_path_wrapper_return_nil
    env = { "HIVE_INVOKED_BIN" => "hive", "PATH" => "" }

    assert_nil Hive::InvokedBinary.path(program_name: "ruby", env: env)
  end

  def test_non_executable_wrapper_is_rejected_and_falls_back_to_path
    with_tmp_dir do |dir|
      # Wrapper exists but is not chmod +x — must not be trusted, since
      # a non-runnable path baked into a daemon unit would fail at boot.
      wrapper = File.join(dir, "bin", "hive")
      FileUtils.mkdir_p(File.dirname(wrapper))
      File.write(wrapper, "#!/bin/sh\n")
      FileUtils.chmod(0o644, wrapper)
      on_path = write_executable(File.join(dir, "path", "hive"))
      env = { "HIVE_INVOKED_BIN" => wrapper, "PATH" => File.dirname(on_path) }

      assert_equal on_path, Hive::InvokedBinary.path(program_name: "hive", env: env)
    end
  end

  def test_wrapper_with_disallowed_basename_is_rejected
    with_tmp_dir do |dir|
      # A valid path to an executable, but named neither hive nor hv —
      # the VALID_NAMES gate must refuse it.
      ruby_like = write_executable(File.join(dir, "bin", "ruby"))
      env = { "HIVE_INVOKED_BIN" => ruby_like, "PATH" => "" }

      assert_nil Hive::InvokedBinary.path(program_name: "ruby", env: env)
    end
  end

  def test_valid_name_with_empty_path_resolves_to_nil
    env = { "HIVE_INVOKED_BIN" => "", "PATH" => "" }

    assert_nil Hive::InvokedBinary.path(program_name: "hive", env: env)
  end

  def test_relative_program_name_expands_against_cwd
    # A relative $PROGRAM_NAME like ./bin/hive is expanded against the
    # current working directory. Pinned deliberately so the behavior is
    # an explicit choice, not an accident.
    with_tmp_dir do |dir|
      Dir.chdir(dir) do
        env = { "HIVE_INVOKED_BIN" => "", "PATH" => "" }
        assert_equal File.join(dir, "bin", "hive"),
                     Hive::InvokedBinary.path(program_name: "./bin/hive", env: env)
      end
    end
  end
end
