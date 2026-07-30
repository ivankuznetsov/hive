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

  private

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
                    unsafe_path: nil)
    trusted_lstat = lambda do |path|
      stat = File.lstat(path)
      mode =
        if stat.directory?
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
    Authority.new(
      effective_uid: -> { Process.uid },
      trusted_uid: Process.uid,
      binary_path: -> { binary },
      loaded_specs: loaded_specs || -> {
        [ Spec.new(name: "hive-cli", full_gem_path: runtime) ]
      },
      loaded_features: loaded_features,
      interpreter_path: -> { File.join(File.dirname(binary), "ruby") },
      program_path: -> { File.join(runtime, "lib", "hive.rb") },
      environment: {
        Authority::MANIFEST_ENV =>
          File.join(File.dirname(binary), "root-runtime.json")
      },
      lstat: trusted_lstat,
      require_launcher_marker: false
    )
  end
end
