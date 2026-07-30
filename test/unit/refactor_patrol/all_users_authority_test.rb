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

      candidate = authority.authorize!

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

  private

  def with_runtime
    with_tmp_dir do |root|
      runtime = File.join(root, "runtime")
      FileUtils.mkdir_p(File.join(runtime, "lib"))
      File.write(File.join(runtime, "lib", "hive.rb"), "module Hive; end\n")
      binary = File.join(root, "hive")
      File.write(binary, "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, binary)
      yield binary, runtime
    end
  end

  def authority_for(binary, runtime, loaded_specs: nil)
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
      TrustedStat.new(stat, uid: Process.uid, mode: mode)
    end
    Authority.new(
      effective_uid: -> { Process.uid },
      trusted_uid: Process.uid,
      binary_path: -> { binary },
      loaded_specs: loaded_specs || -> {
        [ Spec.new(name: "hive-cli", full_gem_path: runtime) ]
      },
      lstat: trusted_lstat
    )
  end
end
