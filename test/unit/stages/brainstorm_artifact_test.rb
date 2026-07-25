require "test_helper"
require "tmpdir"
require "hive/markers"
require "hive/stages/brainstorm"

class HiveStagesBrainstormArtifactTest < Minitest::Test
  def test_complete_requires_content_inside_requirements_section
    Dir.mktmpdir("hive-brainstorm-artifact") do |dir|
      path = File.join(dir, "brainstorm.md")
      File.write(path, "## Requirements\n\n## Notes\nImplementation notes are not requirements.\n")
      Hive::Markers.set(path, :complete)

      refute Hive::Stages::Brainstorm.artifact_valid?(path)

      File.write(path, "## Requirements\n- Ship durable retry.\n\n## Notes\nContext.\n")
      Hive::Markers.set(path, :complete)
      assert Hive::Stages::Brainstorm.artifact_valid?(path)
    end
  end
end
