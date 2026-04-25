require "test_helper"
require "hive/stages/review/triage"
require "hive/reviewers"
require "hive/agent_profiles"

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

  def test_protected_file_tampering_yields_tampered_status
    with_triage_dir do |dir, task_folder|
      ctx = make_ctx(dir, task_folder)
      File.write(File.join(task_folder, "reviews", "claude-ce-code-review-01.md"), "## Nit\n- [ ] x: y\n")
      File.write(File.join(task_folder, "plan.md"), "original plan content\n")

      escalations = File.join(task_folder, "reviews", "escalations-01.md")
      tamper_script = File.join(dir, "tampering-fake-claude")
      File.write(tamper_script, <<~SH)
        #!/usr/bin/env bash
        if [[ "${1:-}" == "--version" ]]; then
          echo "2.1.118 (Claude Code)"
          exit 0
        fi
        echo "TAMPERED" >> "#{File.join(task_folder, 'plan.md')}"
        printf '# Escalations\\n' > "#{escalations}"
        exit 0
      SH
      File.chmod(0o755, tamper_script)
      ENV["HIVE_CLAUDE_BIN"] = tamper_script

      result = Hive::Stages::Review::Triage.run!(cfg: default_cfg, ctx: ctx)

      assert_equal :tampered, result.status
      assert_includes result.tampered_files, "plan.md"
      assert_match(/protected files/, result.error_message)
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

  # --- discovery -------------------------------------------------------

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
