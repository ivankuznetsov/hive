require "test_helper"
require "hive/stages/review/triage"
require "hive/reviewers"
require "hive/agent_profiles"
require "hive/protected_files"

# Direct coverage for the triage step of the 5-review autonomous loop.
class TriageTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../../../fixtures/fake-claude", __dir__)

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    %w[HIVE_FAKE_CLAUDE_OUTPUT HIVE_FAKE_CLAUDE_EXIT
       HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT
       HIVE_FAKE_CLAUDE_LOG_DIR].each { |k| ENV.delete(k) }
    Hive::AgentProfile.reset_version_cache!
  end

  def with_triage_dir
    with_tmp_dir do |dir|
      task_folder = File.join(dir, ".hive-state", "stages", "5-review", "test-task")
      FileUtils.mkdir_p(File.join(task_folder, "reviews"))
      yield(dir, task_folder)
    end
  end

  def make_ctx(worktree, task_folder, pass: 1)
    Hive::Reviewers::Context.new(
      worktree_path: worktree,
      task_folder: task_folder,
      default_branch: "main",
      pass: pass
    )
  end

  def default_cfg(overrides = {})
    deep_merge_for_test(
      {
        "review" => {
          "triage" => {
            "agent" => "claude",
            "bias" => "courageous",
            "custom_prompt" => nil
          }
        },
        "budget_usd" => { "review_triage" => 5 },
        "timeout_sec" => { "review_triage" => 5 }
      },
      overrides
    )
  end

  def deep_merge_for_test(base, over)
    base.merge(over) do |_k, b, o|
      b.is_a?(Hash) && o.is_a?(Hash) ? deep_merge_for_test(b, o) : o
    end
  end

  # --- empty inputs ------------------------------------------------------

  def test_empty_reviewer_files_writes_empty_escalations_doc
    with_triage_dir do |dir, task_folder|
      ctx = make_ctx(dir, task_folder)
      result = Hive::Stages::Review::Triage.run!(cfg: default_cfg, ctx: ctx)

      assert_equal :ok, result.status
      assert File.exist?(result.escalations_path)
      content = File.read(result.escalations_path)
      assert_includes content, "Escalations for pass 01"
      assert_match(/no reviewer findings/i, content)
    end
  end

  # --- happy path: courageous --------------------------------------------

  def test_courageous_mode_renders_template_and_consumes_reviewer_files
    with_triage_dir do |dir, task_folder|
      ctx = make_ctx(dir, task_folder)
      reviews_dir = File.join(task_folder, "reviews")
      File.write(File.join(reviews_dir, "claude-ce-code-review-01.md"),
                 "## High\n- [ ] potential SQL injection: validate input\n")
      File.write(File.join(reviews_dir, "codex-ce-code-review-01.md"),
                 "## Nit\n- [ ] naming: prefer snake_case\n")

      escalations = File.join(reviews_dir, "escalations-01.md")
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = escalations
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "# Escalations for pass 01\n\n_All clean._\n"

      log_dir = Dir.mktmpdir("fake-triage-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir

      result = Hive::Stages::Review::Triage.run!(cfg: default_cfg, ctx: ctx)

      assert_equal :ok, result.status
      assert File.exist?(escalations)

      argv = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_includes argv, "courageous mode"
      assert_includes argv, "claude-ce-code-review-01.md"
      assert_includes argv, "codex-ce-code-review-01.md"
      assert_includes argv, "escalations-01.md"
      assert_match(/<user_supplied_[0-9a-f]{16}/, argv,
                   "per-spawn nonce wrapper must surround reviewer content")
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end

  # --- safetyist mode ----------------------------------------------------

  def test_safetyist_mode_renders_safetyist_template
    with_triage_dir do |dir, task_folder|
      ctx = make_ctx(dir, task_folder)
      reviews_dir = File.join(task_folder, "reviews")
      File.write(File.join(reviews_dir, "claude-ce-code-review-01.md"),
                 "## Nit\n- [ ] typo: replace 'recieve' with 'receive'\n")

      escalations = File.join(reviews_dir, "escalations-01.md")
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = escalations
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "# Escalations\n"
      log_dir = Dir.mktmpdir("fake-triage-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir

      cfg = default_cfg("review" => { "triage" => { "bias" => "safetyist" } })
      result = Hive::Stages::Review::Triage.run!(cfg: cfg, ctx: ctx)

      assert_equal :ok, result.status
      argv = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_includes argv, "safetyist mode"
      refute_includes argv, "courageous mode"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end

  # --- custom_prompt path resolution -------------------------------------

  def test_custom_prompt_uses_user_supplied_template
    with_triage_dir do |dir, task_folder|
      ctx = make_ctx(dir, task_folder)
      File.write(File.join(task_folder, "reviews", "claude-ce-code-review-01.md"),
                 "## High\n- [ ] custom-finding\n")

      state_templates = File.join(dir, ".hive-state", "templates")
      FileUtils.mkdir_p(state_templates)
      File.write(File.join(state_templates, "triage_custom.md.erb"), <<~ERB)
        CUSTOM TEMPLATE for pass <%= pass %>
        Reviewer files: <%= reviewer_files.size %>
        <%= reviewer_contents %>
      ERB

      escalations = File.join(task_folder, "reviews", "escalations-01.md")
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = escalations
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "# Escalations\n"
      log_dir = Dir.mktmpdir("fake-triage-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir

      cfg = default_cfg("review" => { "triage" => { "custom_prompt" => "triage_custom.md.erb" } })
      result = Hive::Stages::Review::Triage.run!(cfg: cfg, ctx: ctx)

      assert_equal :ok, result.status
      argv = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_includes argv, "CUSTOM TEMPLATE for pass 1"
      refute_includes argv, "courageous mode", "preset templates must not be loaded when custom_prompt is set"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end

  def test_custom_prompt_path_escape_raises_config_error
    with_triage_dir do |dir, task_folder|
      ctx = make_ctx(dir, task_folder)
      File.write(File.join(task_folder, "reviews", "claude-ce-code-review-01.md"), "## Nit\n")

      state_templates = File.join(dir, ".hive-state", "templates")
      FileUtils.mkdir_p(state_templates)
      cfg = default_cfg("review" => { "triage" => { "custom_prompt" => "../../../etc/passwd" } })

      err = assert_raises(Hive::ConfigError) do
        Hive::Stages::Review::Triage.run!(cfg: cfg, ctx: ctx)
      end
      assert_match(/custom_prompt/, err.message)
    end
  end

  def test_custom_prompt_missing_file_raises_config_error
    with_triage_dir do |dir, task_folder|
      ctx = make_ctx(dir, task_folder)
      File.write(File.join(task_folder, "reviews", "claude-ce-code-review-01.md"), "## Nit\n")

      state_templates = File.join(dir, ".hive-state", "templates")
      FileUtils.mkdir_p(state_templates)
      cfg = default_cfg("review" => { "triage" => { "custom_prompt" => "does_not_exist.md.erb" } })

      err = assert_raises(Hive::ConfigError) do
        Hive::Stages::Review::Triage.run!(cfg: cfg, ctx: ctx)
      end
      assert_match(/not found/, err.message)
    end
  end

  def test_unknown_bias_preset_raises_config_error
    with_triage_dir do |dir, task_folder|
      ctx = make_ctx(dir, task_folder)
      File.write(File.join(task_folder, "reviews", "claude-ce-code-review-01.md"), "## Nit\n")

      cfg = default_cfg("review" => { "triage" => { "bias" => "yolo" } })
      err = assert_raises(Hive::ConfigError) do
        Hive::Stages::Review::Triage.run!(cfg: cfg, ctx: ctx)
      end
      assert_match(/yolo/, err.message)
    end
  end

  # --- SHA-256 protected files ------------------------------------------

  # Parameterized over every file in Hive::ProtectedFiles::ORCHESTRATOR_OWNED
  # (post-LFG-2 refactor). Each protected file's mutation must yield
  # :tampered with that filename surfaced in tampered_files.
  Hive::ProtectedFiles::ORCHESTRATOR_OWNED.each do |protected_file|
    define_method("test_protected_file_tampering_#{protected_file.tr('.', '_')}_yields_tampered_status") do
      with_triage_dir do |dir, task_folder|
        ctx = make_ctx(dir, task_folder)
        File.write(File.join(task_folder, "reviews", "claude-ce-code-review-01.md"), "## Nit\n- [ ] x: y\n")
        File.write(File.join(task_folder, protected_file), "original #{protected_file} content\n")

        escalations = File.join(task_folder, "reviews", "escalations-01.md")
        target = File.join(task_folder, protected_file)
        tamper_script = File.join(dir, "tampering-fake-claude")
        File.write(tamper_script, <<~SH)
          #!/usr/bin/env bash
          if [[ "${1:-}" == "--version" ]]; then
            echo "2.1.118 (Claude Code)"
            exit 0
          fi
          echo "TAMPERED" >> "#{target}"
          printf '# Escalations\\n' > "#{escalations}"
          exit 0
        SH
        File.chmod(0o755, tamper_script)
        ENV["HIVE_CLAUDE_BIN"] = tamper_script

        result = Hive::Stages::Review::Triage.run!(cfg: default_cfg, ctx: ctx)

        assert_equal :tampered, result.status,
                     "#{protected_file}: expected :tampered, got #{result.status}"
        assert_includes result.tampered_files, protected_file,
                        "#{protected_file}: expected in tampered_files=#{result.tampered_files.inspect}"
        assert_match(/protected files/, result.error_message)
      end
    end
  end

  # --- agent failure ----------------------------------------------------

  def test_missing_escalations_file_returns_error
    with_triage_dir do |dir, task_folder|
      ctx = make_ctx(dir, task_folder)
      File.write(File.join(task_folder, "reviews", "claude-ce-code-review-01.md"), "## Nit\n- [ ] x: y\n")
      result = Hive::Stages::Review::Triage.run!(cfg: default_cfg, ctx: ctx)

      assert_equal :error, result.status
      assert_match(/missing or empty/, result.error_message)
    end
  end

  # --- partial-file cleanup on :error path (correctness #15) ---------
  #
  # If the triage spawn fails AFTER the agent wrote a partial
  # reviews/escalations-NN.md, that file persists and the next
  # `hive run` reads escalations_count > 0, branching into
  # REVIEW_WAITING based on a corrupt artifact. The error path
  # deletes the partial file before returning.
  def test_error_path_cleans_partial_escalations_file
    with_triage_dir do |dir, task_folder|
      ctx = make_ctx(dir, task_folder)
      File.write(File.join(task_folder, "reviews", "claude-ce-code-review-01.md"),
                 "## High\n- [ ] something: explain\n")

      escalations = File.join(task_folder, "reviews", "escalations-01.md")
      # The fake-claude writes a partial escalations file — but exits
      # non-zero so the spawn returns :error. The cleanup step must
      # then delete the partial file before Triage.run! returns.
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = escalations
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "# partial — agent crashed mid-write\n- [ ] half-done\n"
      ENV["HIVE_FAKE_CLAUDE_EXIT"] = "1"

      result = Hive::Stages::Review::Triage.run!(cfg: default_cfg, ctx: ctx)

      assert_equal :error, result.status,
                   "spawn must surface as :error so the runner sets REVIEW_ERROR phase=triage"
      refute File.exist?(escalations),
             "partial escalations-01.md must be removed on the :error path so a subsequent " \
             "`hive run` doesn't read escalations_count > 0 from a corrupt artifact"
    end
  end

  # --- discovery -------------------------------------------------------

  # --- R1: reviewer-file read failure is tolerated --------------------

  def test_unreadable_reviewer_file_substitutes_placeholder_in_block
    with_triage_dir do |_dir, task_folder|
      reviews_dir = File.join(task_folder, "reviews")
      good = File.join(reviews_dir, "claude-ce-code-review-01.md")
      bad = File.join(reviews_dir, "codex-ce-code-review-01.md")
      File.write(good, "## High\n- [ ] real\n")
      File.write(bad, "should be unreadable\n")

      # Make `bad` unreadable to trigger the rescue path. chmod 0000
      # produces Errno::EACCES on read; the rescue branch substitutes
      # a placeholder rather than aborting triage.
      File.chmod(0o000, bad)
      begin
        block = Hive::Stages::Review::Triage.build_reviewer_contents_block([ good, bad ], "tag1")
        assert_includes block, "real", "good reviewer content must still be included"
        assert_includes block, "reviewer file unreadable", "unreadable path must yield a placeholder"
      ensure
        File.chmod(0o644, bad)
      end
    end
  end

  # --- M-06: triage filters all orchestrator-owned families ----------

  def test_discover_reviewer_files_excludes_fix_guardrail_and_browser
    with_triage_dir do |_dir, task_folder|
      ctx = make_ctx(nil, task_folder, pass: 1)
      reviews_dir = File.join(task_folder, "reviews")
      File.write(File.join(reviews_dir, "claude-01.md"), "## High\n- [ ] real\n")
      File.write(File.join(reviews_dir, "fix-guardrail-01.md"), "- [x] orchestrator-owned\n")
      File.write(File.join(reviews_dir, "browser-blocked-01.md"), "browser stuff\n")
      File.write(File.join(reviews_dir, "ci-blocked.md"), "ci stuff\n")

      files = Hive::Stages::Review::Triage.discover_reviewer_files(ctx)
      basenames = files.map { |f| File.basename(f) }
      assert_equal [ "claude-01.md" ], basenames,
                   "triage must only see reviewer-authored files; got #{basenames.inspect}"
    end
  end

  def test_discover_reviewer_files_excludes_escalations_and_other_passes
    with_triage_dir do |dir, task_folder|
      ctx = make_ctx(dir, task_folder, pass: 2)
      reviews_dir = File.join(task_folder, "reviews")
      File.write(File.join(reviews_dir, "claude-ce-code-review-02.md"), "")
      File.write(File.join(reviews_dir, "codex-ce-code-review-02.md"), "")
      File.write(File.join(reviews_dir, "claude-ce-code-review-01.md"), "")
      File.write(File.join(reviews_dir, "escalations-02.md"), "")

      files = Hive::Stages::Review::Triage.discover_reviewer_files(ctx)
      assert_equal 2, files.size
      basenames = files.map { |f| File.basename(f) }.sort
      assert_equal %w[claude-ce-code-review-02.md codex-ce-code-review-02.md], basenames
    end
  end
end
