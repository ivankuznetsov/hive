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
      pr_url: https://github.com/acme/app/pull/42
      pr_number: 42
      ---

      <!-- COMPLETE pr_url=https://github.com/acme/app/pull/42 is_draft=true -->
    MD
    Hive::Task.new(folder)
  end

  def publish_review!(task, **kwargs)
    path = File.join(task.folder, "pr.md")
    url = Hive::Gh.pr_frontmatter(path)["pr_url"].to_s
    with_replaced_singleton_method(
      Hive::Stages::Review::GithubPublisher,
      :validated_pr_url,
      ->(_task, _cfg) { url.empty? ? nil : url }
    ) do
      Hive::Stages::Review::GithubPublisher.publish!(task, **kwargs)
    end
  end

  def cfg(enabled: true, max_attempts: 1)
    { "review" => { "github_publish" => { "enabled" => enabled, "max_attempts" => max_attempts } } }
  end


  def test_posts_review_comment
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "- [ ] finding\n")

      result = publish_review!(
        task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
      )

      assert_equal :posted, result
      log = File.read(File.join(@log_dir, "fake-gh-argv.log"))
      assert_includes log, "arg=comment\n"
      assert_includes log, "arg=https://github.com/acme/app/pull/42\n"

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

  def test_forged_cross_repository_pr_url_is_inert
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "- [ ] finding\n")
      File.write(File.join(task.folder, "pr.md"), <<~MD)
        ---
        pr_url: https://github.com/unrelated/project/pull/999
        pr_number: 999
        head_oid: #{"a" * 40}
        ---

        <!-- COMPLETE pr_url=https://github.com/unrelated/project/pull/999 is_draft=true -->
      MD

      with_replaced_singleton_method(
        Hive::Worktree, :canonical_root, ->(_root) { "/owned" }
      ) do
        with_replaced_singleton_method(
          Hive::Worktree, :read_owned_pointer,
          ->(*_args, **_kwargs) { { "path" => "/owned/task", "branch" => task.slug } }
        ) do
          with_replaced_singleton_method(
            Hive::Gh, :repository_identity,
            ->(*_args, **_kwargs) { { "host" => "github.com", "repository" => "acme/app" } }
          ) do
            with_replaced_singleton_method(
              Hive::Gh, :lookup_prs_for_branch,
              ->(*_args, **_kwargs) { flunk "cross-repository URL must be inert before PR lookup" }
            ) do
              result = Hive::Stages::Review::GithubPublisher.validated_pr_url(task, cfg)
              assert_nil result
            end
          end
        end
      end
    end
  end

  def test_publish_skips_an_invalid_pr_url_before_any_remote_effect
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "- [ ] finding\n")
      File.write(File.join(task.folder, "pr.md"), "---\npr_url: not-a-pr\n---\n")

      assert_equal :invalid_pr,
                   Hive::Stages::Review::GithubPublisher.publish!(
                     task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
                   )
      refute File.exist?(File.join(@log_dir, "fake-gh-argv.log"))
    end
  end

  def test_validated_pr_url_fails_closed_when_repository_identity_cannot_be_read
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(File.join(task.folder, "pr.md"), <<~MD)
        ---
        pr_url: https://github.com/acme/app/pull/42
        head_oid: #{"a" * 40}
        ---
      MD

      with_replaced_singleton_method(
        Hive::Worktree, :canonical_root, ->(_root) { raise Hive::GhError, "identity offline" }
      ) do
        assert_nil Hive::Stages::Review::GithubPublisher.validated_pr_url(task, cfg)
      end
    end
  end

  def test_validated_pr_url_binds_the_live_pr_not_a_saved_commit
    with_tmp_dir do |dir|
      task = make_task(dir)
      head = "a" * 40
      File.write(File.join(task.folder, "pr.md"), <<~MD)
        ---
        pr_url: https://github.com/acme/app/pull/42
        pr_number: 42
        head_oid: #{head}
        ---

        <!-- COMPLETE pr_url=https://github.com/acme/app/pull/42 is_draft=true -->
      MD
      observed = {
        "url" => "https://github.com/acme/app/pull/42",
        "number" => 42,
        "state" => "OPEN",
        "headRefName" => task.slug,
        "headRefOid" => head
      }
      candidates = [ observed ]
      test_case = self

      with_replaced_singleton_method(
        Hive::Worktree, :canonical_root, ->(_root) { "/owned" }
      ) do
        with_replaced_singleton_method(
          Hive::Worktree, :read_owned_pointer,
          ->(*_args, **_kwargs) { { "path" => "/owned/task", "branch" => task.slug } }
        ) do
          with_replaced_singleton_method(
            Hive::Gh, :repository_identity,
            ->(*_args, **_kwargs) { { "host" => "github.com", "repository" => "acme/app" } }
          ) do
            with_replaced_singleton_method(
              Hive::Gh, :lookup_prs_for_branch,
              ->(_path, branch, cfg:) do
                test_case.assert_equal task.slug, branch
                candidates
              end
            ) do
              assert_equal(
                "https://github.com/acme/app/pull/42",
                Hive::Stages::Review::GithubPublisher.validated_pr_url(task, cfg)
              )
              candidates = [ observed.merge("headRefOid" => "b" * 40) ]
              assert_equal observed.fetch("url"),
                           Hive::Stages::Review::GithubPublisher.validated_pr_url(task, cfg)
              File.write(File.join(task.folder, "pr.md"), "---\npr_url: #{observed.fetch('url')}\n---\n")
              assert_equal observed.fetch("url"),
                           Hive::Stages::Review::GithubPublisher.validated_pr_url(task, cfg)
              [ { "headRefName" => "other-branch" }, { "number" => 43 },
                { "state" => "CLOSED" }, { "url" => "https://github.com/acme/app/pull/43" } ].each do |change|
                candidates = [ observed.merge(change) ]
                assert_nil Hive::Stages::Review::GithubPublisher.validated_pr_url(task, cfg)
              end
              candidates = [ observed, observed ]
              assert_nil Hive::Stages::Review::GithubPublisher.validated_pr_url(task, cfg)
            end
          end
        end
      end
    end
  end

  def test_skips_duplicate_header_per_comment_line_anchored
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "- [ ] finding\n")
      # Single comment whose body starts with our header → dedupe.
      ENV["HIVE_FAKE_GH_COMMENTS_BODY"] = "### Reviewer: codex - Pass 01\n\nold"

      result = publish_review!(
        task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
      )

      assert_equal :already_posted, result
      log = File.read(File.join(@log_dir, "fake-gh-argv.log"))
      refute_includes log, "arg=comment\n"
    end
  end

  def test_rewound_generation_posts_past_the_archived_pass_comment
    with_tmp_dir do |dir|
      task = make_task(dir)
      FileUtils.mkdir_p(File.join(task.reviews_dir, "archive", "rewind-8-finalize-to-6-review"))
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "- [ ] new finding\n")
      # The archived generation already posted its pass 01 comment.
      ENV["HIVE_FAKE_GH_COMMENTS_BODY"] = "### Reviewer: codex - Pass 01\n\nold"

      result = publish_review!(
        task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
      )

      assert_equal :posted, result
      log = File.read(File.join(@log_dir, "fake-gh-argv.log"))
      posted = log[/body_content<<EOF\n(.*?)\nEOF\n/m, 1]
      assert_match(/\A### Reviewer: codex - Pass 01 \(review generation 2\)\n\n.*new finding/m, posted)
    end
  end

  def test_rewound_generation_still_dedupes_its_own_pass_comment
    with_tmp_dir do |dir|
      task = make_task(dir)
      FileUtils.mkdir_p(File.join(task.reviews_dir, "archive", "rewind-8-finalize-to-6-review"))
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "- [ ] new finding\n")
      ENV["HIVE_FAKE_GH_COMMENTS_BODY"] = "### Reviewer: codex - Pass 01 (review generation 2)\n\nfirst run"

      result = publish_review!(
        task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
      )

      assert_equal :already_posted, result
      refute_includes File.read(File.join(@log_dir, "fake-gh-argv.log")), "arg=comment\n"
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

      result = publish_review!(
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
        result = publish_review!(
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
                   publish_review!(
                     task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg(enabled: false)
                   )
    end
  end
  def test_missing_body_skips_before_reading_pr_context
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "missing.md")

      assert_equal :missing_body,
                   publish_review!(
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
        result = publish_review!(
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
            result = publish_review!(
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

      result = publish_review!(
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

      result = publish_review!(
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
          result = publish_review!(
            task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
          )
          assert_equal :failed, result
        end
      end

      assert_match(%r{local file at reviews/codex-01\.md is authoritative}, err)
      assert_match(/Errno::EACCES/, err)
    end
  end

  def test_already_posted_forwards_cfg_to_configured_github_invocation
    # Patrol regression: the duplicate-prevention `gh pr view` call used to
    # omit cfg, so it ignored `gh.network_timeout_sec` while the adjacent
    # `gh pr comment` call honored it. Both must route through the same
    # configured invocation path.
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    observed_kwargs = nil
    test_cfg = { "gh" => { "network_timeout_sec" => 7 } }

    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*_args, **kwargs|
      observed_kwargs = kwargs
      [ '{"comments":[]}', "", ok ]
    }) do
      assert_equal false, Hive::Stages::Review::GithubPublisher.already_posted?("https://example.com/pr/1", "header", cfg: test_cfg)
    end

    assert_equal test_cfg, observed_kwargs[:cfg],
                 "duplicate-prevention lookup must pass cfg through to Hive::Gh.capture3"
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
      File.write(body, "- [ ] leaked key: ghp_#{"aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"}\n")

      _out, err = capture_io do
        result = publish_review!(
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

  def test_validated_internal_pr_url_accepts_feature_branch_and_fork_and_rejects_mismatches
    require "hive/internal_pr_checkout"
    with_tmp_dir do |dir|
      head_oid = "a" * 40
      task = make_internal_pr_task(dir, pr_number: 42, head_oid: head_oid)
      identity = Hive::InternalPrCheckout::Identity.resolve!(task)

      view_meta = Hive::Gh::PrMetadata.new(
        number: 42,
        url: "https://github.com/acme/app/pull/42",
        base_ref_name: "main",
        head_ref_name: "alice/fix-login-completely-different-branch",
        head_ref_oid: head_oid,
        head_repository: "acme/app",
        is_cross_repository: false,
        state: "OPEN",
        is_draft: false
      )

      test_case = self
      with_replaced_singleton_method(
        Hive::Worktree, :read_owned_pointer,
        ->(*_args, **kwargs) do
          test_case.assert_equal "hive/review/pr-42", kwargs[:expected_branch]
          { "path" => identity.expected_worktree_path, "branch" => "hive/review/pr-42" }
        end
      ) do
        with_replaced_singleton_method(
          Hive::Gh, :repository_identity,
          ->(*_args, **_kwargs) { { "host" => "github.com", "repository" => "acme/app" } }
        ) do
          with_replaced_singleton_method(Hive::Gh, :validated_pr_metadata, ->(*_args, **_kwargs) { view_meta }) do
            assert_equal "https://github.com/acme/app/pull/42",
                         Hive::Stages::Review::GithubPublisher.validated_pr_url(task, cfg),
                         "differently named remote feature branch must be valid"

            # Fork PR matching stored cross-repo metadata
            fork_task = make_internal_pr_task(
              dir, pr_number: 43, head_oid: head_oid,
                   is_cross_repository: true, head_repository: "fork-owner/app"
            )
            fork_identity = Hive::InternalPrCheckout::Identity.resolve!(fork_task)
            view_meta = Hive::Gh::PrMetadata.new(
              number: 43,
              url: "https://github.com/acme/app/pull/43",
              base_ref_name: "main",
              head_ref_name: "patch-1",
              head_ref_oid: head_oid,
              head_repository: "fork-owner/app",
              is_cross_repository: true,
              state: "OPEN",
              is_draft: false
            )
            with_replaced_singleton_method(
              Hive::Worktree, :read_owned_pointer,
              ->(*_args, **kwargs) do
                test_case.assert_equal "hive/review/pr-43", kwargs[:expected_branch]
                { "path" => fork_identity.expected_worktree_path, "branch" => "hive/review/pr-43" }
              end
            ) do
              assert_equal "https://github.com/acme/app/pull/43",
                           Hive::Stages::Review::GithubPublisher.validated_pr_url(fork_task, cfg),
                           "fork PR matching canonical head_repository must be valid"

              # Mismatched fork identity -> nil
              view_meta = view_meta.with(head_repository: "other-fork/app")
              assert_nil Hive::Stages::Review::GithubPublisher.validated_pr_url(fork_task, cfg)
            end

            # Mismatched number, URL, head OID, or repository -> nil
            base_meta = Hive::Gh::PrMetadata.new(
              number: 42,
              url: "https://github.com/acme/app/pull/42",
              base_ref_name: "main",
              head_ref_name: "alice/fix-login",
              head_ref_oid: head_oid,
              head_repository: "acme/app",
              is_cross_repository: false,
              state: "OPEN",
              is_draft: false
            )
            [
              { number: 99 },
              { url: "https://github.com/acme/app/pull/99" },
              { url: "https://github.com/evil/other/pull/42" },
              { head_ref_oid: "b" * 40 }
            ].each do |bad|
              view_meta = base_meta.with(**bad)
              assert_nil Hive::Stages::Review::GithubPublisher.validated_pr_url(task, cfg),
                         "mismatched #{bad.keys.join(',')} must return nil"
            end
          end
        end
      end
    end
  end

  def test_internal_pr_review_publish_and_fix_publication_are_strictly_local_only
    require "hive/internal_pr_checkout"
    require "hive/stages/review/publication"
    with_tmp_dir do |dir|
      head_oid = "a" * 40
      task = make_internal_pr_task(dir, pr_number: 42, head_oid: head_oid)
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "- [ ] finding\n")

      adhoc_fix_cfg = cfg(enabled: true).merge("review" => {
        "github_publish" => { "enabled" => true, "max_attempts" => 1 },
        "adhoc" => { "fix" => true }
      })

      comment_result = Hive::Stages::Review::GithubPublisher.publish!(
        task, pass: 1, reviewer_name: "codex", body_path: body, cfg: adhoc_fix_cfg
      )
      assert_equal :not_applicable, comment_result
      refute File.exist?(File.join(@log_dir, "fake-gh-argv.log")),
             "internal PR comment publish must invoke zero gh commands"

      fail_gate = Object.new
      fail_gate.define_singleton_method(:execute) { |*| flunk "push gate must never be called for internal PR review" }
      fail_gh = Object.new
      fail_gh.define_singleton_method(:capture3) { |*| flunk "gh must never be called for internal PR fix publication" }
      ctx = Hive::Reviewers::Context.new(
        worktree_path: dir, task_folder: task.folder, default_branch: "main", pass: 1
      )
      pub = Hive::Stages::Review::Publication.new(
        task: task, cfg: adhoc_fix_cfg, ctx: ctx,
        pr_url: "https://github.com/acme/app/pull/42",
        gh: fail_gh, gate: fail_gate
      )
      pub.publish!(expected_head: head_oid)
      assert_equal "not_applicable", pub.evidence["publication"]
      assert_equal "not_applicable", pub.evidence["verification"]
      refute File.exist?(File.join(task.folder, "github-publication.json")),
             "internal PR fix publication must not write github-publication.json"
    end
  end

  def test_ordinary_review_repush_adoption_posts_generation_two_and_dedupes_replay
    require "hive/stages/review/pass_archive"
    with_tmp_dir do |dir|
      task = make_task(dir)
      body = File.join(task.reviews_dir, "codex-01.md")
      File.write(body, "- [ ] gen 1 finding\n")
      assert_equal "### Reviewer: codex - Pass 01",
                   Hive::Stages::Review::GithubPublisher.comment_header(task, "codex", 1)

      Hive::Stages::Review::PassArchive.retire!(
        task, label: "repush-ff-adoption", expiry_reason: "remote_fast_forward_adopted"
      )
      File.write(body, "- [ ] gen 2 finding\n")
      assert_equal "### Reviewer: codex - Pass 01 (review generation 2)",
                   Hive::Stages::Review::GithubPublisher.comment_header(task, "codex", 1)

      ENV["HIVE_FAKE_GH_COMMENTS_BODY"] = "### Reviewer: codex - Pass 01\n\ngen 1 comment"
      assert_equal :posted, publish_review!(
        task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
      )
      log = File.read(File.join(@log_dir, "fake-gh-argv.log"))
      assert_includes log, "### Reviewer: codex - Pass 01 (review generation 2)"

      # Replay with gen 2 comment already present dedupes cleanly
      FileUtils.rm_f(File.join(@log_dir, "fake-gh-argv.log"))
      ENV["HIVE_FAKE_GH_COMMENTS_BODY"] = "### Reviewer: codex - Pass 01 (review generation 2)\n\ngen 2 comment"
      assert_equal :already_posted, publish_review!(
        task, pass: 1, reviewer_name: "codex", body_path: body, cfg: cfg
      )
      refute_includes File.read(File.join(@log_dir, "fake-gh-argv.log")), "arg=comment\n"
    end
  end

  private

  def make_internal_pr_task(dir, pr_number:, head_oid:, is_cross_repository: false, head_repository: "acme/app")
    slug = Hive::InternalPrCheckout::Identity.slug_for(pr_number)
    folder = File.join(dir, ".hive-state", "stages", "6-review", slug)
    FileUtils.mkdir_p(File.join(folder, "reviews"))
    File.write(File.join(folder, "task.md"), "---\nsource: ad-hoc\n---\n\n# PR #{pr_number}\n")
    File.write(File.join(folder, "pr.md"), <<~MD)
      ---
      source: ad-hoc
      pr_number: #{pr_number}
      pr_url: https://github.com/acme/app/pull/#{pr_number}
      head_oid: #{head_oid}
      base_ref_name: main
      head_ref_name: feat
      head_repository: #{head_repository}
      is_cross_repository: #{is_cross_repository}
      pr_state: OPEN
      ---
    MD
    store = Hive::InternalPrCheckout::Store.new(folder)
    store.initialize_generation_one!(
      task_id: format("%04d", pr_number), task_slug: slug, project: File.basename(dir),
      pr_host: "github.com", pr_repository: "acme/app", pr_number: pr_number,
      pr_url: "https://github.com/acme/app/pull/#{pr_number}",
      base_ref_name: "main", head_ref_name: "feat", head_repository: head_repository,
      is_cross_repository: is_cross_repository, pr_state: "OPEN",
      branch: Hive::InternalPrCheckout::Identity.branch_for(pr_number),
      head_oid: head_oid, committed_at: Time.utc(2026, 8, 29, 12, 0, 0)
    )
    Hive::Task.new(folder)
  end
end
