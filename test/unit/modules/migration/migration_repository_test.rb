require "test_helper"
require "digest"
require "hive/modules/migration/migration_repository"
require "hive/modules/migration/report"

class ModulesMigrationRepositoryTest < Minitest::Test
  include HiveTestHelper

  def test_mutation_lock_refuses_symlinks_and_non_regular_entries
    with_tmp_dir do |root|
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      outside = File.join(root, "outside")
      File.binwrite(outside, "sentinel")
      lock = File.join(root, ".mutation.lock")
      File.symlink(outside, lock)

      assert_raises(Hive::ConfigError) do
        repository.with_lock { flunk "unsafe symlink lock yielded" }
      end
      assert_equal "sentinel", File.binread(outside)

      File.unlink(lock)
      FileUtils.mkdir_p(lock)
      assert_raises(Hive::ConfigError) do
        repository.with_lock { flunk "non-regular lock yielded" }
      end
    end
  end

  def test_report_and_cutover_transactions_serialize_on_one_lock
    with_tmp_dir do |root|
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      entered = Queue.new
      release = Queue.new
      second = Queue.new
      writer = Thread.new do
        repository.with_lock do
          entered << true
          release.pop
        end
      end
      entered.pop
      cutover = Thread.new do
        repository.with_lock { second << true }
      end

      sleep 0.05
      assert second.empty?, "cutover entered while report transaction held the lock"
      release << true
      writer.join
      cutover.join
      assert_equal true, second.pop
    ensure
      writer&.kill
      cutover&.kill
    end
  end

  def test_report_compare_and_swap_rejects_stale_and_missing_snapshots
    with_tmp_dir do |root|
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      first = report("first")
      second = report("second")
      stale = report("stale")
      repository.write_report(first)
      first_bytes = repository.read_report_bytes
      repository.write_report(second)

      assert_raises(Hive::ConfigError) do
        repository.write_report(
          stale,
          expected_digest:
            Digest::SHA256.hexdigest(first_bytes)
        )
      end
      assert_equal second.payload, repository.load_report.payload
      assert_raises(Hive::ConfigError) do
        repository.write_report(
          stale,
          expected_digest:
            Hive::Modules::Migration::MigrationRepository::EXPECTED_MISSING
        )
      end
      assert_equal second.payload, repository.load_report.payload
    end
  end

  def test_report_write_prunes_only_unreferenced_content_addressed_bundles
    with_tmp_dir do |root|
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      bytes = "{}"
      digest = Digest::SHA256.hexdigest(bytes)
      relative = "report-evidence/#{digest}.json"
      repository.write_bundle(relative, bytes)

      repository.write_report(report("replacement"))

      assert_nil repository.read_bundle(relative, missing: true)
      assert_raises(Hive::ConfigError) do
        repository.write_bundle(
          "report-evidence/#{"f" * 64}.json",
          bytes
        )
      end
    end
  end

  def test_explicit_anchor_rejects_escape_and_symlink_rebinding
    with_tmp_dir do |root|
      anchor = File.join(root, "state")
      FileUtils.mkdir_p(anchor)
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::MigrationRepository.new(
          root: File.join(root, "outside"),
          anchor: anchor
        )
      end

      real = File.join(root, "real-state")
      FileUtils.mkdir_p(real)
      FileUtils.rm_rf(anchor)
      File.symlink(real, anchor)
      repository =
        Hive::Modules::Migration::MigrationRepository.new(
          root: File.join(anchor, "module-runtime", "migration"),
          anchor: anchor
        )
      assert_raises(Hive::ConfigError) do
        repository.with_lock { flunk "symlink anchor yielded" }
      end
    end
  end

  private

  def report(blocker)
    Hive::Modules::Migration::Report.evidence_required(
      blockers: [ blocker ],
      reviewer: "operator",
      reviewed_at: Time.utc(2026, 7, 30)
    )
  end
end
