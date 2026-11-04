require "test_helper"

class TestHelperTest < ActiveSupport::TestCase
  test "test projects cannot install host llm wiki timers" do
    assert_equal ENV.fetch("HIVE_TEST_HOME_ROOT"), File.dirname(ENV.fetch("HIVE_HOME"))
    assert_equal "1", ENV.fetch("HIVE_SKIP_LLM_WIKI_SCHEDULER")
    assert_equal "1", ENV.fetch("HIVE_SKIP_LLM_WIKI_SYSTEMCTL")
    assert_equal "1", ENV.fetch("HIVE_SKIP_LLM_WIKI_POST_COMMIT")
  end

  %w[1-inbox 2-brainstorm].each do |stage|
    test "create_task retries generated slug collisions in #{stage}" do
      project = create_hive_project!("collision-#{stage}-app")
      first_slug = create_task!(project, "collision probe")
      FileUtils.mv(stage_dir(project, "1-inbox").join(first_slug),
                   stage_dir(project, stage).join(first_slug)) unless stage == "1-inbox"
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
      assert_equal second_slug, Hive::TaskResolver.new(second_slug, project_filter: project).resolve.slug
      refute_equal first_slug, second_slug
      assert stage_dir(project, "1-inbox").join(second_slug).directory?
      assert stage_dir(project, stage).join(first_slug).directory?, "the original task must be preserved"
    ensure
      SecureRandom.define_singleton_method(:hex) { |bytes| original_hex.call(bytes) } if original_hex
    end
  end
end
