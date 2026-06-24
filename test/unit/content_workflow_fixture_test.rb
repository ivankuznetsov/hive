require "test_helper"
require "hive/markers"
require "hive/stages/agent"
require "hive/task"
require "hive/task_meta"

class ContentWorkflowFixtureTest < Minitest::Test
  include HiveTestHelper

  SLUG = "content-fixture-260620-abcd"

  def test_content_workflow_registration_is_scoped
    refute_includes Hive::Workflows::Registry.ids, :content_fixture

    with_registered_workflow(content_workflow) do
      assert_includes Hive::Workflows::Registry.ids, :content_fixture
      assert_equal "1-inbox", Hive::Workflows::Registry.fetch(:content_fixture).stages.first.dir
    end

    refute_includes Hive::Workflows::Registry.ids, :content_fixture
  end

  def test_deterministic_content_agent_writes_stage_artifact_and_marker
    with_registered_workflow(content_workflow) do
      with_tmp_dir do |root|
        folder = File.join(root, ".hive-state", "stages", "2-research", SLUG)
        Hive::TaskMeta.write(folder, id: 7, slug: SLUG, display_name: nil, workflow: "content_fixture")
        task = Hive::Task.new(folder)
        ran = []

        with_deterministic_content_agent(record: ran) do
          result = Hive::Stages::Agent.run!(task, {})

          assert_equal({ commit: "complete", status: :complete }, result)
        end

        assert_equal [ "research" ], ran
        artifact = File.join(folder, "research.md")
        assert_includes File.read(artifact), "artifact: research"
        assert_equal :complete, Hive::Markers.current(artifact).name
      end
    end
  end
end
