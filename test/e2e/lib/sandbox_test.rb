require_relative "../../test_helper"
require "fileutils"
require_relative "sandbox"

class E2ESandboxTest < Minitest::Test
  def with_capture3_responses(*responses)
    Open3.singleton_class.send(:alias_method, :__hive_orig_capture3, :capture3)
    calls = responses.dup
    Open3.define_singleton_method(:capture3) do |*_cmd|
      calls.shift || [ "", "", instance_double_status(true) ]
    end
    yield
  ensure
    Open3.singleton_class.send(:alias_method, :capture3, :__hive_orig_capture3)
    Open3.singleton_class.send(:remove_method, :__hive_orig_capture3)
  end

  def instance_double_status(success)
    status = Object.new
    status.define_singleton_method(:success?) { success }
    status
  end

  def test_bootstrap_initializes_registered_project
    Dir.mktmpdir("e2e-run") do |dir|
      sandbox = Hive::E2E::Sandbox.bootstrap(dir)

      assert File.directory?(File.join(sandbox.sandbox_dir, ".hive-state"))
      config = YAML.safe_load(File.read(File.join(sandbox.run_home, "config.yml")))
      assert_equal [ "sandbox" ], config.fetch("registered_projects").map { |project| project.fetch("name") }
    end
  end

  def test_sample_project_guard_raises_on_tracked_diff
    with_capture3_responses([ "diff", "", instance_double_status(false) ]) do
      error = assert_raises(RuntimeError) do
        Hive::E2E::Sandbox.new("/tmp/e2e-run").assert_sample_project_unmutated!
      end
      assert_includes error.message, "tracked diff"
    end
  end

  def test_sample_project_guard_raises_on_untracked_status
    with_capture3_responses(
      [ "", "", instance_double_status(true) ],
      [ "?? test/e2e/sample-project/new.txt\n", "", instance_double_status(true) ]
    ) do
      error = assert_raises(RuntimeError) do
        Hive::E2E::Sandbox.new("/tmp/e2e-run").assert_sample_project_unmutated!
      end
      assert_includes error.message, "untracked or staged"
    end
  end

  def test_sample_project_guard_allows_clean_status
    with_capture3_responses(
      [ "", "", instance_double_status(true) ],
      [ "", "", instance_double_status(true) ]
    ) do
      Hive::E2E::Sandbox.new("/tmp/e2e-run").assert_sample_project_unmutated!
    end
  end

  def test_cleanup_runs_refuses_unsafe_roots
    assert_raises(ArgumentError) do
      Hive::E2E::Sandbox.cleanup_runs(runs_dir: Dir.home)
    end
  end

  def test_cleanup_runs_only_deletes_generated_run_directories
    Dir.mktmpdir("e2e-runs") do |runs_dir|
      old_generated = File.join(runs_dir, "2026-04-30T12-00-00Z-1234-abcd")
      unsafe_name = File.join(runs_dir, "not-a-generated-run")
      FileUtils.mkdir_p(old_generated)
      FileUtils.mkdir_p(unsafe_name)
      old_time = Time.now - (10 * 86_400)
      File.utime(old_time, old_time, old_generated)
      File.utime(old_time, old_time, unsafe_name)

      result = Hive::E2E::Sandbox.cleanup_runs(runs_dir: runs_dir, retain_days: 0, retain_failed_days: 0)

      assert_equal 1, result["deleted"]
      assert_equal 1, result["kept"]
      refute File.exist?(old_generated), "generated expired run should be deleted"
      assert File.exist?(unsafe_name), "non-generated child directories must never be deleted"
      assert_equal "name_not_generated_run_id", result["kept_runs"].first["reason"]
    end
  end
end
