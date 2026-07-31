require "test_helper"
require "hive/modules/migration/qualification_process_custody"

class ModulesMigrationQualificationProcessCustodyTest <
    Minitest::Test
  include HiveTestHelper

  CUSTODY =
    Hive::Modules::Migration::QualificationProcessCustody
  ATTEMPT_ID =
    "11111111-1111-4111-8111-111111111111".freeze

  def test_round_trips_one_immutable_wrapper_identity
    with_tmp_dir do |root|
      File.chmod(0o700, root)
      record = CUSTODY.write(
        root: root,
        attempt_id: ATTEMPT_ID,
        wrapper: wrapper
      )

      assert_equal ATTEMPT_ID, record.fetch("attempt_id")
      assert_equal(
        { ATTEMPT_ID => record },
        CUSTODY.read_all(root: root)
      )
      path = File.join(root, "#{ATTEMPT_ID}.json")
      assert_equal 0o600, File.stat(path).mode & 0o777

      assert_raises(Hive::ConfigError) do
        CUSTODY.write(
          root: root,
          attempt_id: ATTEMPT_ID,
          wrapper: wrapper.merge("pid" => 999)
        )
      end
    end
  end

  def test_rejects_non_private_roots_and_malformed_records
    with_tmp_dir do |root|
      File.chmod(0o755, root)
      assert_raises(Hive::ConfigError) do
        CUSTODY.read_all(root: root)
      end
    end

    with_tmp_dir do |root|
      File.chmod(0o700, root)
      path = File.join(root, "#{ATTEMPT_ID}.json")
      File.binwrite(path, "{}")
      File.chmod(0o600, path)
      assert_raises(Hive::ConfigError) do
        CUSTODY.read_all(root: root)
      end
    end
  end

  private

  def wrapper
    {
      "pid" => 123,
      "start_fingerprint" => "2026-07-31T12:00:00.000000Z",
      "session_id" => 120,
      "process_group_id" => 120
    }
  end
end
