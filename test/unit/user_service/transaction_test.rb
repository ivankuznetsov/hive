require "test_helper"
require "hive/user_service/definition"
require "hive/user_service/transaction"

class UserServiceTransactionTest < Minitest::Test
  include HiveTestHelper

  def test_missing_home_is_rejected
    with_tmp_dir do |dir|
      error = assert_raises(Hive::UserService::Transaction::Unsafe) do
        build_transaction(File.join(dir, "missing"))
      end

      assert_match(/home is unavailable: Errno::ENOENT/, error.message)
    end
  end

  def test_target_and_coordination_root_must_share_the_same_real_home
    with_tmp_dir do |root|
      target_home = File.join(root, "target-home")
      foreign_home = File.join(root, "foreign-home")
      FileUtils.mkdir_p(target_home)
      FileUtils.mkdir_p(foreign_home)
      definition = Hive::UserService::Definition.new(
        platform: :linux,
        service_name: "hive-test",
        target_path: File.join(target_home, ".config/systemd/user/hive-test.service"),
        content: "desired\n"
      )

      error = assert_raises(Hive::UserService::Transaction::Unsafe) do
        Hive::UserService::Transaction.new(
          definition: definition,
          home: foreign_home
        )
      end

      assert_match(/not anchored to its real home/, error.message)
    end
  end

  def test_foreign_writable_coordination_directory_is_rejected
    with_tmp_dir do |dir|
      state = File.join(dir, ".local", "state")
      FileUtils.mkdir_p(state)
      File.chmod(0o777, state)
      transaction = build_transaction(dir)

      error = assert_raises(Hive::UserService::Transaction::Unsafe) do
        transaction.with_lock { flunk "unsafe root must not be entered" }
      end

      assert_match(/unsafe user-service coordination directory/, error.message)
    end
  end

  def test_unavailable_coordination_directory_is_rejected
    with_tmp_dir do |dir|
      transaction = build_transaction(dir)
      original = File.method(:lstat)
      failing = lambda do |path|
        raise Errno::EACCES if path == File.join(dir, ".local")

        original.call(path)
      end

      error = with_replaced_singleton_method(File, :lstat, failing) do
        assert_raises(Hive::UserService::Transaction::Unsafe) do
          transaction.with_lock { flunk "unavailable root must not be entered" }
        end
      end

      assert_match(/unavailable user-service coordination directory/, error.message)
    end
  end

  def test_unsafe_lock_metadata_is_rejected
    with_tmp_dir do |dir|
      transaction = build_transaction(dir)
      transaction.with_lock { nil }
      File.chmod(0o644, transaction.lock_path)

      error = assert_raises(Hive::UserService::Transaction::Unsafe) do
        transaction.with_lock { flunk "unsafe lock must not be entered" }
      end

      assert_match(/unsafe user-service lock file/, error.message)
    end
  end

  def test_coordination_root_and_target_lock_are_created_under_a_bootstrap_fence
    with_tmp_dir do |dir|
      first = build_transaction(dir)
      second = build_transaction(dir)

      entered = Queue.new
      release = Queue.new
      owner = Thread.new do
        first.with_lock do
          entered << true
          release.pop
        end
      end
      entered.pop

      error = assert_raises(Hive::UserService::Transaction::Busy) do
        second.with_lock { flunk "contender must not enter" }
      end
      assert_match(/target is busy/, error.message)
      assert_equal first.lock_path, second.lock_path
      bootstrap = File.join(dir, ".hive-user-service-bootstrap.lock")
      assert File.file?(bootstrap)
      assert_equal 0o600, File.stat(bootstrap).mode & 0o777
      assert_equal 0o700, File.stat(first.root).mode & 0o777
    ensure
      release << true if owner&.alive?
      owner&.join
    end
  end

  def test_lock_path_replacement_while_owned_fails_closed
    with_tmp_dir do |dir|
      transaction = build_transaction(dir)
      replacement = "foreign evidence\n"

      error = assert_raises(Hive::UserService::Transaction::Unsafe) do
        transaction.with_lock do
          File.unlink(transaction.lock_path)
          File.write(transaction.lock_path, replacement)
          File.chmod(0o600, transaction.lock_path)
        end
      end

      assert_match(/lock binding changed/, error.message)
      assert_equal replacement, File.read(transaction.lock_path)
    end
  end

  def test_process_start_mismatch_is_reclaimed_after_the_kernel_lock_is_acquired
    with_tmp_dir do |dir|
      transaction = build_transaction(dir)
      transaction.with_lock { nil }
      write_holder(transaction, process_start: "not-this-process")

      entered = false
      transaction.with_lock { entered = true }

      assert entered
      assert_equal "", File.read(transaction.lock_path)
    end
  end

  def test_invalid_boot_identity_is_preserved_as_unprovable_evidence
    with_tmp_dir do |dir|
      transaction = build_transaction(dir)
      transaction.with_lock { nil }
      write_holder(transaction, process_start: "not-this-process", boot_id: "not-a-boot-id")
      evidence = File.read(transaction.lock_path)

      error = assert_raises(Hive::UserService::Transaction::Unsafe) do
        transaction.with_lock { flunk "invalid holder must not be reclaimed" }
      end

      assert_match(/invalid user-service lock holder record/, error.message)
      assert_equal evidence, File.read(transaction.lock_path)
    end
  end

  def test_wrong_mode_bootstrap_lock_is_not_normalized
    with_tmp_dir do |dir|
      bootstrap = File.join(dir, ".hive-user-service-bootstrap.lock")
      File.write(bootstrap, "")
      File.chmod(0o644, bootstrap)
      transaction = build_transaction(dir)

      error = assert_raises(Hive::UserService::Transaction::Unsafe) do
        transaction.with_lock { flunk "unsafe bootstrap must not be entered" }
      end

      assert_match(/unsafe user-service bootstrap lock/, error.message)
      assert_equal 0o644, File.stat(bootstrap).mode & 0o777
    end
  end

  def test_operation_filesystem_errors_are_not_reclassified_as_unsafe_lock_evidence
    with_tmp_dir do |dir|
      transaction = build_transaction(dir)

      error = assert_raises(Errno::ENOENT) do
        transaction.with_lock { raise Errno::ENOENT, "operation target vanished" }
      end

      assert_match(/operation target vanished/, error.message)
      assert_equal "", File.read(transaction.lock_path)
    end
  end

  def test_verified_removal_validates_all_evidence_before_deleting_any_of_it
    with_tmp_dir do |dir|
      transaction = build_transaction(dir)
      deleted = []
      journal = Object.new
      journal.define_singleton_method(:read) { true }
      journal.define_singleton_method(:delete) { deleted << :journal }
      receipt = Object.new
      receipt.define_singleton_method(:read) do
        raise Hive::UserService::AppliedReceipt::Invalid, "foreign receipt"
      end
      receipt.define_singleton_method(:delete) { deleted << :receipt }
      transaction.instance_variable_set(:@journal, journal)
      transaction.instance_variable_set(:@receipt, receipt)

      assert_raises(Hive::UserService::AppliedReceipt::Invalid) do
        transaction.clear_after_verified_removal
      end
      assert_empty deleted
    end
  end

  def test_locked_stale_and_unprovable_records_fail_closed
    with_tmp_dir do |dir|
      %i[stale unprovable].each do |state|
        transaction = build_transaction(dir, lock_wait: 0)
        transaction.with_lock { nil }
        File.open(transaction.lock_path, File::RDWR) do |holder|
          holder.flock(File::LOCK_EX)
          transaction.define_singleton_method(:holder_state) { |_lock| state }

          error = assert_raises(Hive::UserService::Transaction::Unsafe) do
            transaction.with_lock { flunk "kernel-locked target must not be entered" }
          end
          expected = state == :stale ? /remains kernel-locked/ : /cannot be proven/
          assert_match expected, error.message
        end
      end
    end
  end

  def test_live_unlocked_holder_record_is_not_reclaimed
    with_tmp_dir do |dir|
      transaction = build_transaction(dir)
      transaction.with_lock { nil }
      write_holder(transaction, process_start: Hive::Lock.process_start_time(Process.pid).to_s)

      error = assert_raises(Hive::UserService::Transaction::Unsafe) do
        transaction.with_lock { flunk "live recorded holder must not be reclaimed" }
      end

      assert_match(/live user-service holder record is not reclaimable/, error.message)
    end
  end

  def test_holder_permission_failure_is_unprovable
    with_tmp_dir do |dir|
      transaction = build_transaction(dir)
      transaction.with_lock { nil }
      write_holder(transaction, process_start: "123")

      File.open(transaction.lock_path, File::RDWR) do |lock|
        state = with_replaced_singleton_method(Process, :kill, ->(*) { raise Errno::EPERM }) do
          transaction.send(:holder_state, lock)
        end
        assert_equal :unprovable, state
      end
    end
  end

  def test_invalid_holder_shapes_and_json_are_rejected
    with_tmp_dir do |dir|
      transaction = build_transaction(dir)
      transaction.with_lock { nil }

      [ JSON.generate("pid" => 1), "{not-json" ].each do |payload|
        File.write(transaction.lock_path, payload)
        File.chmod(0o600, transaction.lock_path)
        error = assert_raises(Hive::UserService::Transaction::Unsafe) do
          transaction.with_lock { flunk "invalid holder must not be reclaimed" }
        end
        assert_match(/invalid user-service lock holder record/, error.message)
      end
    end
  end

  def test_unavailable_boot_identity_and_clear_failure_are_bounded
    with_tmp_dir do |dir|
      transaction = build_transaction(dir)
      original = File.method(:read)
      boot_id = with_replaced_singleton_method(
        File,
        :read,
        lambda do |path, *args|
          raise Errno::EACCES if path == "/proc/sys/kernel/random/boot_id"

          original.call(path, *args)
        end
      ) { transaction.send(:boot_id) }
      assert_equal "unavailable", boot_id

      lock = Object.new
      %i[rewind truncate flush].each { |method| lock.define_singleton_method(method) { |*| nil } }
      lock.define_singleton_method(:fsync) { raise IOError }
      assert_nil transaction.send(:clear_holder, lock)
    end
  end

  private

  def build_transaction(home, lock_wait: 0.01)
    Hive::UserService::Transaction.new(
      definition: definition(home),
      home: home,
      lock_wait: lock_wait,
      clock: -> { Time.utc(2026, 8, 30, 12, 0, 0) }
    )
  end

  def definition(home)
    Hive::UserService::Definition.new(
      platform: :linux,
      service_name: "hive-test",
      target_path: File.join(home, ".config/systemd/user/hive-test.service"),
      content: "desired\n"
    )
  end

  def write_holder(transaction, process_start:, boot_id: File.read("/proc/sys/kernel/random/boot_id").strip)
    File.write(
      transaction.lock_path,
      JSON.generate(
        "pid" => Process.pid,
        "boot_id" => boot_id,
        "process_start" => process_start,
        "target_path" => transaction.instance_variable_get(:@definition).target_path,
        "acquired_at" => Time.now.utc.iso8601(6)
      ) + "\n"
    )
    File.chmod(0o600, transaction.lock_path)
  end
end
