require "test_helper"

class TestHelperTest < ActiveSupport::TestCase
  test "create_task retries rare generated slug collisions" do
    project = create_hive_project!("collision-app")
    first_slug = create_task!(project, "collision probe")
    duplicate_suffix = first_slug.split("-").last
    original_hex = SecureRandom.method(:hex)
    duplicate_once = true

    SecureRandom.define_singleton_method(:hex) do |bytes|
      if bytes == 2 && duplicate_once
        duplicate_once = false
        duplicate_suffix
      else
        original_hex.call(bytes)
      end
    end

    second_slug = create_task!(project, "collision probe")
    refute_equal first_slug, second_slug
    assert stage_dir(project, "1-inbox").join(second_slug).directory?
  ensure
    SecureRandom.define_singleton_method(:hex) { |bytes| original_hex.call(bytes) } if original_hex
  end
end
