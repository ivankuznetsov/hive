require "test_helper"
require "open3"
require "hive/stages/open_pr"

class GoldenPathSupportTest < ActiveSupport::TestCase
  FAKE_CLAUDE = File.expand_path("support/claude", __dir__)

  test "open-PR fake authors the bounded draft consumed by the controller" do
    Dir.mktmpdir("golden-path-open-pr") do |root|
      task_folder = File.join(root, "stages", "5-open-pr", "sample-task")
      FileUtils.mkdir_p(task_folder)

      _stdout, stderr, status = Open3.capture3(FAKE_CLAUDE, chdir: task_folder)

      assert status.success?, stderr
      path = File.join(task_folder, Hive::Stages::OpenPr::AUTHORING_FILE)
      assert_path_exists path
      draft = JSON.parse(File.binread(path))
      assert_equal "Golden path sample implementation", draft.fetch("title")
      assert_equal "Created by the golden-path E2E.", draft.fetch("body")
      assert_operator File.size(path), :<=, Hive::Stages::OpenPr::MAX_AUTHORING_BYTES
    end
  end
end
