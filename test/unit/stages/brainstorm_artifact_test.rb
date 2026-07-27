require "test_helper"
require "tmpdir"
require "hive/markers"
require "hive/stages/brainstorm"

class HiveStagesBrainstormArtifactTest < Minitest::Test
  include HiveTestHelper

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

  def test_artifact_validation_fails_closed_when_the_file_cannot_be_read
    with_tmp_dir do |dir|
      path = File.join(dir, "brainstorm.md")
      File.write(path, "## Round 1\n<!-- WAITING -->\n")
      original = File.method(:read)

      with_replaced_singleton_method(File, :read, lambda { |candidate, *args, **kwargs|
        raise Errno::EACCES if candidate == path

        original.call(candidate, *args, **kwargs)
      }) do
        refute Hive::Stages::Brainstorm.artifact_valid?(path)
      end
    end
  end

  def test_artifact_snapshot_returns_nil_when_the_file_cannot_be_read
    with_tmp_dir do |dir|
      path = File.join(dir, "brainstorm.md")
      File.write(path, "draft")
      original = File.method(:read)

      with_replaced_singleton_method(File, :read, lambda { |candidate, *args, **kwargs|
        raise Errno::EACCES if candidate == path

        original.call(candidate, *args, **kwargs)
      }) do
        assert_nil Hive::Stages::Brainstorm.artifact_snapshot(path)
      end
    end
  end
end
