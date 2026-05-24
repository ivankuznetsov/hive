require "test_helper"
require "hive/stages/review/github_publisher"
require "hive/task"

class ReviewGithubPublisherTest < Minitest::Test
  include HiveTestHelper

  def setup
    @prev_path = ENV["PATH"]
    @gh_dir = Dir.mktmpdir("fake-gh-bin")
    File.symlink(FAKE_GH_FIXTURE, File.join(@gh_dir, "gh"))
    ENV["PATH"] = "#{@gh_dir}:#{@prev_path}"
    @log_dir = Dir.mktmpdir("fake-gh-log")
    ENV["HIVE_FAKE_GH_LOG_DIR"] = @log_dir
  end

  def teardown
    ENV["PATH"] = @prev_path
    FileUtils.rm_rf(@gh_dir)
    FileUtils.rm_rf(@log_dir)
    %w[
      HIVE_FAKE_GH_LOG_DIR
      HIVE_FAKE_GH_COMMENTS_BODY
      HIVE_FAKE_GH_COMMENT_COUNT
      HIVE_FAKE_GH_COMMENT_EXIT
    ].each { |k| ENV.delete(k) }
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

  def cfg(enabled: true, max_attempts: 1)
    { "review" => { "github_publish" => { "enabled" => enabled, "max_attempts" => max_attempts } } }
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

      # Tightened: assert the --body-file content matches the
      # header + reviewer body. fake-gh snapshots the body file
      # to the argv log between `body_content<<EOF` and `EOF` so the
      # tempfile content survives past the publisher's ensure block.
      body = log[/body_content<<EOF\n(.*?)\nEOF\n/m, 1]
      refute_nil body, "fake-gh log must capture body_content section"
      assert_match(/\A### Reviewer: codex - Pass 01\n\n.*finding/m, body,
                   "posted body must start with the header + reviewer file content")
    end
  end

  def test_skips_duplicate_header_per_comment_line_anchored
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "- [ ] finding\n")
      # Single comment whose body starts with our header → dedupe.
      ENV["HIVE_FAKE_GH_COMMENTS_BODY"] = "### Reviewer: codex - Pass 01\n\nold"

      result = Hive::Stages::Review::GithubPublisher.publish!(
        task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
      )

      assert_equal :already_posted, result
      log = File.read(File.join(@log_dir, "fake-gh-argv.log"))
      refute_includes log, "arg=comment\n"
    end
  end

  def test_substring_quoted_header_does_NOT_dedupe
    # H6 regression guard: a human comment quoting the bot header in
    # the middle of the body must NOT trip the dedupe. Substring
    # matching used to false-positive here; line-anchored matching
    # only dedupes when the comment's first line IS the header.
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "- [ ] finding\n")
      ENV["HIVE_FAKE_GH_COMMENTS_BODY"] =
        "Quoting earlier:\n> ### Reviewer: codex - Pass 01\nWhich was wrong."

      result = Hive::Stages::Review::GithubPublisher.publish!(
        task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
      )

      assert_equal :posted, result,
                   "quoted header substring in unrelated comment must NOT dedupe"
    end
  end

  def test_comment_page_cap_fails_closed
    # H7: when GitHub's pagination cap is hit we cannot prove no
    # earlier match exists. Fail-closed (treat as already-posted) so
    # we do not spam duplicates on long-tailed PRs.
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "- [ ] finding\n")
      ENV["HIVE_FAKE_GH_COMMENT_COUNT"] = "100"

      out, err = capture_io do
        result = Hive::Stages::Review::GithubPublisher.publish!(
          task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
        )
        assert_equal :already_posted, result
      end
      assert_match(/page cap/, err, "page-cap warning must surface (got out=#{out.inspect} err=#{err.inspect})")
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
  def test_missing_body_skips_before_reading_pr_context
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "missing.md")

      assert_equal :missing_body,
                   Hive::Stages::Review::GithubPublisher.publish!(
                     task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
                   )
    end
  end

  def test_network_failure_returns_failed_without_raising
    # plan U4 scenario: when gh exits non-zero on every attempt, the
    # publisher must return :failed (warn, do not raise) so the
    # review loop continues with the local file as authoritative.
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "- [ ] finding\n")
      ENV["HIVE_FAKE_GH_COMMENT_EXIT"] = "1"

      _out, err = capture_io do
        result = Hive::Stages::Review::GithubPublisher.publish!(
          task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
        )
        assert_equal :failed, result
      end
      assert_match(/failed to post reviewer comment.*pass=01.*codex/, err)
    end
  end
  def test_network_failure_retries_with_backoff_and_warns_joined_stderr
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "- [ ] finding\n")
      ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
      failed = Hive::Gh::CommandStatus.new(exitstatus: 1)
      sleeps = []
      calls = []
      comment_responses = [ [ "", "temporary outage", failed ], [ "", "auth denied", failed ] ]

      with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*args, **_kwargs|
        calls << args
        if args[2] == "view"
          [ '{"comments":[]}', "", ok ]
        elsif args[2] == "comment"
          comment_responses.shift
        else
          raise "unexpected gh call: #{args.inspect}"
        end
      }) do
        with_replaced_singleton_method(Hive::Stages::Review::GithubPublisher, :sleep, lambda { |seconds|
          sleeps << seconds
        }) do
          _out, err = capture_io do
            result = Hive::Stages::Review::GithubPublisher.publish!(
              task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg(max_attempts: 2)
            )
            assert_equal :failed, result
          end
          assert_match(/temporary outage; auth denied/, err)
        end
      end

      assert_equal [ 1 ], sleeps
      assert_equal 2, calls.count { |args| args[2] == "comment" }
    end
  end

  def test_body_with_only_section_headers_returns_no_findings_without_posting
    # A reviewer that found nothing still writes the High/Medium/Nit
    # section headers per the reviewer prompt; posting that empty
    # skeleton is pure noise. Publisher must short-circuit to
    # :no_findings before calling `gh pr comment`.
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "## High\n\n## Medium\n\n## Nit\n")

      result = Hive::Stages::Review::GithubPublisher.publish!(
        task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
      )

      assert_equal :no_findings, result
      log_path = File.join(@log_dir, "fake-gh-argv.log")
      log = File.exist?(log_path) ? File.read(log_path) : ""
      refute_includes log, "arg=comment\n",
                      "no-findings short-circuit must NOT invoke `gh pr comment`"
    end
  end

  def test_body_with_checked_finding_still_posts
    # `[x]` lines are the triage-accepted-auto-fix signal — still a
    # finding worth surfacing on the PR. Guard the no-findings
    # short-circuit so it only fires when literally zero checkbox
    # lines exist.
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "## High\n\n- [x] fixed by triage\n")

      result = Hive::Stages::Review::GithubPublisher.publish!(
        task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
      )

      assert_equal :posted, result
    end
  end

  def test_file_read_error_returns_failed_with_relative_body_path
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "- [ ] finding\n")
      original_read = File.method(:read)

      _out, err = with_replaced_singleton_method(File, :read, lambda { |path, *args, **kwargs|
        raise Errno::EACCES, "blocked" if path == body

        original_read.call(path, *args, **kwargs)
      }) do
        capture_io do
          result = Hive::Stages::Review::GithubPublisher.publish!(
            task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
          )
          assert_equal :failed, result
        end
      end

      assert_match(%r{local file at reviews/codex-01\.md is authoritative}, err)
      assert_match(/Errno::EACCES/, err)
    end
  end

  def test_already_posted_returns_false_when_view_fails_or_json_is_unusable
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    failed = Hive::Gh::CommandStatus.new(exitstatus: 1)

    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_args, **_kwargs) { [ "", "boom", failed ] }) do
      assert_equal false, Hive::Stages::Review::GithubPublisher.already_posted?("https://example.com/pr/1", "header")
    end

    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_args, **_kwargs) { [ "not-json", "", ok ] }) do
      assert_equal false, Hive::Stages::Review::GithubPublisher.already_posted?("https://example.com/pr/1", "header")
    end

    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_args, **_kwargs) { [ "[]", "", ok ] }) do
      assert_equal false, Hive::Stages::Review::GithubPublisher.already_posted?("https://example.com/pr/1", "header")
    end
  end

  def test_secret_in_reviewer_body_returns_secret_without_posting
    # plan Risk #3: a reviewer body that contains a credential
    # pattern must short-circuit to :secret with zero `gh pr comment`
    # calls.
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "- [ ] leaked key: sk-ant-#{'a' * 30}\n")

      _out, err = capture_io do
        result = Hive::Stages::Review::GithubPublisher.publish!(
          task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
        )
        assert_equal :secret, result
      end
      assert_match(/secret patterns=/, err)
      log_path = File.join(@log_dir, "fake-gh-argv.log")
      log = File.exist?(log_path) ? File.read(log_path) : ""
      refute_includes log, "arg=comment\n",
                      "secret short-circuit must NOT invoke `gh pr comment`"
    end
  end
end
