require "test_helper"
require "json"
require "timeout"
require_relative "../../../packaging/live_agent_skills/workflow_creator_evidence"

class WorkflowCreatorEvidenceTest < Minitest::Test
  include HiveTestHelper

  SHA = "a" * 40
  Creator = HiveLiveAgentProof::WorkflowCreator
  Evidence = HiveLiveAgentProof::WorkflowCreatorEvidence

  def test_initialize_publishes_the_fixed_private_canonical_receipt
    with_private_bundle do |bundle|
      receipt = Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
      target = File.join(bundle, Creator::Vocabulary.fetch("bundle_files").first)

      assert_equal receipt.value, JSON.parse(File.binread(target))
      assert_equal receipt.canonical_bytes, File.binread(target)
      assert_equal 0o600, File.stat(target).mode & 0o777
      assert_equal [ File.basename(target) ], Dir.children(bundle)
    end
  end


  def test_public_api_accepts_only_typed_bundle_operations_and_publisher_is_private
    assert_equal %i[initialize! replace_nonpassing!], Evidence.singleton_methods(false).sort
    assert_equal [ [ :keyreq, :bundle_directory ], [ :keyreq, :candidate_sha ] ],
                 Evidence.method(:initialize!).parameters
    replacement_parameters = Evidence.method(:replace_nonpassing!).parameters
    assert_equal %i[bundle_directory expected receipt exact_secrets],
                 replacement_parameters.map(&:last)
    assert_raises(NameError) { HiveLiveAgentProof::WorkflowCreatorReceiptPublisher }
  end


  def test_exact_retry_converges_without_replacing_the_target
    with_private_bundle do |bundle|
      first = Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
      path = target(bundle)
      identity = File.stat(path).ino

      second = Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)

      assert_equal first.canonical_bytes, second.canonical_bytes
      assert_equal identity, File.stat(path).ino
      assert_equal 1, File.stat(path).nlink
    end
  end

  def test_different_initialization_conflicts_without_clobbering
    with_private_bundle do |bundle|
      first = Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)

      error = assert_raises(Evidence::Conflict) do
        Evidence.initialize!(bundle_directory: bundle, candidate_sha: "b" * 40)
      end

      assert_equal first.canonical_bytes, File.binread(target(bundle))
      assert_equal "workflow-creator evidence initialization conflicts", error.message
    end
  end

  def test_transient_link_is_recovered_and_both_cleanup_orders_converge
    with_private_bundle do |bundle|
      receipt = initial_receipt
      stage = staging_path(bundle, "linked")
      write_private(stage, receipt.canonical_bytes)
      File.link(stage, target(bundle))

      recovered = Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)

      assert_equal receipt.canonical_bytes, recovered.canonical_bytes
      refute_path_exists stage
      assert_equal 1, File.stat(target(bundle)).nlink

      retried = Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
      assert_equal recovered.canonical_bytes, retried.canonical_bytes
    end
  end

  def test_two_recovery_callers_converge_on_one_stable_target
    with_private_bundle do |bundle|
      receipt = initial_receipt
      stage = staging_path(bundle, "linked")
      write_private(stage, receipt.canonical_bytes)
      File.link(stage, target(bundle))
      ready = Queue.new
      start = Queue.new
      results = 2.times.map do
        Thread.new do
          ready << true
          start.pop
          Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
        rescue StandardError => e
          e
        end
      end
      2.times { ready.pop }
      2.times { start << true }
      values = results.map(&:value)

      assert values.all? { |value| value.respond_to?(:canonical_bytes) }, values.map(&:inspect).join("\n")
      assert_equal 1, File.stat(target(bundle)).nlink
      assert_empty staging_entries(bundle)
    end
  end

  def test_interrupted_one_link_stage_is_cleaned_before_initialization
    with_private_bundle do |bundle|
      orphan = staging_path(bundle, "orphan")
      write_private(orphan, initial_receipt.canonical_bytes)

      Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)

      refute_path_exists orphan
      assert_equal [ File.basename(target(bundle)) ], Dir.children(bundle)
      assert_empty staging_entries(bundle)
    end
  end

  def test_link_ambiguities_fail_closed
    cases = {
      outside_prefix: lambda do |bundle, receipt|
        write_private(target(bundle), receipt.canonical_bytes)
        File.link(target(bundle), File.join(File.dirname(bundle), "outside-link"))
      end,
      greater_than_two: lambda do |bundle, receipt|
        write_private(target(bundle), receipt.canonical_bytes)
        File.link(target(bundle), staging_path(bundle, "one"))
        File.link(target(bundle), staging_path(bundle, "two"))
      end,
      multiple_prefix: lambda do |bundle, receipt|
        write_private(staging_path(bundle, "one"), receipt.canonical_bytes)
        write_private(staging_path(bundle, "two"), receipt.canonical_bytes)
      end
    }
    cases.each do |label, prepare|
      with_private_bundle do |bundle|
        prepare.call(bundle, initial_receipt)
        assert_raises(Evidence::UnsafeStorage, label.to_s) do
          Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
        end
      end
    end
  end

  def test_replacement_is_compare_and_swap_and_post_rename_retry_is_exact
    with_private_bundle do |bundle|
      initial = Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
      desired = failure_receipt("proof_failed")

      replaced = Evidence.replace_nonpassing!(
        bundle_directory: bundle, expected: initial.value, receipt: desired.value
      )
      inode = File.stat(target(bundle)).ino
      retried = Evidence.replace_nonpassing!(
        bundle_directory: bundle, expected: initial.value, receipt: desired.value
      )

      assert_equal desired.canonical_bytes, replaced.canonical_bytes
      assert_equal desired.canonical_bytes, retried.canonical_bytes
      assert_equal inode, File.stat(target(bundle)).ino
      assert_empty staging_entries(bundle)
    end
  end

  def test_replacement_preserves_canonical_non_ascii_bytes
    with_private_bundle do |bundle|
      initial = Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
      desired = Creator.failure(
        candidate_sha: SHA, phase: "proof", reason: "proof_failed", detail: "café — 東京"
      )

      Evidence.replace_nonpassing!(
        bundle_directory: bundle, expected: initial.value, receipt: desired.value
      )

      assert_equal desired.canonical_bytes.b, File.binread(target(bundle))
      assert_equal desired.value, JSON.parse(File.binread(target(bundle)))
    end
  end

  def test_replacement_rejects_a_target_changed_away_from_expected_and_desired
    with_private_bundle do |bundle|
      initial = Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
      foreign = failure_receipt("provider_unavailable")
      write_private(target(bundle), foreign.canonical_bytes, truncate: true)

      assert_raises(Evidence::Conflict) do
        Evidence.replace_nonpassing!(
          bundle_directory: bundle, expected: initial.value,
          receipt: failure_receipt("proof_failed").value
        )
      end
      assert_equal foreign.canonical_bytes, File.binread(target(bundle))
    end
  end


  def test_two_replacers_serialize_before_revalidation_and_cannot_clobber_the_winner
    with_private_bundle do |bundle|
      initial = Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
      first_desired = failure_receipt("proof_failed")
      second_desired = failure_receipt("provider_unavailable")
      entered_rename = Queue.new
      release_rename = Queue.new
      attempted_lock = Queue.new
      with_native_method(native_class, :lock, lambda do |original, instance, *args|
        attempted_lock << true if Thread.current[:u1b_replacer] == :second
        original.bind_call(instance, *args)
      end) do
        with_native_method(native_class, :renameat, lambda do |original, instance, *args|
          if Thread.current[:u1b_replacer] == :first
            entered_rename << true
            release_rename.pop
          end
          original.bind_call(instance, *args)
        end) do
          first = Thread.new do
            Thread.current[:u1b_replacer] = :first
            Evidence.replace_nonpassing!(
              bundle_directory: bundle, expected: initial.value, receipt: first_desired.value
            )
          rescue StandardError => e
            e
          end
          Timeout.timeout(2) { entered_rename.pop }
          second = Thread.new do
            Thread.current[:u1b_replacer] = :second
            Evidence.replace_nonpassing!(
              bundle_directory: bundle, expected: initial.value, receipt: second_desired.value
            )
          rescue StandardError => e
            e
          end
          Timeout.timeout(2) { attempted_lock.pop }
          assert second.alive?, "second replacer passed the held descriptor lock"
          release_rename << true
          first_result = first.value
          second_result = second.value

          assert_equal first_desired.canonical_bytes, first_result.canonical_bytes
          assert_instance_of Evidence::Conflict, second_result
          assert_equal first_desired.canonical_bytes, File.binread(target(bundle))
          assert_empty staging_entries(bundle)
        ensure
          release_rename << true if first&.alive?
          first&.join(1)
          second&.join(1)
        end
      end
    end
  end

  def test_descriptor_lock_failure_is_typed_and_leaves_no_stage
    with_private_bundle do |bundle|
      initial = Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
      with_native_method(native_class, :lock, lambda do |_original, _instance, *|
        raise Errno::EACCES, "injected lock failure"
      end) do
        error = assert_raises(Evidence::Unavailable) do
          Evidence.replace_nonpassing!(
            bundle_directory: bundle, expected: initial.value,
            receipt: failure_receipt("proof_failed").value
          )
        end
        assert_nil error.cause
      end
      assert_equal initial.canonical_bytes, File.binread(target(bundle))
      assert_empty staging_entries(bundle)
    end
  end

  def test_file_fsync_precedes_link_and_cleanup_precedes_directory_fsync
    with_private_bundle do |bundle|
      events = []
      native = native_class
      with_native_method(native, :fsync, lambda do |original, instance, io|
        events << (io.stat.file? ? :file_fsync : :directory_fsync)
        original.bind_call(instance, io)
      end) do
        with_native_method(native, :linkat, lambda do |original, instance, *args|
          events << :link
          original.bind_call(instance, *args)
        end) do
          with_native_method(native, :unlinkat, lambda do |original, instance, *args|
            events << :unlink
            original.bind_call(instance, *args)
          end) do
            Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
          end
        end
      end

      assert_operator events.index(:file_fsync), :<, events.index(:link)
      assert_operator events.index(:link), :<, events.index(:unlink)
      assert_operator events.index(:unlink), :<, events.index(:directory_fsync)
    end
  end

  def test_fsync_failures_are_typed_and_retryable
    with_private_bundle do |bundle|
      native = native_class
      with_native_method(native, :fsync, lambda do |_original, _instance, io|
        raise IOError, "injected file fsync" if io.stat.file?
        0
      end) do
        assert_raises(Evidence::Unavailable) do
          Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
        end
      end
      refute_path_exists target(bundle)
      assert_empty staging_entries(bundle)

      Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
      assert_equal initial_receipt.canonical_bytes, File.binread(target(bundle))
    end
  end


  def test_post_publication_directory_fsync_failure_leaves_an_exact_retryable_target
    with_private_bundle do |bundle|
      failed = false
      with_native_method(native_class, :fsync, lambda do |original, instance, io|
        if io.stat.directory? && !failed
          failed = true
          raise IOError, "injected directory fsync"
        end
        original.bind_call(instance, io)
      end) do
        assert_raises(Evidence::Unavailable) do
          Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
        end
      end

      assert_equal initial_receipt.canonical_bytes, File.binread(target(bundle))
      recovered = Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
      assert_equal initial_receipt.canonical_bytes, recovered.canonical_bytes
      assert_equal 1, File.stat(target(bundle)).nlink
    end
  end

  def test_rename_failure_preserves_expected_target_and_cleans_staging
    with_private_bundle do |bundle|
      initial = Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
      with_native_method(native_class, :renameat, lambda do |_original, _instance, *|
        raise Errno::EACCES, "injected rename failure"
      end) do
        assert_raises(Evidence::Unavailable) do
          Evidence.replace_nonpassing!(
            bundle_directory: bundle, expected: initial.value,
            receipt: failure_receipt("proof_failed").value
          )
        end
      end
      assert_equal initial.canonical_bytes, File.binread(target(bundle))
      assert_empty staging_entries(bundle)
    end
  end

  def test_cross_filesystem_target_descriptor_is_rejected
    skip "/dev/shm is unavailable" unless File.directory?("/dev/shm")
    with_private_bundle do |bundle|
      foreign = Dir.mktmpdir("hive-u1b", "/dev/shm")
      FileUtils.chmod(0o700, foreign)
      staging_device = File.stat(File.dirname(bundle)).dev
      skip "test filesystems share a device" if File.stat(foreign).dev == staging_device

      with_native_method(native_class, :open_directory_at, lambda do |_original, _instance, *|
        File.open(foreign, File::RDONLY)
      end) do
        assert_raises(Evidence::UnsafeStorage) do
          Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
        end
      end
    ensure
      FileUtils.remove_entry_secure(foreign) if foreign && File.directory?(foreign)
    end
  end

  def test_context_open_failure_closes_the_held_parent_descriptor
    with_private_bundle do |bundle|
      parent = nil
      with_native_method(native_class, :open_directory, lambda do |original, instance, *args|
        parent = original.bind_call(instance, *args)
      end) do
        with_native_method(native_class, :open_directory_at, lambda do |_original, _instance, *|
          raise Errno::EACCES, "injected child open failure"
        end) do
          assert_raises(Evidence::Unavailable) do
            Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
          end
        end
      end

      assert_predicate parent, :closed?
    end
  end

  def test_symlink_fifo_special_and_permission_fail_without_blocking
    skip "mkfifo is unavailable" unless File.respond_to?(:mkfifo)
    with_private_bundle do |bundle|
      outside = File.join(File.dirname(bundle), "outside")
      write_private(outside, "sentinel")
      File.symlink(outside, target(bundle))
      assert_raises(Evidence::UnsafeStorage) do
        Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
      end
    end
    with_private_bundle do |bundle|
      fifo = staging_path(bundle, "fifo")
      File.mkfifo(fifo, 0o600)
      Timeout.timeout(2) do
        assert_raises(Evidence::UnsafeStorage) do
          Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
        end
      end
    end
    with_private_bundle do |bundle|
      FileUtils.chmod(0o755, bundle)
      assert_raises(Evidence::UnsafeStorage) do
        Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
      end
    end
  end

  def test_native_permission_failure_is_normalized_and_cleans_staging
    with_private_bundle do |bundle|
      with_native_method(native_class, :linkat, lambda do |_original, _instance, *|
        raise Errno::EACCES, "injected"
      end) do
        error = assert_raises(Evidence::Unavailable) do
          Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
        end
        assert_nil error.cause
      end
      refute_path_exists target(bundle)
      assert_empty staging_entries(bundle)
    end
  end

  def test_parent_rebinding_fails_without_clobbering_the_replacement_directory
    with_private_bundle do |bundle|
      initial = Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
      parked = "#{bundle}.parked"
      sentinel = "attacker sentinel"
      rebound = false
      with_native_method(native_class, :renameat, lambda do |original, instance, *args|
        unless rebound
          File.rename(bundle, parked)
          FileUtils.mkdir_p(bundle, mode: 0o700)
          FileUtils.chmod(0o700, bundle)
          write_private(target(bundle), sentinel)
          rebound = true
        end
        original.bind_call(instance, *args)
      end) do
        assert_raises(Evidence::UnsafeStorage) do
          Evidence.replace_nonpassing!(
            bundle_directory: bundle, expected: initial.value,
            receipt: failure_receipt("proof_failed").value
          )
        end
      end
      assert_equal sentinel, File.binread(target(bundle))
    ensure
      FileUtils.rm_rf(bundle) if bundle && File.exist?(bundle)
      File.rename(parked, bundle) if parked && File.directory?(parked)
    end
  end

  def test_staging_enumeration_is_bounded
    with_private_bundle do |bundle|
      parent = File.dirname(bundle)
      1_025.times { |index| write_private(File.join(parent, "unrelated-#{index}"), "x") }

      assert_raises(Evidence::UnsafeStorage) do
        Evidence.initialize!(bundle_directory: bundle, candidate_sha: SHA)
      end
    end
  end

  def test_native_flag_tables_cover_linux_and_macos_nofollow_nonblock_modes
    flags = native_class.const_get(:FLAGS, false)
    assert_equal %i[darwin linux], flags.keys.sort
    assert_operator flags.dig(:linux, :read) & 0o400000, :>, 0
    assert_operator flags.dig(:linux, :read) & 0o4000, :>, 0
    assert_operator flags.dig(:darwin, :read) & 0x0100, :>, 0
    assert_operator flags.dig(:darwin, :read) & 0x0004, :>, 0
  end

  private

  def target(bundle)
    File.join(bundle, Creator::Vocabulary.fetch("bundle_files").first)
  end

  def initial_receipt
    Creator.failure(candidate_sha: SHA, phase: "preflight", reason: "not_started")
  end

  def failure_receipt(reason)
    Creator.failure(candidate_sha: SHA, phase: "proof", reason:,
                    execution_kind: "authenticated_openclaw", model_loop: "executed")
  end

  def staging_path(bundle, suffix)
    stat = File.stat(bundle)
    File.join(File.dirname(bundle), ".hive-creator-#{stat.dev.to_s(16)}-#{stat.ino.to_s(16)}-#{suffix}")
  end

  def staging_entries(bundle)
    prefix = File.basename(staging_path(bundle, ""))
    Dir.children(File.dirname(bundle)).select { |name| name.start_with?(prefix) }
  end

  def write_private(path, bytes, truncate: false)
    flags = File::WRONLY | File::CREAT | (truncate ? File::TRUNC : File::EXCL)
    File.open(path, flags, 0o600) { |file| file.write(bytes) }
    FileUtils.chmod(0o600, path)
  end

  def native_class
    publisher = HiveLiveAgentProof.const_get(:WorkflowCreatorReceiptPublisher, false)
    publisher.const_get(:Native, false)
  end

  def with_native_method(native, name, replacement)
    original = native.instance_method(name)
    native.define_method(name) do |*args|
      replacement.call(original, self, *args)
    end
    yield
  ensure
    native.define_method(name, original) if original
  end

  def with_private_bundle
    with_tmp_dir do |root|
      bundle = File.join(root, "bundle")
      FileUtils.mkdir_p(bundle, mode: 0o700)
      FileUtils.chmod(0o700, bundle)
      yield bundle
    end
  end
end
