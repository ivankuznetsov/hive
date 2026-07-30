require "test_helper"
require "json"
require "yaml"
require "hive/config"
require "hive/patrol/finding"
require "hive/patrol/review_handoff"

class HivePatrolReviewHandoffTest < Minitest::Test
  include HiveTestHelper

  Patch = Struct.new(:branch, :worktree_path, :head_sha, :validation, keyword_init: true)

  def finding(**overrides)
    defaults = {
      id: "f1", feature_id: "feature", category: "bug", severity: "high",
      confidence: "medium", title: "Fix bug", description: "bug details",
      recommendation: "fix it",
      scope: "cross_feature",
      contract: "Every accepted job must eventually be delivered.",
      impact: "Accepted jobs disappear without an error.",
      root_cause: "The handoff clears durable state before acknowledgement.",
      reproduction: "Interrupt the handoff after dequeue and before acknowledgement.",
      validation: "Run the interruption regression and delivery suite.",
      evidence: [ { "file" => "app.rb", "line" => 1, "snippet" => "puts" } ],
      alpha_score: 88,
      fingerprint: "fp1"
    }
    Hive::Patrol::Finding.new(**defaults.merge(overrides))
  end

  def patch(dir, **overrides)
    defaults = {
      branch: "hive-patrol/feature-fp1", worktree_path: dir, head_sha: "abc123", validation: {}
    }
    Patch.new(**defaults.merge(overrides))
  end

  def handoff(dir, review_prs: true, write_hook: nil)
    cfg = Hive::Config.deep_dup(Hive::Config::DEFAULTS)
    cfg["patrol"]["review_prs"] = review_prs
    Hive::Patrol::ReviewHandoff.new(dir, cfg: cfg, state: {}, write_hook: write_hook)
  end

  def with_task_counter(value = 42)
    with_replaced_singleton_method(Hive::TaskCounter, :next!, lambda { value }) do
      yield
    end
  end

  def test_slug_collides_within_6_review_and_gets_numeric_suffix
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state", "stages", "6-review", "patrol-feature-fp1"))

      folder = nil
      with_task_counter { folder = handoff(dir).enqueue(finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7") }

      assert_equal "patrol-feature-fp1-2", File.basename(folder),
                   "a slug already taken in 6-review must get a numeric suffix"
    end
  end

  def test_slug_is_unique_across_all_stages_not_just_6_review
    with_tmp_dir do |dir|
      # A synthetic task that already advanced past 6-review must still reserve
      # its slug, or the slug-derived worktree/log-dir paths would collide.
      FileUtils.mkdir_p(File.join(dir, ".hive-state", "stages", "9-done", "patrol-feature-fp1"))

      folder = nil
      with_task_counter { folder = handoff(dir).enqueue(finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7") }

      assert_equal "patrol-feature-fp1-2", File.basename(folder),
                   "slug uniqueness must scan every stage dir, not only 6-review"
    end
  end

  def test_enqueue_writes_idea_md_from_original_finding
    with_tmp_dir do |dir|
      folder = nil
      with_task_counter do
        folder = handoff(dir).enqueue(
          finding: finding,
          patch: patch(dir),
          pr_url: "https://example.com/pull/7",
          now: Time.utc(2026, 6, 5, 12, 0, 0)
        )
      end

      idea = File.read(File.join(folder, "idea.md"))
      frontmatter = YAML.safe_load(idea.split("---\n\n", 2).first)

      assert_equal "patrol", frontmatter.fetch("source")
      assert_equal "f1", frontmatter.fetch("patrol_finding_id")
      assert_equal "fp1", frontmatter.fetch("patrol_fingerprint")
      assert_includes frontmatter.fetch("original_text"), "Patrol: Fix bug"
      assert_includes idea, "## Finding"
      assert_includes idea, "bug details"
      assert_includes idea, "## Recommendation"
      assert_includes idea, "fix it"
      assert_includes idea, "## Alpha"
      assert_includes idea, "Score: `88`; scope: `cross_feature`"
      assert_includes idea, "## Contract and impact"
      assert_includes idea, "Every accepted job must eventually be delivered."
      assert_includes idea, "## Root cause"
      assert_includes idea, "The handoff clears durable state before acknowledgement."
      assert_includes idea, "## Reproduction and validation"
      assert_includes idea, "`app.rb:1`: puts"
    end
  end

  def test_reconcile_reports_exact_absence_then_the_published_task_without_writing
    with_tmp_dir do |dir|
      subject = handoff(dir)
      arguments = {
        finding: finding,
        patch: patch(dir),
        pr_url: "https://example.com/pull/7"
      }

      assert_equal(
        { "status" => "absent", "outcome" => {} },
        subject.reconcile(**arguments)
      )
      folder = nil
      with_task_counter { folder = subject.enqueue(**arguments) }
      before = Dir.glob(File.join(dir, ".hive-state", "**", "*"), File::FNM_DOTMATCH).sort

      assert_equal(
        {
          "status" => "matched",
          "outcome" => { "task_path" => folder }
        },
        subject.reconcile(**arguments)
      )
      assert_equal before,
                   Dir.glob(File.join(dir, ".hive-state", "**", "*"), File::FNM_DOTMATCH).sort
    end
  end

  def test_enqueue_writes_task_id_and_falls_back_to_null_when_counter_is_busy
    with_tmp_dir do |dir|
      folder = nil
      with_task_counter(123) do
        folder = handoff(dir).enqueue(finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7")
      end

      assert_equal 123, Hive::TaskMeta.read(folder)[:id]
      assert_equal "coding", Hive::TaskMeta.read(folder)[:workflow],
                   "the coding 6-review handoff must pin workflow: coding, not inherit the project default"
    end

    with_tmp_dir do |dir|
      with_replaced_singleton_method(Hive::TaskCounter, :next!, lambda { raise Hive::ConcurrentRunError, "busy" }) do
        folder = handoff(dir).enqueue(finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7")

        assert_nil Hive::TaskMeta.read(folder)[:id]
      end
    end
  end

  def test_enqueue_carries_observed_fix_proof_into_review_task
    with_tmp_dir do |dir|
      validation = {
        "fix_proof" => {
          "root_cause" => "The queue entry is removed before acknowledgement.",
          "audited_paths" => [ "lib/queue.rb", "test/queue_test.rb" ],
          "configured_command" => "bundle exec ruby test/queue_test.rb",
          "before" => { "exit_code" => 1, "timed_out" => false },
          "after" => { "exit_code" => 0, "timed_out" => false }
        }
      }

      folder = handoff(dir).enqueue(
        finding: finding, patch: patch(dir, validation: validation), pr_url: "https://example.com/pull/7"
      )
      task = File.read(File.join(folder, "task.md"))

      assert_includes task, "## Observed fix proof"
      assert_includes task, "**Agent-reported root cause:**"
      assert_includes task, "The queue entry is removed before acknowledgement."
      assert_includes task, "`bundle exec ruby test/queue_test.rb`"
      assert_includes task, "**Before:** exit=1 timed_out=false"
      assert_includes task, "**After:** exit=0 timed_out=false"
    end
  end

  def test_idea_md_omits_finding_section_when_description_blank
    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(
        finding: finding(description: "   "),
        patch: patch(dir),
        pr_url: "https://example.com/pull/7"
      )

      idea = File.read(File.join(folder, "idea.md"))
      refute_includes idea, "## Finding", "blank description must omit the Finding section"
      assert_includes idea, "## Recommendation", "other sections must still render"
    end
  end

  def test_idea_md_omits_recommendation_section_when_blank
    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(
        finding: finding(recommendation: ""),
        patch: patch(dir),
        pr_url: "https://example.com/pull/7"
      )

      idea = File.read(File.join(folder, "idea.md"))
      refute_includes idea, "## Recommendation", "blank recommendation must omit the Recommendation section"
      assert_includes idea, "## Finding", "other sections must still render"
    end
  end

  def test_idea_md_omits_evidence_section_when_evidence_empty
    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(
        finding: finding(evidence: []),
        patch: patch(dir),
        pr_url: "https://example.com/pull/7"
      )

      idea = File.read(File.join(folder, "idea.md"))
      refute_includes idea, "## Evidence", "empty evidence must omit the Evidence section"
    end
  end

  def test_idea_md_renders_evidence_without_location_as_bare_marker
    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(
        finding: finding(evidence: [ { "snippet" => "boom" } ]),
        patch: patch(dir),
        pr_url: "https://example.com/pull/7"
      )

      idea = File.read(File.join(folder, "idea.md"))
      assert_includes idea, "- evidence: boom",
                      "evidence with no file/line must render the bare '- evidence' marker"
    end
  end

  def test_idea_md_renders_location_only_when_snippet_blank
    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(
        finding: finding(evidence: [ { "file" => "app.rb", "line" => 9, "snippet" => "  " } ]),
        patch: patch(dir),
        pr_url: "https://example.com/pull/7"
      )

      idea = File.read(File.join(folder, "idea.md"))
      assert_includes idea, "- `app.rb:9`", "a snippet-less entry must render location only"
      refute_match(/app\.rb:9`:/, idea, "no trailing snippet separator when snippet is blank")
    end
  end

  def test_enqueue_preserves_architecture_context_and_evidence_claim
    with_tmp_dir do |dir|
      context = {
        "schema" => "hive-refactor-patrol-review-context",
        "job_id" => "job-7",
        "source" => { "url" => "https://github.com/acme/demo/pull/4" },
        "thesis" => {
          "id" => "thesis-1",
          "leverage" => { "driver" => "fan_out", "mechanism" => "shared_boundary" }
        }
      }
      enriched = finding(
        evidence: [
          {
            "file" => "src/index.ts", "line" => 7,
            "claim" => "Every caller duplicates the adapter selection.",
            "snippet" => "selectAdapter(kind)"
          }
        ]
      )

      folder = nil
      with_task_counter do
        folder = handoff(dir).enqueue(
          finding: enriched, patch: patch(dir), pr_url: "https://example.com/pull/7",
          mandatory: true, context: context
        )
      end

      assert_equal context, JSON.parse(File.read(File.join(folder, "architecture-thesis.json")))
      assert_includes File.read(File.join(folder, "idea.md")), "architecture-thesis.json"
      assert_includes File.read(File.join(folder, "task.md")), "architecture-thesis.json"
      assert_includes File.read(File.join(folder, "idea.md")), "Every caller duplicates the adapter selection."
      assert_includes File.read(File.join(folder, "idea.md")), "selectAdapter(kind)"
    end
  end

  def test_architecture_context_must_be_json_serializable
    with_tmp_dir do |dir|
      error = assert_raises(ArgumentError) do
        handoff(dir).enqueue(
          finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
          mandatory: true, context: { "score" => Float::NAN }
        )
      end

      assert_includes error.message, "JSON serializable"
    end
  end

  def test_mandatory_handoff_ignores_optional_patrol_review_toggle
    with_tmp_dir do |dir|
      ordinary = handoff(dir, review_prs: false).enqueue(
        finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7"
      )
      mandatory = nil
      with_task_counter do
        mandatory = handoff(dir, review_prs: false).enqueue(
          finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
          mandatory: true
        )
      end

      assert_nil ordinary
      assert File.directory?(mandatory)
    end
  end

  def test_mandatory_handoff_reuses_existing_fingerprint_across_retries
    with_tmp_dir do |dir|
      first = nil
      second = nil
      with_task_counter do
        subject = handoff(dir)
        first = subject.enqueue(
          finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
          mandatory: true
        )
        second = subject.enqueue(
          finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
          mandatory: true
        )
      end

      assert_equal first, second
      assert_equal 1, Dir.glob(File.join(dir, ".hive-state", "stages", "*", "*", "task.md")).size
    end
  end

  def test_optional_handoff_retry_reuses_task_after_post_rename_fsync_failure
    with_tmp_dir do |dir|
      original_fsync = Hive::AtomicFile.method(:fsync_directory)
      target_review_root = review_root(dir)
      failed_after_publish = false
      replacement = lambda do |path|
        if path == target_review_root && !failed_after_publish
          failed_after_publish = true
          raise IOError, "simulated post-rename fsync failure"
        end

        original_fsync.call(path)
      end

      with_task_counter do
        with_replaced_singleton_method(Hive::AtomicFile, :fsync_directory, replacement) do
          assert_raises(IOError) do
            handoff(dir).enqueue(
              finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7"
            )
          end
        end
      end

      published = visible_review_tasks(dir).fetch(0)
      retried = nil
      with_task_counter do
        retried = handoff(dir).enqueue(
          finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7"
        )
      end

      assert_equal published, retried
      assert_equal [ published ], visible_review_tasks(dir)
      assert_complete(retried)
    end
  end

  def test_optional_handoff_retry_fails_closed_when_pr_or_head_conflicts
    conflict_cases = {
      "PR URL" => [ "https://example.com/pull/8", nil ],
      "head" => [ "https://example.com/pull/7", "def456" ]
    }

    conflict_cases.each do |label, (retry_url, retry_head)|
      with_tmp_dir do |dir|
        with_task_counter do
          handoff(dir).enqueue(
            finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7"
          )
        end

        retry_patch = retry_head ? patch(dir, head_sha: retry_head) : patch(dir)
        error = nil
        with_task_counter do
          error = assert_raises(Hive::Patrol::ReviewHandoff::Conflict, label) do
            handoff(dir).enqueue(
              finding: finding, patch: retry_patch, pr_url: retry_url
            )
          end
        end

        assert_includes error.message, "conflict", label
        assert_equal 1, visible_review_tasks(dir).size, label
      end
    end
  end

  def test_mandatory_handoff_publishes_once_when_two_writers_race
    with_tmp_dir do |dir|
      folders = Queue.new
      errors = Queue.new
      with_task_counter do
        threads = 2.times.map do
          Thread.new do
            folders << handoff(dir).enqueue(
              finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
              mandatory: true
            )
          rescue StandardError => e
            errors << e
          end
        end
        threads.each(&:join)
      end

      assert errors.empty?, "concurrent handoffs failed: #{errors.size}"
      results = 2.times.map { folders.pop }
      assert_equal 1, results.uniq.size
      assert_equal 1, visible_review_tasks(dir).size
    end
  end

  def test_mandatory_handoff_retry_recovers_after_interrupted_staging_write
    with_tmp_dir do |dir|
      interrupted = false
      hook = lambda do |artifact, _path|
        next unless artifact == :task_md && !interrupted

        interrupted = true
        raise IOError, "simulated crash"
      end

      with_task_counter do
        assert_raises(IOError) do
          handoff(dir, write_hook: hook).enqueue(
            finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
            mandatory: true
          )
        end
      end
      assert_empty visible_review_tasks(dir), "an interrupted handoff must never publish a partial task"
      refute_empty staging_tasks(dir), "the failure seam should model a crash that leaves hidden staging state"

      folder = nil
      with_task_counter do
        folder = handoff(dir).enqueue(
          finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
          mandatory: true
        )
      end

      assert_equal [ folder ], visible_review_tasks(dir)
      assert_complete(folder)
      assert_empty staging_tasks(dir)
      refute_empty quarantined_tasks(dir), "retry should preserve interrupted state as quarantine evidence"
    end
  end

  def test_mandatory_handoff_quarantines_incomplete_matching_task_and_rebuilds
    with_tmp_dir do |dir|
      first = nil
      with_task_counter do
        first = handoff(dir).enqueue(
          finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
          mandatory: true
        )
      end
      File.delete(File.join(first, "pr.md"))

      rebuilt = nil
      with_task_counter do
        rebuilt = handoff(dir).enqueue(
          finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
          mandatory: true
        )
      end

      assert_equal first, rebuilt
      assert_complete(rebuilt)
      assert_equal 1, visible_review_tasks(dir).size
      assert_equal 1, quarantined_tasks(dir).size
    end
  end

  def test_mandatory_handoff_verifies_architecture_context_before_reuse
    with_tmp_dir do |dir|
      context = { "job_id" => "job-7", "thesis" => { "id" => "thesis-1" } }
      folder = nil
      with_task_counter do
        folder = handoff(dir).enqueue(
          finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
          mandatory: true, context: context
        )
      end

      assert_raises(Hive::Patrol::ReviewHandoff::Conflict) do
        handoff(dir).enqueue(
          finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
          mandatory: true, context: context.merge("job_id" => "job-8")
        )
      end

      File.delete(File.join(folder, "architecture-thesis.json"))
      rebuilt = nil
      with_task_counter do
        rebuilt = handoff(dir).enqueue(
          finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
          mandatory: true, context: context
        )
      end

      assert_equal folder, rebuilt
      assert_equal context, JSON.parse(File.read(File.join(rebuilt, "architecture-thesis.json")))
      assert_equal 1, quarantined_tasks(dir).size
    end
  end

  def test_mandatory_handoff_fails_closed_when_existing_metadata_conflicts
    conflict_cases = {
      "PR URL" => ->(dir, base_patch) { [ base_patch, "https://example.com/pull/8" ] },
      "branch" => ->(dir, _base_patch) { [ patch(dir, branch: "hive-patrol/other"), "https://example.com/pull/7" ] },
      "worktree path" => lambda { |dir, _base_patch|
        [ patch(dir, worktree_path: File.join(dir, "other-worktree")), "https://example.com/pull/7" ]
      },
      "head" => ->(dir, _base_patch) { [ patch(dir, head_sha: "def456"), "https://example.com/pull/7" ] }
    }

    conflict_cases.each do |label, retry_values|
      with_tmp_dir do |dir|
        base_patch = patch(dir)
        with_task_counter do
          handoff(dir).enqueue(
            finding: finding, patch: base_patch, pr_url: "https://example.com/pull/7",
            mandatory: true
          )
        end
        retry_patch, retry_url = retry_values.call(dir, base_patch)

        error = assert_raises(Hive::Patrol::ReviewHandoff::Conflict, label) do
          handoff(dir).enqueue(
            finding: finding, patch: retry_patch, pr_url: retry_url,
            mandatory: true
          )
        end

        assert_includes error.message, "conflict", label
        assert_equal 1, visible_review_tasks(dir).size, label
      end
    end
  end

  def test_mandatory_handoff_fails_closed_when_workflow_metadata_conflicts
    with_tmp_dir do |dir|
      folder = nil
      with_task_counter do
        folder = handoff(dir).enqueue(
          finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
          mandatory: true
        )
      end
      meta = YAML.safe_load(File.read(File.join(folder, "meta.yml")))
      meta["workflow"] = "content"
      File.write(File.join(folder, "meta.yml"), meta.to_yaml)

      assert_raises(Hive::Patrol::ReviewHandoff::Conflict) do
        handoff(dir).enqueue(
          finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
          mandatory: true
        )
      end
      assert_equal 1, visible_review_tasks(dir).size
    end
  end

  # A transient read failure is not evidence that a task is incomplete:
  # coercing it to nil used to quarantine the live task and publish a
  # duplicate review task for the same fingerprint. The error must surface
  # so the caller retries the handoff instead.
  def test_metadata_read_failure_propagates_without_quarantine_or_duplicate
    with_tmp_dir do |dir|
      first = nil
      with_task_counter do
        first = handoff(dir).enqueue(
          finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
          mandatory: true
        )
      end

      original = File.method(:read)
      replacement = lambda do |path, *args, **kwargs|
        raise Errno::EIO, path.to_s if File.basename(path.to_s) == "task.md"

        original.call(path, *args, **kwargs)
      end
      with_replaced_singleton_method(File, :read, replacement) do
        assert_raises(Errno::EIO) do
          handoff(dir).enqueue(
            finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
            mandatory: true
          )
        end
      end

      assert_equal [ first ], visible_review_tasks(dir), "an unreadable task must not be duplicated"
      assert_empty quarantined_tasks(dir), "an unreadable task must not be quarantined"
      assert File.file?(File.join(first, "task.md")), "the live task must stay in place"
    end
  end

  def test_malformed_metadata_is_still_quarantined_and_rebuilt
    with_tmp_dir do |dir|
      first = nil
      with_task_counter do
        first = handoff(dir).enqueue(
          finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
          mandatory: true
        )
      end
      File.write(File.join(first, "task.md"), "---\n{invalid yaml\n---\n\nbody\n")

      rebuilt = nil
      with_task_counter do
        rebuilt = handoff(dir).enqueue(
          finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
          mandatory: true
        )
      end

      assert_equal first, rebuilt
      assert_complete(rebuilt)
      assert_equal 1, visible_review_tasks(dir).size
      assert_equal 1, quarantined_tasks(dir).size, "deterministically malformed state is quarantined evidence"
    end
  end

  def test_malformed_yaml_and_architecture_context_are_quarantined_and_rebuilt
    {
      "meta.yml" => "---\n[unterminated\n",
      "architecture-thesis.json" => "{"
    }.each do |filename, malformed_content|
      with_tmp_dir do |dir|
        context = { "job_id" => "job-7", "thesis" => { "id" => "thesis-1" } }
        first = nil
        with_task_counter do
          first = handoff(dir).enqueue(
            finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
            mandatory: true, context: context
          )
        end
        File.write(File.join(first, filename), malformed_content)

        rebuilt = nil
        with_task_counter do
          rebuilt = handoff(dir).enqueue(
            finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7",
            mandatory: true, context: context
          )
        end

        assert_equal first, rebuilt, filename
        assert_complete(rebuilt)
        assert_equal context, JSON.parse(File.read(File.join(rebuilt, "architecture-thesis.json"))), filename
        assert_equal 1, quarantined_tasks(dir).size, filename
      end
    end
  end

  def test_mandatory_handoff_rejects_duplicate_complete_tasks
    with_tmp_dir do |dir|
      first = handoff(dir).enqueue(
        finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7", mandatory: true
      )
      duplicate = File.join(dir, ".hive-state", "stages", "9-done", File.basename(first))
      FileUtils.mkdir_p(File.dirname(duplicate))
      FileUtils.cp_r(first, duplicate)

      error = assert_raises(Hive::Patrol::ReviewHandoff::Conflict) do
        handoff(dir).enqueue(
          finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7", mandatory: true
        )
      end

      assert_includes error.message, "duplicate complete tasks"
    end
  end

  def test_reconcile_fails_closed_for_duplicate_tasks_and_invalid_identity
    with_tmp_dir do |dir|
      arguments = {
        finding: finding,
        patch: patch(dir),
        pr_url: "https://example.com/pull/7",
        mandatory: true
      }
      first = handoff(dir).enqueue(**arguments)
      duplicate = File.join(dir, ".hive-state", "stages", "9-done", File.basename(first))
      FileUtils.mkdir_p(File.dirname(duplicate))
      FileUtils.cp_r(first, duplicate)

      assert_equal(
        { "status" => "ambiguous", "outcome" => {} },
        handoff(dir).reconcile(**arguments)
      )
      assert_equal(
        { "status" => "ambiguous", "outcome" => {} },
        handoff(dir).reconcile(
          finding: finding, patch: patch(dir), pr_url: "", mandatory: true
        )
      )
    end
  end

  private

  def review_root(dir)
    File.join(dir, ".hive-state", "stages", "6-review")
  end

  def visible_review_tasks(dir)
    Dir.glob(File.join(review_root(dir), "patrol-*"), File::FNM_DOTMATCH).select { |path| File.directory?(path) }.sort
  end

  def staging_tasks(dir)
    Dir.glob(File.join(review_root(dir), ".handoff-*-staging-*"), File::FNM_DOTMATCH).sort
  end

  def quarantined_tasks(dir)
    Dir.glob(File.join(review_root(dir), ".handoff-quarantine", "*"), File::FNM_DOTMATCH)
       .reject { |path| %w[. ..].include?(File.basename(path)) }
       .sort
  end

  def assert_complete(folder)
    %w[meta.yml idea.md task.md worktree.yml pr.md].each do |name|
      assert File.file?(File.join(folder, name)), "missing #{name}"
    end
    assert File.directory?(File.join(folder, "reviews")), "missing reviews/"
  end
end
