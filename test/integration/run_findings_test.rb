require "test_helper"
require "json"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/findings"
require "hive/commands/finding_toggle"

class RunFindingsTest < Minitest::Test
  include HiveTestHelper

  REVIEW_BODY = <<~MD
    # ce-review pass 02

    ## High
    - [ ] memory leak in worker pool: process_pool doesn't drain on shutdown
    - [x] missing rate limit on /api/upload: 100req/s burst seen in load test

    ## Medium
    - [ ] redundant validation in form_helper.rb: server-side already validates
    - [ ] N+1 query on dashboard: profile run shows 250 SELECTs

    ## Nit
    - [ ] typo in error message
  MD

  # Set up an execute-stage task with a review file present so the three
  # commands have something to operate on.
  def seed_execute_task_with_reviews(dir, body: REVIEW_BODY, pass: 2)
    capture_io { Hive::Commands::Init.new(dir).call }
    project = File.basename(dir)
    capture_io { Hive::Commands::New.new(project, "review probe").call }
    inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
    slug = File.basename(inbox)
    execute_dir = File.join(dir, ".hive-state", "stages", "4-execute", slug)
    FileUtils.mkdir_p(File.dirname(execute_dir))
    FileUtils.mv(inbox, execute_dir)

    reviews_dir = File.join(execute_dir, "reviews")
    FileUtils.mkdir_p(reviews_dir)
    File.write(File.join(reviews_dir, format("ce-review-%02d.md", pass)), body)
    [ project, execute_dir, slug ]
  end

  # ── findings (list) ────────────────────────────────────────────────────

  def test_findings_text_lists_each_with_id_and_severity
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, _execute, slug = seed_execute_task_with_reviews(dir)
        out, _err = capture_io { Hive::Commands::Findings.new(slug).call }
        assert_includes out, "findings for #{slug}"
        assert_includes out, "## high"
        assert_includes out, "[ ] #1 memory leak"
        assert_includes out, "[x] #2 missing rate limit"
        assert_includes out, "[ ] #5 typo in error message"
      end
    end
  end

  def test_findings_json_pins_full_schema
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, execute, slug = seed_execute_task_with_reviews(dir)
        out, _err = capture_io { Hive::Commands::Findings.new(slug, json: true).call }
        payload = JSON.parse(out)

        expected_keys = %w[
          schema schema_version ok slug stage stage_dir
          task_folder review_file pass findings summary
        ].sort
        assert_equal expected_keys, payload.keys.sort

        assert_equal "hive-findings", payload["schema"]
        assert_equal 1, payload["schema_version"]
        assert_equal true, payload["ok"]
        assert_equal slug, payload["slug"]
        assert_equal "execute", payload["stage"]
        assert_equal "4-execute", payload["stage_dir"]
        assert_equal execute, payload["task_folder"]
        assert payload["review_file"].end_with?("ce-review-02.md")
        assert_equal 2, payload["pass"]

        assert_equal 5, payload["findings"].size
        first = payload["findings"][0]
        assert_equal({ "folder" => nil, "id" => 1, "severity" => "high",
                       "accepted" => false }.values_at("id", "severity", "accepted"),
                     first.values_at("id", "severity", "accepted"))
        assert_equal "memory leak in worker pool", first["title"]

        assert_equal 5, payload["summary"]["total"]
        assert_equal 1, payload["summary"]["accepted"]
        assert_equal({ "high" => 2, "medium" => 2, "nit" => 1 }, payload["summary"]["by_severity"])
      end
    end
  end

  def test_findings_pass_picks_named_pass_file
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, execute, slug = seed_execute_task_with_reviews(dir, pass: 2)
        File.write(File.join(execute, "reviews", "ce-review-01.md"),
                   "## High\n- [ ] earlier\n")

        out, _err = capture_io { Hive::Commands::Findings.new(slug, pass: 1, json: true).call }
        payload = JSON.parse(out)
        assert_equal 1, payload["pass"]
        assert_equal 1, payload["findings"].size
        assert_equal "earlier", payload["findings"][0]["title"]
      end
    end
  end

  def test_findings_no_review_file_emits_typed_error_and_envelope
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        capture_io { Hive::Commands::New.new(File.basename(dir), "no reviews here").call }
        slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)

        out, err, status = with_captured_exit { Hive::Commands::Findings.new(slug, json: true).call }
        assert_equal Hive::ExitCodes::USAGE, status

        payload = JSON.parse(out)
        assert_equal "no_review_file", payload["error_kind"]
        assert_equal "NoReviewFile", payload["error_class"]
        assert_includes err, "no review files"
      end
    end
  end

  # ── accept-finding ─────────────────────────────────────────────────────

  def test_accept_finding_by_id_flips_checkbox_and_commits
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, execute, slug = seed_execute_task_with_reviews(dir)
        capture_io do
          Hive::Commands::FindingToggle.new(
            Hive::Commands::FindingToggle::ACCEPT, slug, ids: [ 1 ]
          ).call
        end

        body = File.read(File.join(execute, "reviews", "ce-review-02.md"))
        assert_match(/^- \[x\] memory leak/, body, "id 1 must be ticked")
        # Surrounding findings untouched.
        assert_match(/^- \[x\] missing rate limit/, body)
        assert_match(/^- \[ \] redundant validation/, body)

        log = `git -C #{File.join(dir, ".hive-state")} log --format=%s -1`.strip
        assert_match(/accept findings 1 in ce-review-02\.md/, log)
      end
    end
  end

  def test_accept_finding_severity_filter_picks_all_of_one_severity
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, execute, slug = seed_execute_task_with_reviews(dir)
        out, _err = capture_io do
          Hive::Commands::FindingToggle.new(
            Hive::Commands::FindingToggle::ACCEPT, slug, severity: "medium", json: true
          ).call
        end

        payload = JSON.parse(out)
        assert_equal "accept", payload["operation"]
        assert_equal [ 3, 4 ], payload["selected_ids"].sort
        assert_equal 2, payload["changes"].size
        assert_equal 3, payload["summary"]["accepted"], "high.1 + medium.0 + medium.1 now accepted"

        body = File.read(File.join(execute, "reviews", "ce-review-02.md"))
        assert_match(/^- \[x\] redundant validation/, body)
        assert_match(/^- \[x\] N\+1 query/, body)
        # Nit untouched.
        assert_match(/^- \[ \] typo in error message/, body)
      end
    end
  end

  def test_accept_finding_all_accepts_every_finding
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, execute, slug = seed_execute_task_with_reviews(dir)
        out, _err = capture_io do
          Hive::Commands::FindingToggle.new(
            Hive::Commands::FindingToggle::ACCEPT, slug, all: true, json: true
          ).call
        end

        payload = JSON.parse(out)
        assert_equal 5, payload["summary"]["accepted"]
        # id 2 was already accepted — that's a no-op, so changes excludes it.
        assert_equal 4, payload["changes"].size
        refute payload["noop"]

        body = File.read(File.join(execute, "reviews", "ce-review-02.md"))
        assert_equal 5, body.scan(/^- \[x\]/).size
      end
    end
  end

  def test_accept_finding_idempotent_returns_noop
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        seed_execute_task_with_reviews(dir)
        slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "4-execute", "*")].first)

        # id 2 is already accepted in the fixture.
        out, _err = capture_io do
          Hive::Commands::FindingToggle.new(
            Hive::Commands::FindingToggle::ACCEPT, slug, ids: [ 2 ], json: true
          ).call
        end

        payload = JSON.parse(out)
        assert payload["noop"], "already-accepted toggle must report noop"
        assert_equal [], payload["changes"]
      end
    end
  end

  def test_accept_finding_unknown_id_raises_typed_with_envelope
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, _execute, slug = seed_execute_task_with_reviews(dir)
        out, _err, status = with_captured_exit do
          Hive::Commands::FindingToggle.new(
            Hive::Commands::FindingToggle::ACCEPT, slug, ids: [ 99 ], json: true
          ).call
        end
        assert_equal Hive::ExitCodes::USAGE, status

        payload = JSON.parse(out)
        assert_equal "unknown_finding", payload["error_kind"]
        assert_equal 99, payload["id"]
      end
    end
  end

  def test_accept_finding_rejects_malformed_id_without_mutating
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, execute, slug = seed_execute_task_with_reviews(dir)
        review_path = File.join(execute, "reviews", "ce-review-02.md")
        original = File.read(review_path)

        out, _err, status = with_captured_exit do
          Hive::Commands::FindingToggle.new(
            Hive::Commands::FindingToggle::ACCEPT, slug, ids: [ "2foo" ], json: true
          ).call
        end

        assert_equal Hive::ExitCodes::USAGE, status
        payload = JSON.parse(out)
        assert_equal "invalid_task_path", payload["error_kind"]
        assert_includes payload["message"], "invalid finding id"
        assert_equal original, File.read(review_path),
                     "malformed IDs must not be coerced into valid finding IDs"
      end
    end
  end

  def test_accept_finding_with_no_selectors_errors
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, _execute, slug = seed_execute_task_with_reviews(dir)
        _, err, status = with_captured_exit do
          Hive::Commands::FindingToggle.new(
            Hive::Commands::FindingToggle::ACCEPT, slug
          ).call
        end
        assert_equal Hive::ExitCodes::USAGE, status
        assert_includes err, "no findings selected"
      end
    end
  end

  def test_accept_finding_commit_failure_rolls_review_file_back
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, execute, slug = seed_execute_task_with_reviews(dir)
        review_path = File.join(execute, "reviews", "ce-review-02.md")
        rel = review_path.sub("#{File.join(dir, ".hive-state")}/", "")
        original = File.read(review_path)

        hooks_dir = File.join(dir, ".git", "hooks")
        FileUtils.mkdir_p(hooks_dir)
        hook_path = File.join(hooks_dir, "pre-commit")
        File.write(hook_path, "#!/bin/sh\nexit 1\n")
        FileUtils.chmod(0o755, hook_path)

        _, err, status = with_captured_exit do
          Hive::Commands::FindingToggle.new(
            Hive::Commands::FindingToggle::ACCEPT, slug, ids: [ 1 ]
          ).call
        end

        assert_equal Hive::ExitCodes::SOFTWARE, status
        assert_includes err, "commit"
        assert_equal original, File.read(review_path),
                     "commit failure must not leave the checkbox changed without an audit commit"
        staged = `git -C #{File.join(dir, ".hive-state").shellescape} diff --cached --name-only`
        refute_includes staged.lines.map(&:strip), rel,
                        "failed toggle must unstage the review file so a retry can commit it"

        FileUtils.rm_f(hook_path)
        capture_io do
          Hive::Commands::FindingToggle.new(
            Hive::Commands::FindingToggle::ACCEPT, slug, ids: [ 1 ]
          ).call
        end
        assert_match(/^- \[x\] memory leak/, File.read(review_path))
      end
    end
  end

  # ── reject-finding ─────────────────────────────────────────────────────

  def test_reject_finding_unticks_an_accepted_finding
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, execute, slug = seed_execute_task_with_reviews(dir)
        capture_io do
          Hive::Commands::FindingToggle.new(
            Hive::Commands::FindingToggle::REJECT, slug, ids: [ 2 ]
          ).call
        end

        body = File.read(File.join(execute, "reviews", "ce-review-02.md"))
        assert_match(/^- \[ \] missing rate limit/, body)

        log = `git -C #{File.join(dir, ".hive-state")} log --format=%s -1`.strip
        assert_match(/reject findings 2 in ce-review-02\.md/, log)
      end
    end
  end

  def test_reject_finding_idempotent_on_already_unchecked
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, _execute, slug = seed_execute_task_with_reviews(dir)
        out, _err = capture_io do
          Hive::Commands::FindingToggle.new(
            Hive::Commands::FindingToggle::REJECT, slug, ids: [ 1 ], json: true
          ).call
        end
        payload = JSON.parse(out)
        assert payload["noop"]
        assert_equal [], payload["changes"]
      end
    end
  end

  # ── Lock semantics ─────────────────────────────────────────────────────

  def test_toggle_takes_task_lock_and_serialises_with_concurrent_run
    # The command takes Hive::Lock.with_task_lock(task.folder, ...). A
    # second invocation with the lock held must surface ConcurrentRunError
    # (TEMPFAIL, exit 75) rather than racing.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _, execute, slug = seed_execute_task_with_reviews(dir)
        Hive::Lock.acquire_task_lock(execute, slug: slug, op: "fake_run")
        begin
          _, err, status = with_captured_exit do
            Hive::Commands::FindingToggle.new(
              Hive::Commands::FindingToggle::ACCEPT, slug, ids: [ 1 ]
            ).call
          end
          assert_equal Hive::ExitCodes::TEMPFAIL, status,
                       "toggle must serialise via task lock"
          assert_includes err, "another hive run is active"
        ensure
          Hive::Lock.release_task_lock(execute)
        end
      end
    end
  end
end
