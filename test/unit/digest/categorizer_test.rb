require "test_helper"
require "hive/digest/categorizer"

class HiveDigestCategorizerTest < Minitest::Test
  include HiveTestHelper

  FIXTURE = File.expand_path("../../fixtures/digest/items.json", __dir__)

  class CapturingLogger
    attr_reader :warnings

    def initialize
      @warnings = []
    end

    def warn(message)
      @warnings << message
    end
  end

  def test_maps_canned_json_to_categorized_items_by_pr_number
    grouped = {
      "alpha" => [
        item(pr_number: 10, pr_title: "Build digest"),
        item(pr_number: 11, pr_title: "Escape markdown")
      ]
    }

    result = Hive::Digest::Categorizer.map_output_file(FIXTURE, grouped: grouped, logger: nil)

    assert_equal %w[feature fix], result.fetch("alpha").map(&:category)
    assert_equal "Adds the daily digest command.", result.fetch("alpha").first.summary
    assert_same grouped.fetch("alpha").first, result.fetch("alpha").first.item
  end

  def test_unknown_category_defaults_only_that_row
    with_tmp_dir do |dir|
      path = File.join(dir, "items.json")
      File.write(path, JSON.dump({
        "items" => [
          { "id" => "alpha/10", "category" => "mystery", "summary" => "Odd row" },
          { "id" => "alpha/11", "category" => "patrol", "summary" => "Runs maintenance." }
        ]
      }))
      grouped = {
        "alpha" => [
          item(pr_number: 10, pr_title: "Fallback title"),
          item(pr_number: 11, pr_title: "Patrol title")
        ]
      }

      result = Hive::Digest::Categorizer.map_output_file(path, grouped: grouped, logger: nil)

      assert_equal [ "feature", "patrol" ], result.fetch("alpha").map(&:category)
      assert_equal "Odd row", result.fetch("alpha").first.summary
      assert_equal "Runs maintenance.", result.fetch("alpha").last.summary
    end
  end

  def test_missing_row_uses_default_summary
    with_tmp_dir do |dir|
      path = File.join(dir, "items.json")
      File.write(path, JSON.dump({ "items" => [] }))
      grouped = { "alpha" => [ item(pr_number: 10, pr_title: "Fallback title") ] }

      result = Hive::Digest::Categorizer.map_output_file(path, grouped: grouped, logger: nil)

      assert_equal "feature", result.fetch("alpha").first.category
      assert_equal "Fallback title", result.fetch("alpha").first.summary
    end
  end

  def test_bad_agent_result_raises_model_error
    error = assert_raises(Hive::Digest::ModelError) do
      Hive::Digest::Categorizer.parse_result!(
        { status: :error, error_message: "boom" },
        output_path: FIXTURE,
        grouped: { "alpha" => [] },
        logger: nil
      )
    end

    assert_match(/boom/, error.message)
  end

  def test_missing_or_malformed_output_raises_model_error
    with_tmp_dir do |dir|
      assert_raises(Hive::Digest::ModelError) do
        Hive::Digest::Categorizer.map_output_file(File.join(dir, "missing.json"), grouped: {}, logger: nil)
      end

      bad = File.join(dir, "bad.json")
      File.write(bad, "{")

      assert_raises(Hive::Digest::ModelError) do
        Hive::Digest::Categorizer.map_output_file(bad, grouped: {}, logger: nil)
      end
    end
  end

  def test_prompt_renders_full_pr_body_and_output_path
    grouped = {
      "alpha" => [
        item(pr_number: 10, pr_title: "Build digest", pr_body: "## Summary\n\nFull body.")
      ]
    }
    categorizer = Hive::Digest::Categorizer.new(cfg: {}, run_root: Dir.mktmpdir, logger: nil)

    prompt = categorizer.render_prompt(
      grouped,
      date: Date.new(2026, 6, 13),
      output_path: "/tmp/digest-items.json"
    )

    assert_includes prompt, "Hive's daily shipped digest for 2026-06-13"
    assert_includes prompt, "Item id: alpha/10"
    assert_includes prompt, "/tmp/digest-items.json"
    assert_includes prompt, "Full body."
  end

  def test_prompt_fences_every_per_item_data_field_and_drops_pr_url
    grouped = {
      "alpha" => [
        item(pr_number: 10, pr_title: "Build digest", pr_body: "Full body.", display_name: "Shiny task")
      ]
    }
    categorizer = Hive::Digest::Categorizer.new(cfg: {}, run_root: Dir.mktmpdir, logger: nil)

    prompt = categorizer.render_prompt(grouped, date: Date.new(2026, 6, 13), output_path: "/tmp/x.json")

    # pr_url (attacker-influenceable, same provenance as pr_body) is no longer
    # interpolated: the categorizer never used it; the renderer reads it from
    # pr.md for the link, so it is not an un-fenced injection slot anymore.
    refute_includes prompt, "PR URL:"
    refute_includes prompt, "https://example.test/pulls/10",
                    "the unused, attacker-influenceable PR URL must not reach the prompt"

    # Every per-item DATA field (project, display name, PR title, PR body) is
    # fenced in the per-spawn nonce tag, so none is an un-fenced injection slot.
    tag = prompt[/<(user_supplied_[0-9a-f]+)>/, 1]
    refute_nil tag, "the prompt must use a per-spawn nonce tag"
    assert_equal prompt.scan("<#{tag}>").count, prompt.scan("</#{tag}>").count,
                 "every opened nonce fence must be closed"
    assert_includes prompt, "Project:\n<#{tag}>\nalpha\n</#{tag}>"
    assert_includes prompt, "Display name:\n<#{tag}>\nShiny task\n</#{tag}>"
    assert_includes prompt, "PR title:\n<#{tag}>\nBuild digest\n</#{tag}>"
    assert_includes prompt, "PR body:\n<#{tag}>\nFull body.\n</#{tag}>"
    # The id stays outside the fence as the join key the model echoes back.
    assert_includes prompt, "Item id: alpha/10"
  end

  def test_unknown_category_warns_through_the_logger
    with_tmp_dir do |dir|
      path = File.join(dir, "items.json")
      File.write(path, JSON.dump({
        "items" => [ { "id" => "alpha/10", "category" => "mystery", "summary" => "Odd row" } ]
      }))
      grouped = { "alpha" => [ item(pr_number: 10, pr_title: "Fallback title") ] }
      logger = CapturingLogger.new

      Hive::Digest::Categorizer.map_output_file(path, grouped: grouped, logger: logger)

      assert(logger.warnings.any? { |m| m.include?("invalid category") && m.include?("alpha/10") },
             "an unknown category must warn — the only operator signal the model misbehaved")
    end
  end

  def test_missing_row_warns_through_the_logger
    with_tmp_dir do |dir|
      path = File.join(dir, "items.json")
      File.write(path, JSON.dump({ "items" => [] }))
      grouped = { "alpha" => [ item(pr_number: 10, pr_title: "Fallback title") ] }
      logger = CapturingLogger.new

      Hive::Digest::Categorizer.map_output_file(path, grouped: grouped, logger: logger)

      assert(logger.warnings.any? { |m| m.include?("omitted item") && m.include?("alpha/10") },
             "an omitted item must warn so a half-bad model run leaves a trace")
    end
  end

  def test_duplicate_id_warns_and_last_write_wins
    with_tmp_dir do |dir|
      path = File.join(dir, "items.json")
      File.write(path, JSON.dump({
        "items" => [
          { "id" => "alpha/10", "category" => "feature", "summary" => "First." },
          { "id" => "alpha/10", "category" => "fix", "summary" => "Second wins." }
        ]
      }))
      grouped = { "alpha" => [ item(pr_number: 10, pr_title: "Title") ] }
      logger = CapturingLogger.new

      result = Hive::Digest::Categorizer.map_output_file(path, grouped: grouped, logger: logger)

      assert_equal "Second wins.", result.fetch("alpha").first.summary
      assert(logger.warnings.any? { |m| m.include?("duplicate id") && m.include?("alpha/10") },
             "a duplicate model id must warn — it is attacker-steerable last-write-wins")
    end
  end

  def test_categorized_item_guard_rejects_unknown_category_and_blank_summary
    shipped = item(pr_number: 10, pr_title: "Title")
    assert_raises(ArgumentError) do
      Hive::Digest::CategorizedItem.new(item: shipped, category: "mystery", summary: "ok")
    end
    assert_raises(ArgumentError) do
      Hive::Digest::CategorizedItem.new(item: shipped, category: "feature", summary: "   ")
    end
  end

  def test_cross_project_pr_number_collision_keeps_summaries_distinct
    with_tmp_dir do |dir|
      path = File.join(dir, "items.json")
      # Two projects shipped PR #10 on the same day. Project-scoped ids keep
      # their model summaries from overwriting each other in the output map.
      File.write(path, JSON.dump({
        "items" => [
          { "id" => "alpha/10", "category" => "feature", "summary" => "Alpha PR 10." },
          { "id" => "beta/10", "category" => "fix", "summary" => "Beta PR 10." }
        ]
      }))
      grouped = {
        "alpha" => [ item(pr_number: 10, pr_title: "Alpha title") ],
        "beta" => [ item(pr_number: 10, pr_title: "Beta title", project_name: "beta") ]
      }

      result = Hive::Digest::Categorizer.map_output_file(path, grouped: grouped, logger: nil)

      assert_equal "Alpha PR 10.", result.fetch("alpha").first.summary
      assert_equal "Beta PR 10.", result.fetch("beta").first.summary
    end
  end

  # A fake agent that stands in for Hive::Agent: instead of spawning a real
  # process it writes the canned items.json to the `expected_output` the
  # categorizer passed in, then reports success — exercising the full
  # categorize orchestration (run_dir → prune → runner_task → agent_for →
  # run! → parse_result! → map_output_file) without an AI/process call.
  class FakeAgent
    def initialize(expected_output:, items:, summary: nil)
      @expected_output = expected_output
      @items = items
      @summary = summary
    end

    def run!
      doc = { "items" => @items }
      doc["summary"] = @summary if @summary
      File.write(@expected_output, JSON.dump(doc))
      { status: :ok }
    end
  end

  def test_categorize_runs_end_to_end_through_a_seamed_agent
    with_tmp_dir do |run_root|
      grouped = {
        "alpha" => [
          item(pr_number: 10, pr_title: "Build digest"),
          item(pr_number: 11, pr_title: "Escape markdown")
        ]
      }
      rows = [
        { "id" => "alpha/10", "category" => "feature", "summary" => "Adds the digest." },
        { "id" => "alpha/11", "category" => "fix", "summary" => "Escapes markdown." }
      ]
      categorizer = Hive::Digest::Categorizer.new(cfg: {}, run_root: run_root, logger: nil)

      fake_new = lambda do |**kw|
        FakeAgent.new(expected_output: kw.fetch(:expected_output), items: rows)
      end
      result = with_replaced_singleton_method(Hive::Agent, :new, fake_new) do
        categorizer.categorize(grouped, date: "2026-06-15")
      end

      assert_equal %w[feature fix], result.by_project.fetch("alpha").map(&:category)
      assert_equal "Adds the digest.", result.by_project.fetch("alpha").first.summary
      assert_same grouped.fetch("alpha").first, result.by_project.fetch("alpha").first.item
      assert_equal "2 updates shipped today.", result.summary,
                   "with no model summary, categorize must fall back to a neutral count"
      # The orchestration created exactly one scratch run dir under the root.
      run_dirs = Dir.children(run_root).select { |name| File.directory?(File.join(run_root, name)) }
      assert_equal 1, run_dirs.size, "categorize must materialize one per-run scratch dir"
      assert_match(/\A2026-06-15-[0-9a-f]{8}\z/, run_dirs.first)
    end
  end

  def test_global_digest_model_controls_reach_direct_agent_constructor
    with_tmp_dir do |run_root|
      grouped = { "alpha" => [ item(pr_number: 10, pr_title: "Build digest") ] }
      rows = [ { "id" => "alpha/10", "category" => "feature", "summary" => "Adds it." } ]
      cfg = {
        "digest" => { "agent" => "codex" },
        "models" => { "digest" => { "model" => "gpt-5.6-sol", "effort" => "xhigh" } }
      }
      captured = nil
      fake_new = lambda do |**kw|
        captured = kw
        FakeAgent.new(expected_output: kw.fetch(:expected_output), items: rows)
      end

      with_replaced_singleton_method(Hive::Agent, :new, fake_new) do
        Hive::Digest::Categorizer.new(cfg: cfg, run_root: run_root, logger: nil)
                                 .categorize(grouped, date: "2026-06-15")
      end

      assert_equal [ "--model", "gpt-5.6-sol", "-c", 'model_reasoning_effort="xhigh"' ],
                   captured[:model_control_flags]
      assert_nil captured[:permission_mode]
    end
  end

  def test_categorize_surfaces_the_model_overall_summary
    with_tmp_dir do |run_root|
      grouped = { "alpha" => [ item(pr_number: 10, pr_title: "Build digest") ] }
      rows = [ { "id" => "alpha/10", "category" => "feature", "summary" => "Adds the digest." } ]
      categorizer = Hive::Digest::Categorizer.new(cfg: {}, run_root: run_root, logger: nil)

      fake_new = lambda do |**kw|
        FakeAgent.new(expected_output: kw.fetch(:expected_output), items: rows,
                      summary: "A quiet maintenance day.")
      end
      result = with_replaced_singleton_method(Hive::Agent, :new, fake_new) do
        categorizer.categorize(grouped, date: "2026-06-15")
      end

      assert_equal "A quiet maintenance day.", result.summary,
                   "the model's top-level summary must reach the Output"
    end
  end

  def test_default_overall_summary_is_singular_for_one_item
    with_tmp_dir do |run_root|
      grouped = { "alpha" => [ item(pr_number: 10, pr_title: "Build digest") ] }
      rows = [ { "id" => "alpha/10", "category" => "feature", "summary" => "Adds it." } ]
      categorizer = Hive::Digest::Categorizer.new(cfg: {}, run_root: run_root, logger: nil)

      # No top-level summary in the model output → the count fallback fires, and
      # must pluralize correctly for a single shipped item.
      fake_new = lambda do |**kw|
        FakeAgent.new(expected_output: kw.fetch(:expected_output), items: rows)
      end
      result = with_replaced_singleton_method(Hive::Agent, :new, fake_new) do
        categorizer.categorize(grouped, date: "2026-06-15")
      end

      assert_equal "1 update shipped today.", result.summary
    end
  end

  def test_agent_spawn_failure_becomes_a_model_error
    with_tmp_dir do |run_root|
      grouped = { "alpha" => [ item(pr_number: 10, pr_title: "Build digest") ] }
      categorizer = Hive::Digest::Categorizer.new(cfg: {}, run_root: run_root, logger: nil)

      spawn_failing = lambda do |**_kw|
        agent = Object.new
        # Models a missing/misnamed digest.agent binary: Process.spawn raises
        # Errno::ENOENT straight out of Agent#run! (which does not rescue it).
        agent.define_singleton_method(:run!) { raise Errno::ENOENT, "No such file - claude" }
        agent
      end

      error = with_replaced_singleton_method(Hive::Agent, :new, spawn_failing) do
        assert_raises(Hive::Digest::ModelError) do
          categorizer.categorize(grouped, date: "2026-06-15")
        end
      end

      assert_match(/could not run the agent/, error.message)
      assert_match(/ENOENT/, error.message,
                   "a broken agent binary must surface as a ModelError so the failed-notice path fires")
    end
  end

  def test_map_document_rejects_a_non_array_items_field
    error = assert_raises(Hive::Digest::ModelError) do
      Hive::Digest::Categorizer.map_document({ "items" => "not-an-array" }, grouped: {}, logger: nil)
    end

    assert_match(/must contain an items array/, error.message)
  end

  def test_default_summary_falls_back_to_display_label_when_pr_title_blank
    with_tmp_dir do |dir|
      path = File.join(dir, "items.json")
      # The model omitted this item, so categorized_item takes the default
      # path; its pr_title is blank, so default_summary must fall through to
      # display_label rather than render an empty changelog line.
      File.write(path, JSON.dump({ "items" => [] }))
      grouped = { "alpha" => [ item(pr_number: 10, pr_title: "  ", display_name: "Shiny task") ] }

      result = Hive::Digest::Categorizer.map_output_file(path, grouped: grouped, logger: nil)

      assert_equal "Shiny task", result.fetch("alpha").first.summary,
                   "a blank pr_title must fall back to the item's display_label"
    end
  end

  def test_prune_old_runs_drops_the_oldest_excess_scratch_dirs
    with_tmp_dir do |run_root|
      retention = Hive::Digest::Categorizer::RUN_DIR_RETENTION
      # Pre-seed more than the retention cap, oldest-first by mtime, so the
      # next run_dir call must prune the excess down to the cap (minus the
      # one fresh dir it creates).
      old_dirs = (1..(retention + 5)).map do |n|
        dir = File.join(run_root, format("2026-06-%02d-%08x", n % 28 + 1, n))
        FileUtils.mkdir_p(dir)
        File.utime(Time.now - (retention + 5 - n) * 3600, Time.now - (retention + 5 - n) * 3600, dir)
        dir
      end
      categorizer = Hive::Digest::Categorizer.new(cfg: {}, run_root: run_root, logger: nil)

      fresh = categorizer.send(:run_dir, "2026-06-15")

      remaining = Dir.children(run_root).select { |name| File.directory?(File.join(run_root, name)) }
      # prune runs BEFORE the fresh dir is created: it leaves exactly
      # RUN_DIR_RETENTION, then run_dir adds the one fresh dir on top.
      assert_equal retention + 1, remaining.size,
                   "prune must leave RUN_DIR_RETENTION dirs before the fresh one is created"
      assert_includes remaining, File.basename(fresh), "the freshly created run dir must survive the prune"
      refute_includes remaining, File.basename(old_dirs.first), "the oldest excess dir must be pruned"
    end
  end

  def test_prune_old_runs_tolerates_a_filesystem_error
    with_tmp_dir do |run_root|
      retention = Hive::Digest::Categorizer::RUN_DIR_RETENTION
      (1..(retention + 2)).each do |n|
        FileUtils.mkdir_p(File.join(run_root, format("2026-06-%02d-%08x", n % 28 + 1, n)))
      end
      logger = CapturingLogger.new
      categorizer = Hive::Digest::Categorizer.new(cfg: {}, run_root: run_root, logger: logger)

      # An EACCES during the rm_rf (a permission flip / locked dir) must be
      # caught and logged, not crash the whole digest run.
      raising_rm_rf = lambda { |*_args| raise Errno::EACCES, "prune blocked" }
      with_replaced_singleton_method(FileUtils, :rm_rf, raising_rm_rf) do
        categorizer.send(:run_dir, "2026-06-15")
      end

      assert(logger.warnings.any? { |m| m.include?("run-dir prune failed") },
             "a prune SystemCallError must degrade to a warning, not crash the digest")
    end
  end

  def test_agent_name_fallback_chain
    assert_equal "codex",
                 Hive::Digest::Categorizer.new(cfg: { "digest" => { "agent" => "codex" } }).send(:agent_name)
    assert_equal "pi",
                 Hive::Digest::Categorizer.new(cfg: { "patrol" => { "agent" => "pi" } }).send(:agent_name)
    assert_equal "claude", Hive::Digest::Categorizer.new(cfg: {}).send(:agent_name)
  end

  def test_budget_and_timeout_fallback_chain
    tuned = Hive::Digest::Categorizer.new(
      cfg: { "budget_usd" => { "digest" => 12 }, "timeout_sec" => { "digest" => 34 } }
    )
    assert_equal 12, tuned.send(:budget_usd)
    assert_equal 34, tuned.send(:timeout_sec)

    defaulted = Hive::Digest::Categorizer.new(cfg: {})
    assert_equal Hive::Digest::Categorizer::DEFAULT_BUDGET_USD, defaulted.send(:budget_usd)
    assert_equal Hive::Digest::Categorizer::DEFAULT_TIMEOUT_SEC, defaulted.send(:timeout_sec)
  end

  private

  def item(pr_number:, pr_title:, pr_body: "body", project_name: "alpha", display_name: nil)
    Hive::Digest::ShippedItem.new(
      project_name: project_name,
      slug: "slug-#{pr_number}",
      display_name: display_name || "Task #{pr_number}",
      pr_url: "https://example.test/pulls/#{pr_number}",
      pr_number: pr_number,
      pr_title: pr_title,
      pr_body: pr_body,
      shipped_at: Time.utc(2026, 6, 13, 12)
    )
  end
end
