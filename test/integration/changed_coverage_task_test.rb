require "test_helper"
require "open3"

class ChangedCoverageTaskTest < Minitest::Test
  include HiveTestHelper

  ROOT = File.expand_path("../..", __dir__)

  def test_focused_task_collects_once_without_preloading_unrelated_sources_and_refuses_unloaded_source
    Dir.mktmpdir("hive-changed-coverage") do |root|
      %w[bin test/support test/unit lib].each { |path| FileUtils.mkdir_p(File.join(root, path)) }
      %w[Rakefile bin/test test/support/coverage.rb test/support/changed_coverage.rb
         test/support/tmp_cleanup.rb test/support/test_partition.rb test/hive_coverage_boot.rb].each do |path|
        FileUtils.cp(File.join(ROOT, path), File.join(root, path))
      end
      File.write(File.join(root, "test/test_helper.rb"), <<~SOURCE)
        require "minitest/autorun"
        require_relative "support/coverage"
        HiveTestCoverage.install_reporter!
      SOURCE
      File.write(File.join(root, "lib/unrelated.rb"), 'raise "unrelated source was preloaded"')
      system("git", "init", "-q", root, exception: true)
      system("git", "-C", root, "add", ".", exception: true)
      system("git", "-C", root, "-c", "user.name=Test", "-c", "user.email=test@example.com",
             "commit", "-qm", "fixture", exception: true)
      # Both new files are untracked: the focused loop must see work before commit.
      File.write(File.join(root, "lib/demo.rb"), "module Demo; def self.answer; 42; end; end\n")
      test_path = File.join(root, "test/unit/demo_test.rb")
      File.write(test_path, <<~SOURCE)
        require "test_helper"
        require "demo"
        class DemoTest < Minitest::Test
          def test_answer = assert_equal 42, Demo.answer
        end
      SOURCE
      environment = {
        "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"), "HIVE_COVERAGE_BASE" => "HEAD",
        "HIVE_COVERAGE" => nil, "HIVE_COVERAGE_ROOT" => nil, "HIVE_COVERAGE_RUN_ID" => nil,
        "HIVE_COVERAGE_COLLECT_ONLY" => nil, "HIVE_COVERAGE_LOAD_ALL" => nil, "RUBYOPT" => nil
      }
      output, status = Open3.capture2e(environment, "bundle", "exec", "rake", "coverage:changed", chdir: root)
      assert status.success?, output
      assert_includes output, "exact line coverage holds for all 1 changed source(s)"
      reports = Dir[File.join(root, "coverage", "changed-*.json")]
      assert_equal 1, reports.length
      report = JSON.parse(File.read(reports.first))
      assert_equal [ "lib/demo.rb" ], report.fetch("files").map { |entry| entry.fetch("file") }
      assert_equal 100.0, report.fetch("line_percent")
      refute File.exist?(File.join(root, "coverage", "coverage.json")), "child must not write a global report"

      File.write(test_path, <<~SOURCE)
        require "test_helper"
        class DemoTest < Minitest::Test
          def test_unrelated = assert true
        end
      SOURCE
      output, status = Open3.capture2e(environment, "bundle", "exec", "rake", "coverage:changed", chdir: root)
      refute status.success?, output
      assert_includes output, "lib/demo.rb: never loaded"
    end
  end
end
