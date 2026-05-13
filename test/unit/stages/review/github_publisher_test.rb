require "test_helper"
require "hive/stages/review/github_publisher"
require "hive/task"

class ReviewGithubPublisherTest < Minitest::Test
  include HiveTestHelper

  FAKE_GH = File.expand_path("../../../fixtures/fake-gh", __dir__)

  def setup
    @prev_path = ENV["PATH"]
    @gh_dir = Dir.mktmpdir("fake-gh-bin")
    File.symlink(FAKE_GH, File.join(@gh_dir, "gh"))
    ENV["PATH"] = "#{@gh_dir}:#{@prev_path}"
    @log_dir = Dir.mktmpdir("fake-gh-log")
    ENV["HIVE_FAKE_GH_LOG_DIR"] = @log_dir
  end

  def teardown
    ENV["PATH"] = @prev_path
    FileUtils.rm_rf(@gh_dir)
    FileUtils.rm_rf(@log_dir)
    %w[HIVE_FAKE_GH_LOG_DIR HIVE_FAKE_GH_COMMENTS_BODY HIVE_FAKE_GH_COMMENT_EXIT].each { |k| ENV.delete(k) }
  end

  def make_task(dir)
    folder = File.join(dir, ".hive-state", "stages", "6-review", "demo-260513-abcd")
    FileUtils.mkdir_p(File.join(folder, "reviews"))
    File.write(File.join(folder, "task.md"), "task\n")
    File.write(File.join(folder, "pr.md"), <<~MD)
      ---
      pr_url: https://example.com/pr/42
      pr_number: 42
      ---

      <!-- COMPLETE pr_url=https://example.com/pr/42 is_draft=true -->
    MD
    Hive::Task.new(folder)
  end

  def cfg(enabled: true)
    { "review" => { "github_publish" => { "enabled" => enabled, "max_attempts" => 1 } } }
  end

  def test_posts_review_comment
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "- [ ] finding\n")

      result = Hive::Stages::Review::GithubPublisher.publish!(
        task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
      )

      assert_equal :posted, result
      log = File.read(File.join(@log_dir, "fake-gh-argv.log"))
      assert_includes log, "arg=comment\n"
      assert_includes log, "arg=https://example.com/pr/42\n"
    end
  end

  def test_skips_duplicate_header
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "- [ ] finding\n")
      ENV["HIVE_FAKE_GH_COMMENTS_BODY"] = "### Reviewer: codex - Pass 01\n\nold"

      result = Hive::Stages::Review::GithubPublisher.publish!(
        task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
      )

      assert_equal :already_posted, result
      log = File.read(File.join(@log_dir, "fake-gh-argv.log"))
      refute_includes log, "arg=comment\n"
    end
  end

  def test_disabled_skips
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "- [ ] finding\n")

      assert_equal :disabled,
                   Hive::Stages::Review::GithubPublisher.publish!(
                     task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg(enabled: false)
                   )
    end
  end
end
