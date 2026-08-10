require "test_helper"
require "hive/recovery/api"

class HiveRecoveryAPITest < Minitest::Test
  include HiveTestHelper

  def test_observation_derives_the_state_file_from_a_task_folder
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "4-execute", "task")
      FileUtils.mkdir_p(folder)
      expected = File.join(folder, "task.md")
      File.write(expected, "# Task\n")

      observation = Hive::Recovery::API.observation(
        { "folder" => folder, "slug" => "task", "stage" => "4-execute" }
      )

      assert_equal expected, observation.state_file
    end
  end

  def test_observation_ignores_invalid_and_unreadable_mtimes
    invalid = Hive::Recovery::API.observation(
      { "state_file_mtime" => "not-a-time" }
    )
    assert_nil invalid.state_file_mtime

    with_tmp_dir do |dir|
      path = File.join(dir, "task.md")
      File.write(path, "# Task\n")
      original = File.method(:mtime)

      with_replaced_singleton_method(File, :mtime, lambda { |candidate|
        raise Errno::EACCES if candidate == path

        original.call(candidate)
      }) do
        unreadable = Hive::Recovery::API.observation({ "state_file" => path })
        assert_nil unreadable.state_file_mtime
      end
    end
  end
end
