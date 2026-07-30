require "test_helper"
require "hive/refactor_patrol/all_users_authority"

class AllUsersAuthorityTest < Minitest::Test
  include HiveTestHelper

  Authority = Hive::RefactorPatrol::AllUsersAuthority
  Spec = Data.define(:name, :full_gem_path)

  class TrustedStat
    def initialize(stat, uid:, mode: nil)
      @stat = stat
      @uid = uid
      @mode = mode
    end

    def uid = @uid
    def mode = @mode || @stat.mode

    def method_missing(name, *args, &block)
      @stat.public_send(name, *args, &block)
    end

    def respond_to_missing?(name, include_private = false)
      @stat.respond_to?(name, include_private) || super
    end
  end

  def test_authorizes_one_snapshot_of_a_trusted_packaged_runtime
    with_runtime do |binary, runtime|
      calls = 0
      authority = authority_for(
        binary, runtime,
        loaded_specs: lambda {
          calls += 1
          [ Spec.new(name: "hive-cli", full_gem_path: runtime) ]
        }
      )

      candidate = authority.authorize!.candidate

      assert_equal File.realpath(binary), candidate.path
      assert_equal Process.uid, candidate.uid
      assert_equal 1, calls
    end
  end

  def test_default_runtime_observers_are_live
    authority = Authority.new(require_launcher_marker: false)

    assert_equal Process.euid,
                 authority.instance_variable_get(:@effective_uid).call
    assert_kind_of Array,
                   authority.instance_variable_get(:@loaded_specs).call
    assert_kind_of Array,
                   authority.instance_variable_get(:@loaded_features).call
    assert_equal RbConfig.ruby,
                 authority.instance_variable_get(:@interpreter_path).call
    assert_equal File.expand_path($PROGRAM_NAME),
                 authority.instance_variable_get(:@program_path).call
  end

  def test_verify_runtime_fails_closed_for_invalid_identity_drift_and_io
    malformed = assert_raises(Hive::ConfigError) do
      Authority.verify_runtime!(Object.new)
    end
    assert_match(/runtime identity is malformed/, malformed.message)

    with_runtime do |binary, runtime|
      identity = authority_for(binary, runtime).authorize!
      drifted = identity.with(
        interpreter: identity.interpreter.with(
          size: identity.interpreter.size + 1
        )
      )
      changed = assert_raises(Hive::ConfigError) do
        Authority.verify_runtime!(
          drifted, trusted_uid: Process.uid
        )
      end
      assert_match(/changed after authorization/, changed.message)

      unavailable = assert_raises(Hive::ConfigError) do
        Authority.verify_runtime!(
          identity,
          trusted_uid: Process.uid,
          lstat: ->(_path) { raise Errno::EIO, "runtime unavailable" }
        )
      end
      assert_match(/cannot revalidate install-wide runtime/,
                   unavailable.message)
    end
  end

  def test_production_wrapper_identity_uses_the_outer_invoked_launcher
    with_runtime do |binary, runtime|
      authority = authority_for(
        binary, runtime,
        default_binary_path: true,
        require_launcher_marker: true
      )

      runtime_identity = authority.authorize!

      assert_equal File.realpath(binary),
                   runtime_identity.candidate.path
    end
  end

  def test_authorization_requires_launcher_evidence_and_a_resolved_binary
    marker = Authority.new(
      effective_uid: -> { Process.uid },
      trusted_uid: Process.uid,
      environment: {},
      binary_path: -> { flunk("marker failure must precede binary lookup") }
    )
    error = assert_raises(Hive::ConfigError) { marker.authorize! }
    assert_match(/requires the root-owned Hive launcher/, error.message)

    unavailable = Authority.new(
      effective_uid: -> { Process.uid },
      trusted_uid: Process.uid,
      binary_path: -> { nil },
      require_launcher_marker: false,
      lstat: ->(_path) { flunk("an absent binary must not be inspected") }
    )
    error = assert_raises(Hive::UnavailableError) do
      unavailable.authorize!
    end
    assert_match(/executable is unavailable/, error.message)
  end

  def test_rejects_before_runtime_reads_without_trusted_authority
    authority = Authority.new(
      effective_uid: -> { Process.uid + 1 },
      trusted_uid: Process.uid,
      binary_path: -> { flunk("binary must not be inspected") }
    )

    error = assert_raises(Hive::ConfigError) { authority.authorize! }

    assert_match(/requires root authority/, error.message)
  end

  def test_requires_hive_cli_and_rejects_mutable_or_unreadable_runtime_entries
    with_runtime do |binary, runtime|
      missing = authority_for(
        binary, runtime,
        loaded_specs: -> {
          [ Spec.new(name: "dependency", full_gem_path: runtime) ]
        }
      )
      error = assert_raises(Hive::ConfigError) { missing.authorize! }
      assert_match(/packaged hive-cli runtime/, error.message)

      mutable = File.join(runtime, "mutable.rb")
      File.write(mutable, "puts :unsafe\n")
      FileUtils.chmod(0o666, mutable)
      authority = authority_for(binary, runtime)
      error = assert_raises(Hive::ConfigError) do
        authority.authorize!
      end
      assert_match(/not root-owned and immutable/, error.message)

      FileUtils.chmod(0o600, mutable)
      error = assert_raises(Hive::ConfigError) do
        authority.authorize!
      end
      assert_match(/not root-owned and immutable/, error.message)
    end
  end

  def test_rejects_a_user_owned_interpreter_even_when_the_gem_is_trusted
    with_runtime do |binary, runtime|
      ruby = File.join(File.dirname(binary), "ruby")
      authority = authority_for(
        binary, runtime, unsafe_path: ruby
      )

      error = assert_raises(Hive::ConfigError) do
        authority.authorize!
      end

      assert_match(/Ruby interpreter.*root-owned/i, error.message)
    end
  end

  def test_rejects_non_builtin_relative_loaded_features
    with_runtime do |binary, runtime|
      authority = authority_for(
        binary, runtime, loaded_features: -> { [ "attacker.rb" ] }
      )

      error = assert_raises(Hive::ConfigError) do
        authority.authorize!
      end

      assert_match(/loaded feature path is not absolute/, error.message)
    end
  end

  def test_loaded_feature_paths_are_captured_and_malformed_paths_are_rejected
    with_runtime do |binary, runtime|
      feature = File.join(runtime, "lib", "feature.rb")
      File.write(feature, "module Feature; end\n")
      identity = authority_for(
        binary,
        runtime,
        loaded_features: -> { [ feature ] }
      ).authorize!

      assert_instance_of Authority::RuntimeIdentity, identity

      malformed = authority_for(
        binary,
        runtime,
        loaded_features: -> { [ "bad\0feature.rb" ] }
      )
      error = assert_raises(Hive::ConfigError) do
        malformed.authorize!
      end
      assert_match(/loaded feature path is malformed/, error.message)
    end
  end

  def test_manifest_rejects_oversize_syntax_shape_and_identity_drift
    manifest_case(
      "x" * (Authority::MAX_MANIFEST_BYTES + 1),
      /exceeds its size limit/
    )
    manifest_case("{", /manifest is malformed/)
    manifest_case("null", /manifest is malformed/)
    manifest_case(JSON.generate("scalar"), /manifest is malformed/)
    manifest_case(JSON.generate({}), /manifest is malformed/)

    with_runtime do |binary, runtime|
      path = File.join(File.dirname(binary), "root-runtime.json")
      payload = JSON.parse(File.binread(path))
      payload["launcher"] = File.join(File.dirname(binary), "other-hive")
      File.binwrite(path, JSON.generate(payload))

      error = assert_raises(Hive::ConfigError) do
        authority_for(binary, runtime).authorize!
      end
      assert_match(/does not match the loaded runtime/, error.message)
    end
  end

  def test_runtime_custody_rejects_io_non_directory_and_replaceable_ancestors
    with_tmp_dir do |root|
      missing = Authority.new(
        effective_uid: -> { Process.uid },
        trusted_uid: Process.uid,
        binary_path: -> { File.join(root, "missing-hive") },
        require_launcher_marker: false
      )
      error = assert_raises(Hive::ConfigError) { missing.authorize! }
      assert_match(/cannot validate hive executable/, error.message)
    end

    with_runtime do |binary, runtime|
      missing_runtime = File.join(runtime, "missing-runtime")
      authority = authority_for(
        binary,
        runtime,
        loaded_specs: -> {
          [ Spec.new(name: "hive-cli", full_gem_path: missing_runtime) ]
        }
      )
      error = assert_raises(Hive::ConfigError) { authority.authorize! }
      assert_match(/cannot validate install-wide migration runtime/,
                   error.message)
    end

    with_runtime do |binary, runtime|
      authority = authority_for(
        binary,
        runtime,
        loaded_specs: -> {
          [ Spec.new(name: "hive-cli", full_gem_path: binary) ]
        }
      )
      error = assert_raises(Hive::ConfigError) { authority.authorize! }
      assert_match(/runtime root.*directory/i, error.message)
    end

    with_runtime do |binary, runtime|
      authority = authority_for(
        binary,
        runtime,
        mode_overrides: {
          File.dirname(binary) => 0o777
        }
      )
      error = assert_raises(Hive::ConfigError) { authority.authorize! }
      assert_match(/replaceable ancestor/, error.message)
    end
  end

  def test_runtime_tree_entry_limit_fails_at_the_boundary
    with_runtime do |binary, runtime|
      authority = authority_for(binary, runtime)

      error = assert_raises(Hive::ConfigError) do
        authority.send(
          :validate_runtime_tree!,
          runtime,
          count: Authority::MAX_RUNTIME_ENTRIES
        )
      end

      assert_match(/runtime tree is unbounded/, error.message)
    end
  end

  private

  def manifest_case(bytes, message)
    with_runtime do |binary, runtime|
      File.binwrite(
        File.join(File.dirname(binary), "root-runtime.json"),
        bytes
      )
      error = assert_raises(Hive::ConfigError) do
        authority_for(binary, runtime).authorize!
      end
      assert_match message, error.message
    end
  end

  def with_runtime
    with_tmp_dir do |root|
      runtime = File.join(root, "runtime")
      FileUtils.mkdir_p(File.join(runtime, "lib"))
      File.write(File.join(runtime, "lib", "hive.rb"), "module Hive; end\n")
      binary = File.join(root, "hive")
      File.write(binary, "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, binary)
      ruby = File.join(root, "ruby")
      File.write(ruby, "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, ruby)
      manifest = File.join(root, "root-runtime.json")
      File.write(
        manifest,
        JSON.generate(
          "gem_home" => root,
          "launcher" => binary,
          "ruby" => ruby,
          "schema" => "hive-root-runtime",
          "schema_version" => 1,
          "script" => File.join(runtime, "lib", "hive.rb")
        )
      )
      yield binary, runtime
    end
  end

  def authority_for(binary, runtime, loaded_specs: nil,
                    loaded_features: -> { [] },
                    unsafe_path: nil, default_binary_path: false,
                    require_launcher_marker: false,
                    mode_overrides: {})
    trusted_lstat = lambda do |path|
      stat = File.lstat(path)
      mode =
        if mode_overrides.key?(File.expand_path(path))
          (stat.mode & ~0o777) |
            mode_overrides.fetch(File.expand_path(path))
        elsif stat.directory?
          (stat.mode & ~0o777) | 0o755
        elsif File.expand_path(path) == File.expand_path(binary)
          (stat.mode & ~0o777) | 0o755
        else
          stat.mode
        end
      uid =
        File.expand_path(path) == File.expand_path(unsafe_path.to_s) ?
          Process.uid + 1 : Process.uid
      TrustedStat.new(stat, uid: uid, mode: mode)
    end
    options = {
      effective_uid: -> { Process.uid },
      trusted_uid: Process.uid,
      loaded_specs: loaded_specs || -> {
        [ Spec.new(name: "hive-cli", full_gem_path: runtime) ]
      },
      loaded_features: loaded_features,
      interpreter_path: -> { File.join(File.dirname(binary), "ruby") },
      program_path: -> { File.join(runtime, "lib", "hive.rb") },
      environment: {
        Hive::InvokedBinary::ENV_KEY => binary,
        Authority::LAUNCHER_MARKER => "1",
        Authority::MANIFEST_ENV =>
          File.join(File.dirname(binary), "root-runtime.json")
      },
      lstat: trusted_lstat,
      require_launcher_marker: require_launcher_marker
    }
    options[:binary_path] = -> { binary } unless default_binary_path
    Authority.new(**options)
  end
end
