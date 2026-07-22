require "test_helper"
require "hive/config"

class ConfigTest < Minitest::Test
  def test_registry_round_trips_repository_identity
    with_tmp_global_config do
      with_tmp_git_repo do |repo|
        remote = File.join(File.dirname(repo), "remote.git")
        FileUtils.mkdir_p(remote)
        run!("git", "-C", repo, "remote", "add", "origin", remote)

        Hive::Config.register_project(name: "sample", path: repo)
        entry = Hive::Config.registered_projects.find { |candidate| candidate["name"] == "sample" }

        assert_equal Hive::RepositoryIdentity.normalize(remote), entry["repository_identity"]
      end
    end
  end

  include HiveTestHelper

  def test_load_returns_defaults_when_no_config_file
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)
      assert_nil cfg["max_review_passes"],
                 "deprecated max_review_passes key must be absent from DEFAULTS"
      # Generous defaults bumped ~5x in plan 2026-05-04-001 / ADR-023.
      assert_equal 50, cfg["budget_usd"]["brainstorm"]
      assert_equal 500, cfg["budget_usd"]["execute_implementation"]
      assert_nil cfg["budget_usd"]["execute_review"],
                 "deprecated execute_review key must be absent from DEFAULTS"
      assert_equal 100, cfg["budget_usd"]["patrol"]
      assert_equal 3600, cfg["timeout_sec"]["patrol"]
      assert_equal 50, cfg["budget_usd"]["digest"]
      assert_equal 1800, cfg["timeout_sec"]["digest"]
      assert_equal "8-finalize", cfg["dependency_gate_stage"]
      assert_equal "coding", cfg["default_workflow"]
      assert_equal true, cfg.dig("daemon", "auto_retry", "enabled")
      assert_equal 5, cfg["attempt_heartbeat_sec"]
      assert_equal 30, cfg["attempt_stale_sec"]
      assert_equal 30, cfg["attempt_launch_timeout_sec"]
      assert_equal 30, cfg["attempt_first_heartbeat_timeout_sec"]
      assert_nil cfg.dig("review", "adhoc", "reviewers")
      assert_equal false, cfg.dig("review", "adhoc", "fix")
      assert_nil cfg.dig("open_pr", "agent")
      assert_nil cfg.dig("review", "ci", "agent")
      assert_nil cfg.dig("review", "fix", "agent")
      assert_equal dir, cfg["project_root"]
    end
  end

  def test_load_records_frozen_field_level_implementation_identity_provenance
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        execute:
          agent: codex
          model: gpt-5.6-sol
        open_pr:
          effort: low
        review:
          ci:
            model: gpt-5.6-terra
          fix:
            agent: claude
            effort: high
      YAML

      cfg = Hive::Config.load(dir)
      provenance = cfg.fetch(Hive::Config::IMPLEMENTATION_IDENTITY_PROVENANCE_KEY)

      assert_equal({ "agent" => "codex", "model" => "gpt-5.6-sol" },
                   provenance.fetch("execute"))
      assert_equal({ "effort" => "low" }, provenance.fetch("open_pr"))
      assert_equal({ "model" => "gpt-5.6-terra" }, provenance.fetch("review.ci"))
      assert_equal({ "agent" => "claude", "effort" => "high" },
                   provenance.fetch("review.fix"))
      assert provenance.frozen?
      assert provenance.values.all?(&:frozen?)
    end
  end

  def test_implementation_identity_fields_use_raw_provenance_not_merged_defaults
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)

      assert_equal({}, Hive::Config.implementation_identity_fields(cfg, "open_pr"))
      assert_equal({}, Hive::Config.implementation_identity_fields(cfg, "review.fix"))

      synthetic = { "review" => { "fix" => { "agent" => "claude" } } }
      assert_equal({ "agent" => "claude" },
                   Hive::Config.implementation_identity_fields(synthetic, "review.fix"))
    end
  end

  def test_deep_freeze_recurses_into_arrays
    value = { "nested" => [ { "model" => "gpt" } ] }

    Hive::Config.deep_freeze(value)

    assert value.frozen?
    assert value.fetch("nested").frozen?
    assert value.dig("nested", 0).frozen?
  end

  def test_load_validates_attempt_timer_relationships
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        attempt_heartbeat_sec: 10
        attempt_stale_sec: 9
      YAML

      error = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_includes error.message, "attempt_stale_sec"
      assert_includes error.message, "attempt_heartbeat_sec"
    end
  end

  def test_load_rejects_non_positive_attempt_timers
    %w[
      attempt_heartbeat_sec
      attempt_stale_sec
      attempt_launch_timeout_sec
      attempt_first_heartbeat_timeout_sec
    ].each do |key|
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), "#{key}: 0\n")
        error = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
        assert_includes error.message, key
        assert_includes error.message, "positive integer"
      end
    end
  end

  def test_load_rewraps_malformed_project_yaml_as_config_error
    with_tmp_dir do |dir|
      config_path = File.join(dir, ".hive-state", "config.yml")
      FileUtils.mkdir_p(File.dirname(config_path))
      File.write(config_path, "daemon: [\n")

      error = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }

      assert_includes error.message, config_path
      assert_includes error.message, "not valid YAML"
    end
  end

  def test_load_rewraps_disallowed_project_yaml_class_as_config_error
    with_tmp_dir do |dir|
      config_path = File.join(dir, ".hive-state", "config.yml")
      FileUtils.mkdir_p(File.dirname(config_path))
      File.write(config_path, "daemon: !ruby/object:Object {}\n")

      error = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }

      assert_includes error.message, config_path
      assert_includes error.message, "not valid YAML"
    end
  end

  def test_load_rewraps_unreadable_project_config_as_config_error
    with_tmp_dir do |dir|
      config_path = File.join(dir, ".hive-state", "config.yml")
      FileUtils.mkdir_p(config_path)

      error = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }

      assert_includes error.message, config_path
      assert_includes error.message, "not readable"
    end
  end

  def test_load_rewraps_inaccessible_project_config_parent_as_config_error
    skip "permission bits are not enforced for root" if Process.uid.zero?

    with_tmp_dir do |dir|
      state_dir = File.join(dir, ".hive-state")
      config_path = File.join(state_dir, "config.yml")
      FileUtils.mkdir_p(state_dir)
      File.write(config_path, "daemon:\n  enabled: true\n")
      File.chmod(0o000, state_dir)

      error = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }

      assert_includes error.message, config_path
      assert_includes error.message, "not readable"
    ensure
      File.chmod(0o700, state_dir) if state_dir && File.exist?(state_dir)
    end
  end

  def test_load_rewraps_project_config_symlink_loop_as_config_error
    with_tmp_dir do |dir|
      state_dir = File.join(dir, ".hive-state")
      config_path = File.join(state_dir, "config.yml")
      FileUtils.mkdir_p(state_dir)
      File.symlink("config.yml", config_path)

      error = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }

      assert_includes error.message, config_path
      assert_includes error.message, "not readable"
    end
  end

  def test_load_allows_daemon_auto_retry_enabled_override
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          auto_retry:
            enabled: false
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal false, cfg.dig("daemon", "auto_retry", "enabled")
      assert_equal 30, cfg.dig("daemon", "poll_interval_sec"),
                   "nested daemon auto_retry override must deep-merge without dropping siblings"
    end
  end

  def test_load_rejects_non_hash_daemon_auto_retry
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          auto_retry: nope
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }

      assert_includes err.message, "daemon.auto_retry"
      assert_includes err.message, "must be a hash"
    end
  end

  def test_load_rejects_non_boolean_daemon_auto_retry_enabled
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          auto_retry:
            enabled: sometimes
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }

      assert_includes err.message, "daemon.auto_retry.enabled"
      assert_includes err.message, "must be a boolean"
    end
  end

  def test_load_accepts_default_workflow_override
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        default_workflow: research
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal "research", cfg["default_workflow"]
    end
  end

  def test_load_keeps_default_workflow_when_other_keys_override
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        dependency_gate_stage: 9-done
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal "coding", cfg["default_workflow"]
      assert_equal "9-done", cfg["dependency_gate_stage"]
    end
  end

  def test_load_accepts_dependency_gate_stage_done_override
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        dependency_gate_stage: 9-done
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal "9-done", cfg["dependency_gate_stage"]
    end
  end

  def test_load_rejects_invalid_dependency_gate_stage
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        dependency_gate_stage: 7-artifacts
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }

      assert_includes err.message, "dependency_gate_stage"
      assert_includes err.message, "8-finalize"
      assert_includes err.message, "9-done"
    end
  end

  # Patrol is OPT-IN: a project with NO config file (and thus no patrol
  # section) must resolve to disabled. `medium` is the `mode` carried by
  # DEFAULTS for validation, but its `enabled: true` knob is NOT injected
  # because no explicit `mode:` was written — `enabled` falls through to
  # DEFAULTS["patrol"]["enabled"] = false.
  def test_load_leaves_patrol_disabled_when_no_config
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)

      assert_equal "medium", cfg.dig("patrol", "mode")
      assert_equal false, cfg.dig("patrol", "enabled"),
                   "patrol must be opt-in: no config section means disabled"
      assert_equal "continuous", cfg.dig("patrol", "trigger")
      assert_equal 600, cfg.dig("patrol", "poll_interval_sec")
      assert_equal "claude", cfg.dig("patrol", "agent")
      assert_equal "medium", cfg.dig("patrol", "min_confidence_to_fix")
      assert_equal 3, cfg.dig("patrol", "max_findings_per_feature")
      assert_equal 12, cfg.dig("patrol", "max_features_per_cycle")
      assert_equal 70, cfg.dig("patrol", "min_alpha_to_fix")
      assert_equal 1, cfg.dig("patrol", "max_fixes_per_feature_per_cycle")
      assert_equal 6, cfg.dig("patrol", "max_fix_attempts_per_cycle")
      assert_equal 3, cfg.dig("patrol", "max_prs_per_cycle")
      assert_equal false, cfg.dig("patrol", "draft_prs")
      assert_equal true, cfg.dig("patrol", "review_prs")
      assert_equal [], cfg.dig("patrol", "include")
      assert_includes cfg.dig("patrol", "exclude"), "node_modules"
      assert_nil cfg.dig("patrol", "commands", "test")
      refute cfg.dig("patrol", "commands").key?("public_contract"),
             "architecture-patrol validation must not alter ordinary patrol"
      assert_equal 4, cfg.dig("patrol", "review", "max_owned_files")
      assert_equal 4, cfg.dig("patrol", "review", "max_context_files")
      assert_equal %w[codex-native-review],
                   cfg.dig("patrol", "review", "reviewers").map { |entry| entry.fetch("name") }
      native = cfg.dig("patrol", "review", "reviewers").first
      assert_equal "codex_review", native["kind"]
      assert_equal "codex", native["agent"]
      assert_equal "reviewer_codex_native_review.md.erb", native["prompt_template"]
      refute native.key?("skill"), "the codex-native patrol reviewer takes no CE skill"
    end
  end

  def test_load_keeps_refactor_patrol_inert_when_no_config
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)

      assert_equal false, cfg.dig("refactor_patrol", "enabled")
      assert_equal false, cfg.dig("refactor_patrol", "auto_fix", "enabled")
      refute cfg.dig("refactor_patrol", "auto_fix").key?("agent")
      assert_equal false, cfg.dig("refactor_patrol", "issue_filing", "enabled")
      assert_equal 0.25, cfg.dig("refactor_patrol", "issue_filing", "min_leverage_score")
      refute cfg.fetch("refactor_patrol").key?("agent")
      assert_equal 0.10, cfg.dig("refactor_patrol", "min_leverage_score")
      assert_equal "medium", cfg.dig("refactor_patrol", "min_confidence")
      assert_equal 1, cfg.dig("refactor_patrol", "max_theses_per_feature")
      assert_equal 10, cfg.dig("refactor_patrol", "max_theses_per_run")
      assert_equal 3600, cfg.dig("refactor_patrol", "max_review_seconds_per_run")
      assert_includes cfg.dig("refactor_patrol", "exclude"), "node_modules"
      assert_nil cfg.dig("refactor_patrol", "commands", "test")
      assert_nil cfg.dig("refactor_patrol", "commands", "docs")
      assert cfg.dig("refactor_patrol", "commands").key?("public_contract")
      assert_nil cfg.dig("refactor_patrol", "commands", "public_contract")
      refute cfg.dig("refactor_patrol", "caps").key?("max_files")
      refute cfg.dig("refactor_patrol", "caps").key?("max_diff_lines")
      assert_equal false, cfg.dig("refactor_patrol", "caps", "single_feature_only")
      assert_equal true, cfg.dig("refactor_patrol", "caps", "allow_cross_feature")
      assert_equal 0.3, cfg.dig("refactor_patrol", "leverage", "weights", "churn")
      assert_equal 0.0, cfg.dig("refactor_patrol", "leverage", "weights", "coverage_gap")
      assert_equal 6, cfg.dig("refactor_patrol", "review", "max_owned_files")
      assert_equal 6, cfg.dig("refactor_patrol", "review", "max_context_files")
    end
  end

  def test_load_does_not_grant_auto_fix_to_legacy_discovery_only_config
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        refactor_patrol:
          enabled: true
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal true, cfg.dig("refactor_patrol", "enabled")
      assert_equal false, cfg.dig("refactor_patrol", "auto_fix", "enabled")
      assert_equal false, cfg.dig("refactor_patrol", "issue_filing", "enabled")
    end
  end

  def test_load_merges_refactor_patrol_overrides
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        patrol:
          mode: off
        refactor_patrol:
          enabled: true
          auto_fix:
            enabled: true
            agent: codex
          issue_filing:
            enabled: true
            min_leverage_score: 0.5
          agent: codex
          min_confidence: high
          max_theses_per_run: 4
          max_review_seconds_per_run: 600
          commands:
            test: bundle exec rake test
          leverage:
            weights:
              churn: 0.9
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal false, cfg.dig("patrol", "enabled")
      assert_equal true, cfg.dig("refactor_patrol", "enabled")
      assert_equal true, cfg.dig("refactor_patrol", "auto_fix", "enabled")
      assert_equal "codex", cfg.dig("refactor_patrol", "auto_fix", "agent")
      assert_equal true, cfg.dig("refactor_patrol", "issue_filing", "enabled")
      assert_equal 0.5, cfg.dig("refactor_patrol", "issue_filing", "min_leverage_score")
      assert_equal "codex", cfg.dig("refactor_patrol", "agent")
      assert_equal "high", cfg.dig("refactor_patrol", "min_confidence")
      assert_equal 4, cfg.dig("refactor_patrol", "max_theses_per_run")
      assert_equal 600, cfg.dig("refactor_patrol", "max_review_seconds_per_run")
      assert_equal "bundle exec rake test", cfg.dig("refactor_patrol", "commands", "test")
      refute cfg.dig("refactor_patrol", "caps").key?("max_files")
      refute cfg.dig("refactor_patrol", "caps").key?("max_diff_lines")
      assert_equal 0.9, cfg.dig("refactor_patrol", "leverage", "weights", "churn")
      assert_equal 0.25, cfg.dig("refactor_patrol", "leverage", "weights", "fan_in")
    end
  end

  def test_load_rejects_invalid_refactor_patrol_caps_confidence_and_weights
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        refactor_patrol:
          min_confidence: bogus
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_includes err.message, "refactor_patrol.min_confidence"
      assert_includes err.message, "low"
      assert_includes err.message, "medium"
      assert_includes err.message, "high"
    end

    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        refactor_patrol:
          min_leverage_score: 1.1
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_includes err.message, "refactor_patrol.min_leverage_score"
      assert_includes err.message, "between 0 and 1"
    end

    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        refactor_patrol:
          model: gpt-5.6-sol
          effort: HIGH
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_includes err.message, "refactor_patrol identity"
      assert_includes err.message, "effort"
    end

    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        refactor_patrol:
          issue_filing:
            min_leverage_score: 1.1
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_includes err.message, "refactor_patrol.issue_filing.min_leverage_score"
      assert_includes err.message, "between 0 and 1"
    end

    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        refactor_patrol:
          caps:
            allow_cross_feature: sometimes
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_includes err.message, "refactor_patrol.caps.allow_cross_feature"
      assert_includes err.message, "must be a boolean"
    end

    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        refactor_patrol:
          leverage:
            weights:
              churn: -1
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_includes err.message, "refactor_patrol.leverage.weights.churn"
      assert_includes err.message, ">= 0"
    end

    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        refactor_patrol:
          commands: nope
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_includes err.message, "refactor_patrol.commands"
      assert_includes err.message, "must be a Hash"
    end

    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        refactor_patrol:
          commands:
            test: " "
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_includes err.message, "refactor_patrol.commands.test"
      assert_includes err.message, "non-empty String"
    end

    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        refactor_patrol:
          commands:
            docs: " "
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_includes err.message, "refactor_patrol.commands.docs"
      assert_includes err.message, "non-empty String"
    end

    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        refactor_patrol:
          commands:
            public_contract: " "
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_includes err.message, "refactor_patrol.commands.public_contract"
      assert_includes err.message, "non-empty String"
    end

    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        refactor_patrol:
          caps: nope
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_includes err.message, "refactor_patrol.caps"
      assert_includes err.message, "must be a Hash"
    end

    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        refactor_patrol:
          leverage: nope
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_includes err.message, "refactor_patrol.leverage"
      assert_includes err.message, "must be a Hash"
    end

    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        refactor_patrol:
          leverage:
            weights: nope
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_includes err.message, "refactor_patrol.leverage.weights"
      assert_includes err.message, "must be a Hash"
    end

    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        refactor_patrol:
          leverage:
            weights:
              churn: 0
              fan_in: 0
              complexity: 0
              coupling: 0
              bug_density: 0
              coverage_gap: 0
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_includes err.message, "at least one positive weight"
    end

    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        refactor_patrol:
          review: nope
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_includes err.message, "refactor_patrol.review"
      assert_includes err.message, "must be a Hash"
    end

    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        refactor_patrol:
          review:
            max_context_files: -1
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_includes err.message, "refactor_patrol.review.max_context_files"
      assert_includes err.message, "must be an integer"
      assert_includes err.message, ">= 0"
    end

    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        refactor_patrol:
          enabled: maybe
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_includes err.message, "refactor_patrol.enabled"
      assert_includes err.message, "must be a boolean"
    end

    %w[auto_fix issue_filing].each do |gate|
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
          refactor_patrol:
            #{gate}: nope
        YAML

        err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
        assert_includes err.message, "refactor_patrol.#{gate}"
        assert_includes err.message, "must be a Hash"
      end

      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
          refactor_patrol:
            #{gate}:
              enabled: maybe
        YAML

        err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
        assert_includes err.message, "refactor_patrol.#{gate}.enabled"
        assert_includes err.message, "must be a boolean"
      end
    end
  end

  # An unset `mode` must NOT inject medium's knobs (opt-in). A patrol
  # section that only overrides `agent` (no `mode:`) stays disabled.
  def test_load_leaves_patrol_disabled_when_mode_unset
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        patrol:
          agent: codex
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal "medium", cfg.dig("patrol", "mode")
      assert_equal false, cfg.dig("patrol", "enabled"),
                   "unset mode must not inject medium's enabled: true knob"
      assert_equal "continuous", cfg.dig("patrol", "trigger")
      assert_equal 600, cfg.dig("patrol", "poll_interval_sec")
      assert_equal "codex", cfg.dig("patrol", "agent")
      assert_equal 3, cfg.dig("patrol", "max_findings_per_feature")
      assert_equal 12, cfg.dig("patrol", "max_features_per_cycle")
      assert_equal 70, cfg.dig("patrol", "min_alpha_to_fix")
      assert_equal 1, cfg.dig("patrol", "max_fixes_per_feature_per_cycle")
      assert_equal 6, cfg.dig("patrol", "max_fix_attempts_per_cycle")
      assert_equal 3, cfg.dig("patrol", "max_prs_per_cycle")
      assert_equal "medium", cfg.dig("patrol", "min_confidence_to_fix")
    end
  end

  # Explicit `mode: medium` (what `hive init` writes) DOES enable patrol
  # and derive the timer/14400 frequency knobs — unchanged behavior.
  def test_load_enables_patrol_on_explicit_medium_mode
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        patrol:
          mode: medium
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal "medium", cfg.dig("patrol", "mode")
      assert_equal true, cfg.dig("patrol", "enabled"),
                   "explicit mode: medium must enable patrol"
      assert_equal "timer", cfg.dig("patrol", "trigger")
      assert_equal 14_400, cfg.dig("patrol", "poll_interval_sec")
    end
  end

  # Explicit `mode: off` disables patrol.
  def test_load_disables_patrol_on_explicit_off_mode
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        patrol:
          mode: off
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal "off", cfg.dig("patrol", "mode")
      assert_equal false, cfg.dig("patrol", "enabled"),
                   "explicit mode: off must disable patrol"
    end
  end

  # A quoted `mode: "off"` arrives as the literal string "off" (not the
  # YAML boolean false the bareword form produces), so it exercises the
  # PATROL_MODES path directly rather than the `mode == false` coercion.
  def test_load_disables_patrol_on_quoted_off_mode
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        patrol:
          mode: "off"
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal "off", cfg.dig("patrol", "mode")
      assert_equal false, cfg.dig("patrol", "enabled"),
                   "quoted mode: \"off\" must disable patrol"
    end
  end

  # A config with no `mode` but an explicit `enabled: true` stays enabled:
  # the explicit knob is preserved through merge_defaults even though no
  # mode knobs are injected.
  def test_load_keeps_explicit_enabled_true_without_mode
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        patrol:
          enabled: true
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal "medium", cfg.dig("patrol", "mode")
      assert_equal true, cfg.dig("patrol", "enabled"),
                   "explicit enabled: true must survive even without a mode"
    end
  end

  # An explicit `mode: "medium"` round-trips to enabled medium patrol with the
  # timer/14400 cadence. (`hive init` defaults the prompt to `low`, but a user
  # can pick `medium`; this locks medium's derivation either way.)
  def test_load_enables_patrol_on_explicit_medium_round_trip
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        patrol:
          mode: "medium"
          min_confidence_to_fix: medium
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal "medium", cfg.dig("patrol", "mode")
      assert_equal true, cfg.dig("patrol", "enabled")
      assert_equal "timer", cfg.dig("patrol", "trigger")
      assert_equal 14_400, cfg.dig("patrol", "poll_interval_sec")
    end
  end

  def test_load_resolves_patrol_frequency_modes
    cases = {
      "ultrapatrol" => [ "timer", 1800, true, 800_000, 2_400_000, 100_000, 10, 36, 100 ],
      "high" => [ "timer", 7200, true, 400_000, 1_200_000, 75_000, 6, 18, 50 ],
      "medium" => [ "timer", 14_400, true, 200_000, 600_000, 50_000, 3, 8, 25 ],
      "low" => [ "new_commits", 600, true, 100_000, 200_000, 40_000, 1, 2, 10 ],
      "off" => [ "continuous", 600, false, 200_000, 600_000, 50_000, 3, 8, 25 ]
    }

    cases.each do |mode, (trigger, poll_interval_sec, enabled, cycle_tokens, daily_tokens, agent_tokens,
                          cycle_spawns, daily_spawns, agent_budget)|
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
          patrol:
            mode: #{mode}
        YAML

        cfg = Hive::Config.load(dir)

        assert_equal mode, cfg.dig("patrol", "mode")
        assert_equal trigger, cfg.dig("patrol", "trigger")
        assert_equal poll_interval_sec, cfg.dig("patrol", "poll_interval_sec")
        assert_equal enabled, cfg.dig("patrol", "enabled")
        assert_equal 3, cfg.dig("patrol", "max_findings_per_feature"),
                     "#{mode} must not change the findings cap"
        assert_equal 12, cfg.dig("patrol", "max_features_per_cycle"),
                     "#{mode} must not change the feature review cap"
        assert_equal 70, cfg.dig("patrol", "min_alpha_to_fix"),
                     "#{mode} must not change the alpha gate"
        assert_equal 3, cfg.dig("patrol", "max_prs_per_cycle"),
                     "#{mode} must not change the PR cap"
        assert_equal 6, cfg.dig("patrol", "max_fix_attempts_per_cycle"),
                     "#{mode} must not change the fix-attempt cap"
        assert_equal cycle_tokens, cfg.dig("patrol", "max_tokens_per_cycle")
        assert_equal daily_tokens, cfg.dig("patrol", "max_tokens_per_day")
        assert_equal agent_tokens, cfg.dig("patrol", "max_tokens_per_agent")
        assert_equal cycle_spawns, cfg.dig("patrol", "max_agent_spawns_per_cycle")
        assert_equal daily_spawns, cfg.dig("patrol", "max_agent_spawns_per_day")
        assert_equal 96, cfg.dig("patrol", "max_architecture_unmetered_spawns_per_day")
        assert_equal 8, cfg.dig("patrol", "max_architecture_review_spawns_per_day")
        assert_equal agent_budget, cfg.dig("patrol", "max_budget_usd_per_agent")
        assert_equal 2, cfg.dig("patrol", "architecture_budget_multiplier")
        assert_equal 2, cfg.dig("patrol", "fix_budget_multiplier")
        assert_equal "medium", cfg.dig("patrol", "min_confidence_to_fix"),
                     "#{mode} must not change the confidence gate"
      end
    end
  end

  def test_load_keeps_explicit_patrol_knob_over_mode_derived_value
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        patrol:
          mode: medium
          poll_interval_sec: 600
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal "medium", cfg.dig("patrol", "mode")
      assert_equal true, cfg.dig("patrol", "enabled")
      assert_equal "timer", cfg.dig("patrol", "trigger")
      assert_equal 600, cfg.dig("patrol", "poll_interval_sec")
    end
  end

  def test_load_preserves_legacy_explicit_patrol_granular_knobs_without_mode
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        patrol:
          enabled: false
          trigger: continuous
          poll_interval_sec: 600
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal "medium", cfg.dig("patrol", "mode")
      assert_equal false, cfg.dig("patrol", "enabled")
      assert_equal "continuous", cfg.dig("patrol", "trigger")
      assert_equal 600, cfg.dig("patrol", "poll_interval_sec")
    end
  end

  def test_load_deep_merges_patrol_overrides
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        patrol:
          mode: medium
          enabled: true
          trigger: continuous
          commands:
            test: bundle exec rake test
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal true, cfg.dig("patrol", "enabled")
      assert_equal "continuous", cfg.dig("patrol", "trigger")
      assert_equal 14_400, cfg.dig("patrol", "poll_interval_sec"),
                   "mode-derived patrol frequency must fill missing sibling keys"
      assert_equal "bundle exec rake test", cfg.dig("patrol", "commands", "test")
      assert_nil cfg.dig("patrol", "commands", "lint")
    end
  end

  def test_load_rejects_invalid_patrol_config
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        patrol:
          enabled: true
          trigger: cron
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/patrol\.trigger/, err.message)
      assert_match(/new_commits/, err.message)
      assert_match(/timer/, err.message)
      assert_match(/continuous/, err.message)
    end
  end

  def test_load_rejects_invalid_patrol_mode
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        patrol:
          mode: bogus
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/patrol\.mode/, err.message)
      assert_match(/ultrapatrol/, err.message)
      assert_match(/medium/, err.message)
      assert_match(/off/, err.message)
    end
  end

  def test_load_rejects_invalid_patrol_field_shapes
    cases = [
      "mode: bogus",
      "enabled: maybe",
      "draft_prs: sometimes",
      "review_prs: sometimes",
      "min_confidence_to_fix: certain",
      "min_alpha_to_fix: 101",
      "max_features_per_cycle: 0",
      "max_fixes_per_feature_per_cycle: 0",
      "max_fix_attempts_per_cycle: 0",
      "max_tokens_per_cycle: 0",
      "max_tokens_per_day: nope",
      "max_tokens_per_agent: 0",
      "max_agent_spawns_per_cycle: 0",
      "max_agent_spawns_per_day: 1.5",
      "max_architecture_review_spawns_per_day: 0",
      "max_architecture_unmetered_spawns_per_day: 0",
      "architecture_budget_multiplier: 0",
      "fix_budget_multiplier: 0",
      "max_budget_usd_per_agent: 0",
      "poll_interval_sec: 30",
      "commands: []",
      "commands:\n    test: ''",
      "review:",
      "review: []",
      "review:\n    max_owned_files: 0",
      "review:\n    reviewers:",
      "review:\n    reviewers: nope",
      "review:\n    reviewers:\n      - name: codex-ce-code-review\n        kind: agent"
    ]

    cases.each do |body|
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
          patrol:
            #{body}
        YAML

        assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      end
    end
  end

  # Plan U1 explicit test scenarios for the 7-artifacts stage defaults
  # (see .hive-state/stages/.../we-need-to-collect-artifacts/plan.md, U1).
  # Without these assertions a silent drift on the artifact stage defaults
  # goes undetected.
  def test_load_returns_artifacts_stage_defaults
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)
      assert_equal 100, cfg.dig("budget_usd", "artifacts"),
                   "artifacts budget must default to 100 USD per plan U1"
      assert_equal 3600, cfg.dig("timeout_sec", "artifacts"),
                   "artifacts timeout must default to 3600 seconds per plan U1"
      assert_equal "claude", cfg.dig("artifacts", "agent"),
                   "artifacts agent must default to claude per plan U1"
    end
  end

  def test_hive_state_dir_uses_default_and_custom_name
    assert_equal File.join("/repo", ".hive-state"), Hive::Config.hive_state_dir("/repo")
    assert_equal File.join("/repo", ".custom-state"), Hive::Config.hive_state_dir("/repo", ".custom-state")
  end

  def test_load_merges_per_project_overrides
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        default_branch: main
        max_review_passes: 6
        budget_usd:
          brainstorm: 20
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal "main", cfg["default_branch"]
      assert_equal 6, cfg["max_review_passes"]
      assert_equal 20, cfg["budget_usd"]["brainstorm"], "explicit override must win"
      assert_equal 100, cfg["budget_usd"]["plan"], "plan budget should fall back to bumped default"
    end
  end

  # Legacy projects that still carry execute_review explicitly must keep it
  # via deep-merge — DEFAULTS no longer ships the key but user-supplied
  # values survive untouched.
  def test_load_preserves_user_supplied_execute_review_when_legacy
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        budget_usd:
          execute_review: 50
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal 50, cfg["budget_usd"]["execute_review"],
                   "legacy explicit execute_review must survive deep-merge"
    end
  end

  # ADR-023: stage-level agent keys for brainstorm / plan / execute.
  # Defaults are "claude" so legacy configs without these keys keep
  # the same runtime behavior as before this plan landed.
  def test_load_returns_default_stage_agents_when_keys_absent
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)
      assert_equal "claude", cfg.dig("brainstorm", "agent"), "brainstorm agent must default to claude"
      assert_equal "claude", cfg.dig("plan", "agent"), "plan agent must default to claude"
      assert_equal "claude", cfg.dig("execute", "agent"), "execute agent must default to claude"
      assert_equal :tmux, Hive::Config.claude_mode(cfg), "claude.mode must default to tmux"
      assert_equal "bypassPermissions", Hive::Config.claude_permission_mode(cfg),
                   "claude.permission_mode must default to bypassPermissions"
      assert_equal "headless", cfg.dig("brainstorm", "runtime"), "brainstorm runtime must default to headless"
    end
  end

  def test_load_honors_claude_mode_override
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        claude:
          mode: headless
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal :headless, Hive::Config.claude_mode(cfg)
      assert_equal true, Hive::Config.explicit_claude_mode?(cfg)
    end
  end

  def test_load_honors_claude_permission_mode_override
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        claude:
          permission_mode: auto
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal "auto", Hive::Config.claude_permission_mode(cfg)
      assert_equal "auto", cfg.dig("claude", "permission_mode")
    end
  end

  def test_permission_spec_defaults_to_yolo
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)

      assert_equal "yolo", cfg["permissions"]
      assert_equal "yolo", Hive::Config.permission_spec(cfg, "plan")
      assert_equal "yolo", Hive::Config.permission_spec(cfg, "review.triage")
    end
  end

  def test_permission_spec_uses_project_default_when_stage_is_silent
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        permissions: read-only
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal "read-only", Hive::Config.permission_spec(cfg, "plan")
      assert_equal "read-only", Hive::Config.permission_spec(cfg, "execute")
      assert_equal "read-only", Hive::Config.permission_spec(cfg, "review.fix")
    end
  end

  def test_stage_permission_spec_fully_replaces_project_default
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        permissions:
          preset: scoped
          tools: [Read]
          dirs:
            - shared
        execute:
          permissions:
            preset: scoped
            tools: [Read, Write]
      YAML

      cfg = Hive::Config.load(dir)

      execute_permissions = Hive::Config.permission_spec(cfg, "execute")
      assert_equal({ "preset" => "scoped", "tools" => [ "Read", "Write" ] }, execute_permissions)
      refute execute_permissions.key?("dirs"), "stage override must not inherit dirs from project default"
      assert_equal [ "shared" ], Hive::Config.permission_spec(cfg, "plan")["dirs"]
    end
  end

  def test_nested_review_permission_spec_is_read_by_dot_stage_name
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        permissions: yolo
        review:
          triage:
            permissions: read-only
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal "read-only", Hive::Config.permission_spec(cfg, "review.triage")
      assert_equal "yolo", Hive::Config.permission_spec(cfg, "review.fix")
    end
  end

  def test_review_level_permissions_key_is_rejected_at_load
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          permissions: read-only
      YAML

      # A bare `review.permissions` is never resolved (only review.<role>
      # and per-reviewer entries are), so honoring it silently would be a
      # fail-open downgrade. Load must reject it loudly.
      error = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.permissions/, error.message)
      assert_match(/not a supported/, error.message)
      assert_match(/review\.\{ci,triage,fix,browser_test\}/, error.message)
    end
  end

  def test_per_role_review_permissions_still_load_when_review_has_no_bare_key
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          ci:
            permissions: read-only
          triage:
            permissions:
              preset: scoped
              tools: [Read, Write, Edit]
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal "read-only", Hive::Config.permission_spec(cfg, "review.ci")
      assert_equal({ "preset" => "scoped", "tools" => %w[Read Write Edit] },
                   Hive::Config.permission_spec(cfg, "review.triage"))
    end
  end

  def test_permission_config_errors_fail_closed_at_load
    cases = [
      [ "permissions: reckless\n", /unknown preset "reckless"/ ],
      [ "plan:\n  permissions:\n    tools: [Read]\n", /map must include preset/ ],
      [ "execute:\n  permissions:\n    preset: scoped\n    tools: [Read, Bash]\n    bash: true\n", /express Bash via tools/ ],
      [ "review:\n  triage:\n    permissions:\n      preset: scoped\n", /scoped requires tools: or bash:/ ],
      # Mirror the resolver table's malformed shapes at the operator-facing
      # load path: an unknown key for the preset, and a non-string/non-map
      # scalar spec.
      [ "plan:\n  permissions:\n    preset: read-only\n    dirs: [tmp]\n", /unknown key/ ],
      [ "permissions: 42\n", /must be a preset string or a map/ ]
    ]

    cases.each do |yaml, pattern|
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), yaml)

        error = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
        assert_match(/permissions/, error.message)
        assert_match(pattern, error.message)
      end
    end
  end

  # Fail-closed: a present-but-blank `permissions:` (YAML key with no value →
  # nil) must hard-error at load, NOT silently resolve to yolo. permission_at
  # returns the literal nil (not the MISSING_PERMISSION sentinel), so the
  # value is the operator's explicit-but-empty scope, which we reject.
  def test_blank_stage_permissions_fails_closed_at_load
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        execute:
          permissions:
      YAML

      error = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/present but blank/, error.message)
      assert_match(/yolo/, error.message)
    end
  end

  def test_blank_project_level_permissions_fails_closed_at_load
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        permissions:
      YAML

      error = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/present but blank/, error.message)
      assert_match(/yolo/, error.message)
    end
  end

  # Guard against over-correcting: a fully-ABSENT permissions key must still
  # default to yolo with NO error. Only a present-but-blank key fails closed.
  def test_absent_permissions_still_defaults_to_yolo_without_error
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        max_passes: 4
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal "yolo", cfg["permissions"]
      assert_equal "yolo", Hive::Config.permission_spec(cfg, "plan")
      assert_equal "yolo", Hive::Config.permission_spec(cfg, "execute")
      assert_equal "yolo", Hive::Config.permission_spec(cfg, "review.triage")
    end
  end

  def test_load_raises_when_claude_permission_mode_is_unknown
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        claude:
          permission_mode: reckless
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/claude\.permission_mode/, err.message)
      assert_match(/bypassPermissions/, err.message)
      assert_match(/auto/, err.message)
    end
  end

  def test_load_raises_when_claude_permission_mode_is_not_a_string
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        claude:
          permission_mode: 42
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/claude\.permission_mode/, err.message)
      assert_match(/Integer/, err.message)
    end
  end

  def test_load_raises_when_claude_mode_is_unknown
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        claude:
          mode: warm_pool
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/claude\.mode/, err.message)
      assert_match(/headless/, err.message)
      assert_match(/tmux/, err.message)
    end
  end

  def test_load_raises_when_claude_mode_is_not_a_string
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        claude:
          mode: 42
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/claude\.mode/, err.message)
      assert_match(/Integer/, err.message)
    end
  end

  def test_load_tracks_legacy_brainstorm_runtime_separately_from_global_claude_mode
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        brainstorm:
          runtime: headless
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal :tmux, Hive::Config.claude_mode(cfg),
                   "legacy brainstorm.runtime must not become the project-global claude.mode"
      assert_equal false, Hive::Config.explicit_claude_mode?(cfg)
      assert_equal true, Hive::Config.explicit_brainstorm_runtime?(cfg)
    end
  end

  def test_load_honors_per_project_stage_agent_overrides
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        brainstorm:
          agent: codex
        plan:
          agent: pi
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal "codex", cfg.dig("brainstorm", "agent")
      assert_equal "pi",    cfg.dig("plan", "agent")
      assert_equal "headless", cfg.dig("brainstorm", "runtime")
      assert_equal "claude", cfg.dig("execute", "agent"),
                   "execute agent must fall back to default when not overridden"
    end
  end

  def test_load_honors_brainstorm_tmux_runtime_override
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        brainstorm:
          runtime: tmux_interactive
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal "tmux_interactive", cfg.dig("brainstorm", "runtime")
    end
  end

  def test_load_raises_when_brainstorm_runtime_is_unknown
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        brainstorm:
          runtime: warm_pool
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/brainstorm\.runtime/, err.message)
      assert_match(/headless/, err.message)
      assert_match(/tmux_interactive/, err.message)
    end
  end

  def test_stage_skill_uses_agent_specific_plan_defaults
    assert_equal "/plan",
      Hive::Config.stage_skill({ "plan" => { "agent" => "claude" } }, "plan")
    assert_equal "/llm-wiki:wiki-plan",
      Hive::Config.stage_skill({ "plan" => { "agent" => "codex" } }, "plan")
    assert_equal "/llm-wiki:wiki-plan",
      Hive::Config.stage_skill({ "plan" => { "agent" => "pi" } }, "plan")
  end

  def test_stage_skill_maps_legacy_plan_alias_for_non_claude_agents
    cfg = { "plan" => { "agent" => "codex", "skill" => "/plan" } }

    assert_equal "/llm-wiki:wiki-plan", Hive::Config.stage_skill(cfg, "plan")
  end

  def test_stage_skill_keeps_non_legacy_plan_override
    cfg = { "plan" => { "agent" => "codex", "skill" => "/compound-engineering:ce-plan" } }

    assert_equal "/compound-engineering:ce-plan", Hive::Config.stage_skill(cfg, "plan")
  end

  def test_load_rejects_non_hash_stage_skill_by_agent
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        plan:
          skill_by_agent: wiki-plan
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/plan\.skill_by_agent.*must be a Hash/, err.message)
    end
  end

  def test_load_rejects_non_string_stage_skill_by_agent_value
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        plan:
          skill_by_agent:
            codex: 42
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/plan\.skill_by_agent\.codex.*must be a String/, err.message)
    end
  end

  def test_load_raises_when_stage_agent_is_unknown_profile
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        execute:
          agent: nonexistent_profile
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/execute\.agent "nonexistent_profile"/, err.message)
      assert_match(/registered:/, err.message, "error must list registered profiles")
    end
  end

  # ADR-023 shape-validation gap (ce-code-review F1): non-Hash overrides on
  # the new top-level keys would otherwise survive deep_merge (because
  # deep_merge returns the override unchanged when it is not a Hash) and
  # crash later as TypeError/NoMethodError in stage code. validate! now
  # rejects them at load time with a typed ConfigError.
  def test_load_raises_when_stage_block_is_a_scalar_instead_of_hash
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        brainstorm: claude
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/brainstorm.*must be a Hash/, err.message)
      assert_match(/got "claude"/, err.message)
    end
  end

  def test_load_raises_when_budget_usd_is_nil
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        budget_usd: ~
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/budget_usd.*must be a Hash/, err.message)
    end
  end

  def test_load_raises_when_timeout_sec_is_a_scalar
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        timeout_sec: 600
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/timeout_sec.*must be a Hash/, err.message)
    end
  end

  # AgentProfiles.registered?(name) calls name.to_sym; non-String values
  # (Integer, Hash, Array, Boolean) crash with NoMethodError. validate_agent_name!
  # type-checks first so a typo like `execute.agent: 42` surfaces as
  # ConfigError, not NoMethodError. Closes ce-code-review F2 (P2).
  def test_load_raises_when_stage_agent_is_an_integer
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        execute:
          agent: 42
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/execute\.agent.*must be a String/, err.message)
      assert_match(/got 42 \(Integer\)/, err.message)
    end
  end

  def test_load_raises_when_stage_agent_is_a_hash
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        plan:
          agent:
            name: claude
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/plan\.agent.*must be a String/, err.message)
    end
  end

  # Symbol agents (e.g. from a Ruby-injected config) should still pass —
  # AgentProfiles.registered? handles both symbols and strings.
  def test_load_accepts_symbol_stage_agent
    with_tmp_dir do |dir|
      cfg = Hive::Config.send(:merge_defaults, { "execute" => { "agent" => :claude } })
      cfg["project_root"] = dir
      Hive::Config.send(:validate!, cfg, "synthetic")
      assert_equal :claude, cfg.dig("execute", "agent")
    end
  end

  # Table-driven coverage so every key in HASH_SHAPED_KEYS — not just the
  # 3 we sampled in the original tests — is defended against scalar
  # overrides. A future refactor that subsetted the constant (e.g.
  # conditionalised the check per-key) would otherwise pass tests while
  # silently letting `agents: claude` or `review: foo` bypass validation.
  def test_load_rejects_scalar_override_on_every_hash_shaped_key
    Hive::Config::HASH_SHAPED_KEYS.each do |key|
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), "#{key}: scalar-value\n")
        err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
        assert_match(/#{key}.*must be a Hash/, err.message,
                     "HASH_SHAPED_KEYS member #{key.inspect} must reject scalar overrides")
      end
    end
  end

  # Table-driven coverage for the type-check in validate_agent_name!.
  # Every path in ROLE_AGENT_PATHS — including all four review.* paths —
  # must reject non-String/non-Symbol values with ConfigError, not crash
  # with NoMethodError on `name.to_sym`.
  def test_load_rejects_non_string_agent_value_on_every_role_agent_path
    Hive::Config::ROLE_AGENT_PATHS.each do |path|
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        # Build a nested YAML hash matching the path with the leaf as
        # an Integer (the canonical NoMethodError trigger for to_sym).
        yaml = path.reverse.reduce(42) { |acc, key| { key => acc } }.to_yaml
        File.write(File.join(dir, ".hive-state", "config.yml"), yaml)
        err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
        label = path.join(".")
        assert_match(/#{Regexp.escape(label)}.*must be a String/, err.message,
                     "#{label} must reject Integer agent values with ConfigError, not crash on to_sym")
      end
    end
  end

  # Boolean is the documented crash class in validate_agent_name!'s
  # comment but isn't exercised anywhere else. Pin it explicitly.
  def test_load_rejects_boolean_agent_value
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          ci:
            agent: true
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.ci\.agent.*must be a String/, err.message)
    end
  end

  def test_register_and_lookup_project
    with_tmp_global_config do |home|
      Hive::Config.register_project(name: "foo", path: "/tmp/foo")
      Hive::Config.register_project(name: "bar", path: "/tmp/bar")
      projects = Hive::Config.registered_projects
      assert_equal 2, projects.size, "two projects should be registered"
      assert_equal "/tmp/foo", projects.first["path"]
      assert Hive::Config.find_project("bar"), "find_project should locate registered project by name"
      refute Hive::Config.find_project("missing"), "find_project should return nil for unknown project"
      assert File.exist?(File.join(home, "config.yml"))
    end
  end

  def test_project_for_path_resolves_registered_repo_from_cwd
    with_tmp_global_config do
      with_tmp_dir do |repo|
        FileUtils.mkdir_p(File.join(repo, ".hive-state"))
        Hive::Config.register_project(name: "repo", path: repo)

        project = Hive::Config.project_for_path(repo)

        assert_equal "repo", project["name"]
        assert_equal File.expand_path(repo), project["path"]
      end
    end
  end

  def test_project_for_path_resolves_nested_subdirectory
    with_tmp_global_config do
      with_tmp_dir do |repo|
        nested = File.join(repo, "lib", "hive")
        FileUtils.mkdir_p([ File.join(repo, ".hive-state"), nested ])
        Hive::Config.register_project(name: "repo", path: repo)

        project = Hive::Config.project_for_path(nested)

        assert_equal "repo", project["name"]
      end
    end
  end

  def test_project_for_path_uses_most_specific_registered_prefix
    with_tmp_global_config do
      with_tmp_dir do |parent|
        child = File.join(parent, "child")
        FileUtils.mkdir_p([ File.join(parent, ".hive-state"), File.join(child, ".hive-state") ])
        Hive::Config.register_project(name: "parent", path: parent)
        Hive::Config.register_project(name: "child", path: child)

        project = Hive::Config.project_for_path(File.join(child, "subdir"))

        assert_equal "child", project["name"]
      end
    end
  end

  def test_registered_project_resolves_by_project_name_override
    with_tmp_global_config do
      with_tmp_dir do |repo|
        FileUtils.mkdir_p(File.join(repo, ".hive-state"))
        Hive::Config.register_project(name: "repo", path: repo)

        project = Hive::Config.registered_project!(name: "repo", cwd: "/tmp/not-inside")

        assert_equal "repo", project["name"]
      end
    end
  end

  def test_registered_project_rejects_unknown_project_name
    with_tmp_global_config do
      err = assert_raises(Hive::ConfigError) do
        Hive::Config.registered_project!(name: "missing", cwd: "/tmp/not-inside")
      end

      assert_includes err.message, "not a hive-invited repo"
      assert_includes err.message, "hive init"
    end
  end

  def test_registered_project_rejects_cwd_outside_registered_repos
    with_tmp_global_config do
      with_tmp_dir do |outside|
        err = assert_raises(Hive::ConfigError) do
          Hive::Config.registered_project!(cwd: outside)
        end

        assert_includes err.message, "not a hive-invited repo"
        assert_includes err.message, "--project NAME"
      end
    end
  end

  def test_registered_project_rejects_missing_hive_state_directory
    with_tmp_global_config do
      with_tmp_dir do |repo|
        Hive::Config.register_project(name: "repo", path: repo)

        err = assert_raises(Hive::ConfigError) do
          Hive::Config.registered_project!(cwd: repo)
        end

        # Distinct from the not-invited message: the project is registered but
        # its hive state directory is gone.
        assert_includes err.message, "registered but its hive state directory"
        assert_includes err.message, "is missing"
        assert_includes err.message, "hive init"
        refute_includes err.message, "not a hive-invited repo"
      end
    end
  end

  def test_register_project_replaces_existing_by_name
    with_tmp_global_config do
      Hive::Config.register_project(name: "foo", path: "/tmp/old")
      Hive::Config.register_project(name: "foo", path: "/tmp/new")
      projects = Hive::Config.registered_projects
      assert_equal 1, projects.size
      assert_equal "/tmp/new", projects.first["path"]
    end
  end

  def test_register_project_preserves_malformed_registry_container_for_prune
    with_tmp_global_config do |home|
      File.write(
        File.join(home, "config.yml"),
        {
          "registered_projects" => { "bad" => "shape" },
          "daemon" => { "autostart" => false }
        }.to_yaml
      )

      Hive::Config.register_project(name: "good", path: "/tmp/good")

      data = YAML.safe_load(File.read(File.join(home, "config.yml")))
      rows = data.fetch("registered_projects")
      assert rows.any? { |row| !row.is_a?(Hash) },
             "malformed registry content must stay visible to prune"
      assert_includes rows.select { |row| row.is_a?(Hash) }.map { |row| row["name"] }, "good"
      assert_equal false, data.dig("daemon", "autostart"),
                   "register_project must preserve sibling global config blocks"
    end
  end

  def test_concurrent_register_project_preserves_all_entries
    with_tmp_global_config do |home|
      count = 8
      roots = count.times.map do |i|
        File.join(home, "project-#{i}").tap { |dir| FileUtils.mkdir_p(dir) }
      end

      run_concurrent_global_config_writers(count) do |i|
        Hive::Config.register_project(name: "p#{i}", path: roots.fetch(i))
      end

      names = Hive::Config.registered_projects.map { |project| project["name"] }.sort
      assert_equal count.times.map { |i| "p#{i}" }, names
    end
  end

  def test_concurrent_register_and_unregister_preserves_both_mutations
    with_tmp_global_config do |home|
      count = 6
      new_roots = count.times.map do |i|
        File.join(home, "new-project-#{i}").tap { |dir| FileUtils.mkdir_p(dir) }
      end
      Hive::Config.register_project(name: "keep", path: File.join(home, "keep").tap { |dir| FileUtils.mkdir_p(dir) })
      count.times do |i|
        Hive::Config.register_project(name: "drop#{i}", path: "/tmp/hive-drop-#{Process.pid}-#{i}")
      end

      run_concurrent_global_config_writers(count * 2) do |i|
        if i < count
          Hive::Config.register_project(name: "new#{i}", path: new_roots.fetch(i))
        else
          Hive::Config.unregister_project(name: "drop#{i - count}")
        end
      end

      data = YAML.safe_load(File.read(File.join(home, "config.yml")))
      names = Array(data["registered_projects"]).map { |entry| entry["name"] }.sort
      assert_equal [ "keep", *count.times.map { |i| "new#{i}" } ], names
    end
  end

  def test_concurrent_register_and_prune_preserves_added_entries_and_removed_stale_rows
    with_tmp_global_config do |home|
      count = 6
      live = File.join(home, "live").tap { |dir| FileUtils.mkdir_p(dir) }
      new_roots = count.times.map do |i|
        File.join(home, "prune-new-#{i}").tap { |dir| FileUtils.mkdir_p(dir) }
      end
      Hive::Config.register_project(name: "live", path: live)
      count.times do |i|
        Hive::Config.register_project(name: "dead#{i}", path: "/tmp/hive-dead-#{Process.pid}-#{i}")
      end

      run_concurrent_global_config_writers(count * 2) do |i|
        if i < count
          Hive::Config.register_project(name: "new#{i}", path: new_roots.fetch(i))
        else
          Hive::Config.prune_missing_projects!
        end
      end

      data = YAML.safe_load(File.read(File.join(home, "config.yml")))
      names = Array(data["registered_projects"]).map { |entry| entry["name"] }.sort
      assert_equal [ "live", *count.times.map { |i| "new#{i}" } ], names
    end
  end

  def test_load_raises_on_non_hash_yaml
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), "- a\n- b\n")
      assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
    end
  end

  # --- Deep-merge semantics (closes doc-review F3) -----------------------

  def test_deep_merge_keeps_siblings_at_three_levels_nested
    # Pre-U2 bug: a partial override at review.ci.command would wipe every
    # other key under review.ci. The recursive deep-merge keeps siblings.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          ci:
            command: bin/ci
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal "bin/ci", cfg.dig("review", "ci", "command")
      assert_equal 3,        cfg.dig("review", "ci", "max_attempts"), "max_attempts must fall back to default"
      assert_nil cfg.dig("review", "ci", "agent"),
                 "implementation-owning CI agent stays absent for execute inheritance"
      assert_equal "ci_fix_prompt.md.erb", cfg.dig("review", "ci", "prompt_template")
      # Other sibling blocks at review.* must also stay intact.
      assert_equal "courageous", cfg.dig("review", "triage", "bias")
      assert_equal 2,            cfg.dig("review", "max_passes")
    end
  end

  def test_deep_merge_partial_triage_override_keeps_other_triage_defaults
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          triage:
            bias: safetyist
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal "safetyist", cfg.dig("review", "triage", "bias")
      assert_equal "claude",    cfg.dig("review", "triage", "agent"),   "agent default must persist"
      assert_equal true,        cfg.dig("review", "triage", "enabled"), "enabled default must persist"
    end
  end

  def test_deep_merge_partial_agents_override_keeps_other_profiles
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        agents:
          codex:
            min_version: "0.5.0"
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal "0.5.0", cfg.dig("agents", "codex", "min_version")
      assert_equal "codex", cfg.dig("agents", "codex", "bin"),          "codex.bin default must persist"
      assert_equal "claude", cfg.dig("agents", "claude", "bin"),        "claude profile must stay intact"
      assert_equal "pi", cfg.dig("agents", "pi", "bin"),                "pi profile must stay intact"
    end
  end

  def test_review_reviewers_replaces_wholesale_not_per_element
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: only-one
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: only-one
              prompt_template: reviewer_claude_ce_code_review.md.erb
      YAML
      cfg = Hive::Config.load(dir)
      reviewers = cfg.dig("review", "reviewers")
      assert_equal 1, reviewers.size
      assert_equal "only-one", reviewers.first["name"]
    end
  end

  def test_review_adhoc_reviewers_accepts_reviewer_entries
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          adhoc:
            fix: true
            reviewers:
              - name: adhoc-one
                kind: agent
                agent: claude
                skill: ce-code-review
                output_basename: adhoc-one
                prompt_template: reviewer_claude_ce_code_review.md.erb
                permissions: yolo
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal true, cfg.dig("review", "adhoc", "fix")
      assert_equal [ "adhoc-one" ], cfg.dig("review", "adhoc", "reviewers").map { |entry| entry.fetch("name") }
    end
  end

  # --- Validation --------------------------------------------------------

  def test_load_raises_when_reviewers_is_not_an_array
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            this: is_a_hash_not_an_array
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.reviewers/, err.message)
      assert_match(/must be an Array/, err.message)
    end
  end

  def test_load_raises_when_reviewer_entry_is_not_a_hash
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - not-a-hash
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.reviewers\[0\].*must be a Hash/, err.message)
    end
  end

  def test_load_raises_when_review_adhoc_is_not_a_hash
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          adhoc: false
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }

      assert_match(/review\.adhoc/, err.message)
      assert_match(/must be a Hash/, err.message)
    end
  end

  def test_load_raises_when_review_adhoc_reviewers_is_not_array_or_nil
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          adhoc:
            reviewers:
              name: not-array
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }

      assert_match(/review\.adhoc\.reviewers/, err.message)
      assert_match(/must be an Array/, err.message)
    end
  end

  def test_load_raises_when_review_adhoc_fix_is_not_boolean
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          adhoc:
            fix: yes-please
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }

      assert_match(/review\.adhoc\.fix/, err.message)
      assert_match(/must be a boolean/, err.message)
    end
  end

  def test_load_rejects_review_adhoc_permissions_block
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          adhoc:
            permissions: yolo
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }

      assert_match(/review\.adhoc\.permissions/, err.message)
      assert_match(/review\.adhoc\.reviewers/, err.message)
    end
  end

  def test_load_raises_on_duplicate_reviewer_name
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: dup-reviewer
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: a
              prompt_template: reviewer_claude_ce_code_review.md.erb
            - name: dup-reviewer
              kind: agent
              agent: codex
              skill: ce-code-review
              output_basename: b
              prompt_template: reviewer_codex_ce_code_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/duplicate name "dup-reviewer"/, err.message)
    end
  end

  def test_load_raises_on_duplicate_output_basename
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: a
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: collision
              prompt_template: reviewer_claude_ce_code_review.md.erb
            - name: b
              kind: agent
              agent: codex
              skill: ce-code-review
              output_basename: collision
              prompt_template: reviewer_codex_ce_code_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/duplicate output_basename "collision"/, err.message)
    end
  end

  def test_load_accepts_codex_review_reviewer_without_skill
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: codex-native-review
              kind: codex_review
              agent: codex
              output_basename: codex-native-review
              prompt_template: reviewer_codex_native_review.md.erb
      YAML
      cfg = Hive::Config.load(dir)
      reviewer = cfg.dig("review", "reviewers").first
      assert_equal "codex_review", reviewer["kind"]
      refute reviewer.key?("skill"), "codex_review needs no skill"
    end
  end

  def test_load_still_requires_name_and_basename_uniqueness_for_codex_review
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: dup-native
              kind: codex_review
              agent: codex
              output_basename: a
              prompt_template: reviewer_codex_native_review.md.erb
            - name: dup-native
              kind: codex_review
              agent: codex
              output_basename: b
              prompt_template: reviewer_codex_native_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/duplicate name "dup-native"/, err.message)
    end
  end

  def test_load_requires_prompt_template_for_codex_review
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: codex-native-review
              kind: codex_review
              agent: codex
              output_basename: codex-native-review
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.reviewers\[0\]\.prompt_template.*is missing/, err.message)
    end
  end

  def test_load_requires_agent_for_codex_review
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      # codex_review resolves the codex binary via
      # Hive::AgentProfiles.lookup(spec.fetch("agent")); a spec missing
      # `agent` would crash mid-dispatch with KeyError, so it must fail at
      # config load. (The generic validate_agent_name! returns early on nil,
      # so without `agent` in the required list this entry would pass load.)
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: codex-native-review
              kind: codex_review
              output_basename: codex-native-review
              prompt_template: reviewer_codex_native_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.reviewers\[0\]\.agent.*is missing/, err.message)
    end
  end

  def test_load_requires_name_for_codex_review
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - kind: codex_review
              agent: codex
              output_basename: codex-native-review
              prompt_template: reviewer_codex_native_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.reviewers\[0\]\.name.*is missing/, err.message)
    end
  end

  def test_load_accepts_linter_reviewer_kind_at_config_load
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      # `linter` is deliberately accepted at config-load time and rejected
      # only at dispatch (Hive::Reviewers.dispatch) so the more actionable
      # dispatch-time error — pointing at review.ci.command — is what the
      # user sees. Pin that design: load must NOT raise and the kind must
      # round-trip.
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: my-linter
              kind: linter
              skill: ce-code-review
              output_basename: my-linter
              prompt_template: reviewer_codex_native_review.md.erb
      YAML
      cfg = Hive::Config.load(dir)
      reviewer = cfg.dig("review", "reviewers").first
      assert_equal "linter", reviewer["kind"],
                   "linter kind is accepted at config load and rejected only at dispatch"
    end
  end

  def test_load_rejects_unknown_reviewer_kind
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: bogus
              kind: nonsense
              agent: codex
              output_basename: bogus
              prompt_template: reviewer_codex_native_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/kind.*must be one of/, err.message)
    end
  end

  # ce-review P2 #6 — output_basename starting with a reserved
  # orchestrator prefix would silently have its per-pass file (e.g.
  # `errors-01.md`) classified as orchestrator-owned by
  # `Hive::Stages::Review.reviewer_file?`, hidden from triage's
  # `discover_reviewer_files`, and (for `output_basename: "errors"`
  # specifically) overwritten by the U2 errors sink.
  def test_load_raises_when_output_basename_collides_with_reserved_prefix
    %w[errors escalations fix-guardrail fix-success browser ci-blocked].each do |reserved|
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
          review:
            reviewers:
              - name: bad
                kind: agent
                agent: claude
                skill: ce-code-review
                output_basename: #{reserved}
                prompt_template: reviewer_claude_ce_code_review.md.erb
        YAML
        err = assert_raises(Hive::ConfigError, "output_basename #{reserved.inspect} must be rejected") do
          Hive::Config.load(dir)
        end
        assert_match(/output_basename .* reserved orchestrator-owned prefix/, err.message,
                     "error message must explain why #{reserved.inspect} was rejected")
      end
    end
  end

  # ce-review P3 #8 — max_attempts is parsed by the adapter at spawn
  # time but should also fail loudly at config-load when malformed,
  # so operators don't discover a typo deep in a 6-review pass.
  def test_load_raises_when_max_attempts_is_zero
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: bad
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: ok
              prompt_template: reviewer_claude_ce_code_review.md.erb
              max_attempts: 0
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/max_attempts .* positive Integer/, err.message)
    end
  end

  def test_load_raises_when_max_attempts_is_negative
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: bad
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: ok
              prompt_template: reviewer_claude_ce_code_review.md.erb
              max_attempts: -1
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/max_attempts .* positive Integer/, err.message)
    end
  end

  def test_load_raises_when_max_attempts_is_string
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: bad
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: ok
              prompt_template: reviewer_claude_ce_code_review.md.erb
              max_attempts: "two"
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/max_attempts .* positive Integer/, err.message)
    end
  end

  # ce-review round-3 P1 #2 — output_basename containing path
  # separators or `.`/`..` flows into `reviews/<basename>-NN.md` and
  # the retry-loop cleanup `File.delete(output_path)` could then
  # delete files outside the reviews/ dir.
  def test_load_raises_when_output_basename_contains_path_separator
    %w[../escape foo/bar foo\\bar . .. \0nul].each do |bad|
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
          review:
            reviewers:
              - name: bad
                kind: agent
                agent: claude
                skill: ce-code-review
                output_basename: #{bad.inspect}
                prompt_template: reviewer_claude_ce_code_review.md.erb
        YAML
        err = assert_raises(Hive::ConfigError, "output_basename #{bad.inspect} must be rejected") do
          Hive::Config.load(dir)
        end
        assert_match(/single filename component|path separators|'\.\.'|'\.'/, err.message,
                     "error message must explain why #{bad.inspect} was rejected")
      end
    end
  end

  def test_load_accepts_auto_commit_scope_check_override
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          fix:
            auto_commit:
              scope_check:
                enabled: false
                allowed_paths:
                  - custom/**
                denied_paths:
                  - forbidden/**
      YAML
      cfg = Hive::Config.load(dir)
      scope = cfg.dig("review", "fix", "auto_commit", "scope_check")

      assert_equal false, scope["enabled"]
      assert_equal [ "custom/**" ], scope["allowed_paths"]
      assert_equal [ "forbidden/**" ], scope["denied_paths"]
    end
  end

  def test_load_rejects_malformed_auto_commit_scope_check
    cases = [
      [ "scope_check: nope\n", /scope_check.*must be a Hash/ ],
      [ "scope_check:\n  enabled: maybe\n", /scope_check\.enabled.*must be true or false/ ],
      [ "scope_check:\n  allowed_paths: lib/**\n", /allowed_paths.*must be an Array/ ],
      [ "scope_check:\n  allowed_paths:\n", /allowed_paths.*must be an Array/ ],
      [ "scope_check:\n  denied_paths:\n", /denied_paths.*must be an Array/ ],
      [ "scope_check:\n  allowed_paths:\n    - ' '\n", /allowed_paths\[0\].*non-empty String/ ],
      [ "scope_check:\n  denied_paths:\n    - /abs/**\n", /denied_paths\[0\].*relative path glob/ ],
      [ "scope_check:\n  denied_paths:\n    - ../**\n", /denied_paths\[0\].*relative path glob/ ],
      [ "scope_check:\n  denied_paths:\n    - 'C:\\secrets\\**'\n", /denied_paths\[0\].*relative path glob/ ]
    ]

    cases.each do |body, pattern|
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
          review:
            fix:
              auto_commit:
                #{body.gsub("\n", "\n                ")}
        YAML

        err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
        assert_match pattern, err.message
      end
    end
  end

  def test_load_rejects_malformed_review_fix_container
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          fix: false
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.fix.*must be a Hash/, err.message)
    end
  end

  def test_load_rejects_malformed_auto_commit_container
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          fix:
            auto_commit: false
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.fix\.auto_commit.*must be a Hash/, err.message)
      assert_match(/scope_check\.enabled/, err.message)
    end
  end

  def test_auto_commit_scope_validation_allows_missing_legacy_scope
    cfg = { "review" => { "fix" => {} } }

    Hive::Config.send(:validate_review_fix_auto_commit_scope!, cfg, "test")
    assert_nil Hive::Config.send(:validate_path_glob_list!, nil, "review.fix.auto_commit.scope_check.allowed_paths", "test")
  end

  def test_auto_commit_scope_direct_validator_accepts_scope_config
    cfg = {
      "review" => {
        "fix" => {
          "auto_commit" => {
            "scope_check" => {
              "enabled" => true,
              "allowed_paths" => [ "lib/**" ],
              "denied_paths" => [ "config/**" ]
            }
          }
        }
      }
    }

    Hive::Config.send(:validate_review_fix_auto_commit_scope!, cfg, "test")
  end

  def test_load_accepts_max_attempts_one_and_three
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: a
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: a
              prompt_template: reviewer_claude_ce_code_review.md.erb
              max_attempts: 1
            - name: b
              kind: agent
              agent: codex
              skill: ce-code-review
              output_basename: b
              prompt_template: reviewer_codex_ce_code_review.md.erb
              max_attempts: 3
      YAML
      assert Hive::Config.load(dir),
             "positive Integer max_attempts (1, 3) must load cleanly"
    end
  end

  def test_load_raises_when_role_agent_is_unknown_profile
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          triage:
            agent: nonexistent_profile
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.triage\.agent "nonexistent_profile"/, err.message)
      assert_match(/not a registered AgentProfile/, err.message)
    end
  end

  # ── Required fields on each reviewer entry (closes AC-6) ───────────────
  # validate_reviewers! must reject missing name / skill / prompt_template
  # at config-load time; otherwise a misconfigured reviewer NoMethodError-s
  # mid-spawn instead of raising Hive::ConfigError at `hive run` startup.

  def test_load_raises_when_reviewer_name_is_missing
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: bad
              prompt_template: reviewer_claude_ce_code_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.reviewers\[0\]\.name/, err.message)
      assert_match(/is missing/, err.message)
    end
  end

  def test_load_raises_when_reviewer_skill_is_missing
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: needs-skill
              kind: agent
              agent: claude
              output_basename: needs-skill
              prompt_template: reviewer_claude_ce_code_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.reviewers\[0\]\.skill/, err.message)
      assert_match(/is missing/, err.message)
    end
  end

  def test_load_raises_when_reviewer_prompt_template_is_missing
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: needs-template
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: needs-template
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.reviewers\[0\]\.prompt_template/, err.message)
      assert_match(/is missing/, err.message)
    end
  end

  def test_load_raises_when_reviewer_skill_is_blank_string
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: blank-skill
              kind: agent
              agent: claude
              skill: "   "
              output_basename: blank-skill
              prompt_template: reviewer_claude_ce_code_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.reviewers\[0\]\.skill/, err.message)
      assert_match(/is missing/, err.message)
    end
  end

  def test_load_raises_when_reviewer_agent_is_unknown_profile
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: bad-reviewer
              kind: agent
              agent: nonexistent_profile
              skill: ce-code-review
              output_basename: bad-reviewer
              prompt_template: reviewer_claude_ce_code_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.reviewers\[0\]\.agent "nonexistent_profile"/, err.message)
    end
  end

  def test_load_raises_when_reviewers_key_is_nil
    # User typed `reviewers:` with no value — YAML parses to nil. Without
    # this guard the early-return swallowed the typo and downstream code
    # NoMethodError'd on .each. Closes ce-code-review #12.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.reviewers/, err.message)
      assert_match(/is nil/, err.message)
    end
  end

  def test_load_raises_on_empty_output_basename
    # output_basename: "" would yield reviews/-NN.md filenames. Closes
    # ce-code-review #11.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: empty-basename
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: ""
              prompt_template: reviewer_claude_ce_code_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/output_basename/, err.message)
      assert_match(/must not be empty/, err.message)
    end
  end

  def test_load_raises_on_whitespace_only_output_basename
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          reviewers:
            - name: ws-basename
              kind: agent
              agent: claude
              skill: ce-code-review
              output_basename: "   "
              prompt_template: reviewer_claude_ce_code_review.md.erb
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/output_basename/, err.message)
      assert_match(/must not be empty/, err.message)
    end
  end

  def test_validation_error_message_notes_when_no_config_file_present
    # When there is no config.yml on disk, validation errors mentioning
    # the source path should call that out so the user isn't sent to a
    # phantom file. Closes ce-code-review #13.
    #
    # Reproducing the no-file-present validation failure requires the
    # defaults to themselves fail validation, which they don't by design
    # (only user input fails validation). So we exercise the
    # `describe_source` helper indirectly by registering a tampered
    # claude profile name and writing a config that picks an unknown
    # agent — but the source_path describe applies regardless.
    #
    # Direct unit test of the helper:
    msg = Hive::Config.send(:describe_source, "/no/such/file.yml")
    assert_match %r{/no/such/file\.yml \(defaults; no file present\)}, msg
    # When the file does exist, no annotation:
    Tempfile.create([ "config", ".yml" ]) do |f|
      f.write("---\n")
      f.flush
      assert_equal f.path, Hive::Config.send(:describe_source, f.path)
    end
  end

  # --- Positive-integer review knobs --------------------------------------
  # 0 / negative / non-integer values yield degenerate runner behavior:
  #   review.ci.max_attempts: 0           → CiFix runs once and bails
  #   review.browser_test.max_attempts: 0 → BrowserTest writes blocked.md without spawn
  #   review.max_passes: 0                → pass loop exits before Phase 2
  #   review.max_wall_clock_sec: 0        → wall_clock_exceeded? trips immediately
  # Validation catches each at config-load time so misconfig fails at
  # `hive run` startup, not silently mid-loop.

  def test_load_raises_when_review_ci_max_attempts_is_zero
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          ci:
            max_attempts: 0
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.ci\.max_attempts/, err.message)
      assert_match(/positive integer/, err.message)
    end
  end

  def test_load_raises_when_review_ci_max_attempts_is_negative
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          ci:
            max_attempts: -1
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.ci\.max_attempts/, err.message)
    end
  end

  def test_load_raises_when_review_ci_max_attempts_is_non_integer
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          ci:
            max_attempts: 1.5
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.ci\.max_attempts/, err.message)
    end
  end

  def test_load_raises_when_review_triage_max_attempts_is_zero
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          triage:
            max_attempts: 0
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.triage\.max_attempts/, err.message)
      assert_match(/positive integer/, err.message)
    end
  end

  def test_load_raises_when_review_triage_max_attempts_is_negative
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          triage:
            max_attempts: -1
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.triage\.max_attempts/, err.message)
    end
  end

  def test_load_raises_when_review_triage_max_attempts_is_non_integer
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          triage:
            max_attempts: 1.5
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.triage\.max_attempts/, err.message)
    end
  end

  def test_load_raises_when_review_browser_test_max_attempts_is_zero
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          browser_test:
            max_attempts: 0
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.browser_test\.max_attempts/, err.message)
    end
  end

  def test_load_raises_when_review_max_passes_is_zero
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          max_passes: 0
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.max_passes/, err.message)
    end
  end

  def test_load_raises_when_review_max_wall_clock_sec_is_zero
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          max_wall_clock_sec: 0
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.max_wall_clock_sec/, err.message)
    end
  end

  def test_load_accepts_review_knobs_at_default_positive_values
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          ci:
            max_attempts: 5
          browser_test:
            max_attempts: 3
          max_passes: 6
          max_wall_clock_sec: 7200
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal 5, cfg.dig("review", "ci", "max_attempts")
      assert_equal 3, cfg.dig("review", "browser_test", "max_attempts")
      assert_equal 6, cfg.dig("review", "max_passes")
      assert_equal 7200, cfg.dig("review", "max_wall_clock_sec")
    end
  end

  # --- New defaults present ----------------------------------------------

  def test_new_review_defaults_are_present
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)
      assert_equal 3,         cfg.dig("review", "ci", "max_attempts")
      assert_nil cfg.dig("review", "ci", "agent")
      assert_equal "courageous", cfg.dig("review", "triage", "bias")
      assert_equal false,     cfg.dig("review", "browser_test", "enabled")
      assert_equal 2,         cfg.dig("review", "max_passes")
      assert_equal 28_800,    cfg.dig("review", "max_wall_clock_sec")
      assert_equal "claude",  cfg.dig("agents", "claude", "bin")
      assert_equal "codex",   cfg.dig("agents", "codex", "bin")
      assert_equal "pi",      cfg.dig("agents", "pi", "bin")
    end
  end

  # --- HIVE_HOME explicit-but-nonexistent validation --------------------
  # Silent `[]` on a typo'd HIVE_HOME hid the misconfiguration and made
  # `hive status --json | jq .ok` falsely report `true`. The validation
  # fires only when ENV["HIVE_HOME"] is explicitly set AND the directory
  # doesn't exist — the default path (env unset) and the legitimate
  # first-install state (dir exists, no config.yml yet) must continue to
  # work without raising.

  def test_registered_projects_raises_when_hive_home_explicitly_nonexistent
    prev = ENV["HIVE_HOME"]
    ENV["HIVE_HOME"] = "/tmp/hive-test-definitely-does-not-exist-#{rand(1_000_000)}"
    err = assert_raises(Hive::ConfigError) { Hive::Config.registered_projects }
    assert_match(/HIVE_HOME is set to a path that does not exist/, err.message)
    assert_includes err.message, ENV["HIVE_HOME"]
  ensure
    ENV["HIVE_HOME"] = prev
  end

  def test_registered_projects_returns_empty_when_hive_home_unset
    prev = ENV["HIVE_HOME"]
    ENV.delete("HIVE_HOME")
    # Default ~/Dev/hive may or may not have a config.yml; what matters is
    # that the validation doesn't fire and the call returns an Array. Stub
    # global_config_path to a guaranteed-missing file so we exercise the
    # "no config.yml" branch deterministically.
    Hive::Config.singleton_class.alias_method(:__orig_global_config_path, :global_config_path)
    Hive::Config.define_singleton_method(:global_config_path) { "/nonexistent-#{rand(1_000_000)}/config.yml" }
    begin
      assert_equal [], Hive::Config.registered_projects
    ensure
      Hive::Config.singleton_class.alias_method(:global_config_path, :__orig_global_config_path)
      Hive::Config.singleton_class.send(:remove_method, :__orig_global_config_path)
      ENV["HIVE_HOME"] = prev
    end
  end

  def test_registered_projects_returns_empty_when_hive_home_dir_exists_but_no_config
    Dir.mktmpdir("hive-empty-home") do |dir|
      prev = ENV["HIVE_HOME"]
      ENV["HIVE_HOME"] = dir
      begin
        assert_equal [], Hive::Config.registered_projects,
                     "directory exists but no config.yml is the legitimate fresh-install state"
      ensure
        ENV["HIVE_HOME"] = prev
      end
    end
  end

  def test_register_project_still_works_on_first_call_with_fresh_hive_home
    # `register_project` must continue to lazy-create config.yml on first
    # use even though `registered_projects` now validates HIVE_HOME. The
    # validation guards READ paths only; register_project does its own
    # mkdir_p and reads the YAML file directly without going through
    # registered_projects.
    Dir.mktmpdir("hive-fresh-home") do |dir|
      prev = ENV["HIVE_HOME"]
      ENV["HIVE_HOME"] = dir
      begin
        entry = Hive::Config.register_project(name: "first", path: "/tmp/first")
        assert_equal "first", entry["name"]
        assert File.exist?(File.join(dir, "config.yml")),
               "register_project must lazy-create config.yml on first use"
        # registered_projects after registration still works (directory now
        # exists AND config.yml is now there).
        projects = Hive::Config.registered_projects
        assert_equal 1, projects.size
        assert_equal "first", projects.first["name"]
      ensure
        ENV["HIVE_HOME"] = prev
      end
    end
  end

  def test_unregister_project_removes_named_entry_and_returns_it
    with_tmp_global_config do
      Hive::Config.register_project(name: "keep", path: "/tmp/keep")
      Hive::Config.register_project(name: "drop", path: "/tmp/drop")

      removed = Hive::Config.unregister_project(name: "drop")
      assert_equal "drop", removed["name"]
      assert_equal "/tmp/drop", removed["path"]

      remaining = Hive::Config.registered_projects.map { |p| p["name"] }
      assert_equal [ "keep" ], remaining
    end
  end

  def test_unregister_project_returns_nil_for_unknown_name
    with_tmp_global_config do
      Hive::Config.register_project(name: "keep", path: "/tmp/keep")
      assert_nil Hive::Config.unregister_project(name: "ghost"),
                 "unregister_project must return nil for an unknown name (idempotent inverse of register)"
      assert_equal 1, Hive::Config.registered_projects.size,
                   "config must be untouched when no entry matched"
    end
  end

  def test_unregister_project_returns_nil_when_no_global_config_file
    Dir.mktmpdir("hive-no-config") do |dir|
      prev = ENV["HIVE_HOME"]
      ENV["HIVE_HOME"] = dir
      begin
        assert_nil Hive::Config.unregister_project(name: "anything")
        refute File.exist?(File.join(dir, "config.yml")),
               "unregister must not lazy-create config.yml when there's nothing to remove"
      ensure
        ENV["HIVE_HOME"] = prev
      end
    end
  end

  def test_prune_missing_projects_drops_entries_whose_path_is_gone
    with_tmp_global_config do
      Dir.mktmpdir("hive-live-project") do |live_dir|
        Hive::Config.register_project(name: "live", path: live_dir)
        Hive::Config.register_project(name: "dead", path: "/tmp/hive-prune-#{rand(1_000_000)}-gone")
        Hive::Config.register_project(name: "dead2", path: "/tmp/hive-prune-#{rand(1_000_000)}-also-gone")

        result = Hive::Config.prune_missing_projects!
        names = result.fetch(:removed).map { |e| e["name"] }.sort
        assert_equal [ "dead", "dead2" ], names
        assert_equal 1, result.fetch(:kept_count),
                     "kept_count must reflect rows surviving the prune"

        kept = Hive::Config.registered_projects.map { |p| p["name"] }
        assert_equal [ "live" ], kept
      end
    end
  end

  def test_prune_missing_projects_dry_run_returns_targets_without_writing
    with_tmp_global_config do |home|
      Dir.mktmpdir("hive-live-project") do |live_dir|
        Hive::Config.register_project(name: "live", path: live_dir)
        Hive::Config.register_project(name: "dead", path: "/tmp/hive-prune-#{rand(1_000_000)}-gone")

        before = File.read(File.join(home, "config.yml"))
        result = Hive::Config.prune_missing_projects!(dry_run: true)
        after = File.read(File.join(home, "config.yml"))

        assert_equal [ "dead" ], result.fetch(:removed).map { |e| e["name"] }
        assert_equal 1, result.fetch(:kept_count)
        assert_equal before, after, "dry-run must not rewrite config.yml"
        assert_equal 2, Hive::Config.registered_projects.size,
                     "registry must still contain both entries after a dry-run"
      end
    end
  end

  def test_prune_missing_projects_returns_empty_removed_when_all_paths_exist
    with_tmp_global_config do
      Dir.mktmpdir("hive-live-1") do |a|
        Dir.mktmpdir("hive-live-2") do |b|
          Hive::Config.register_project(name: "a", path: a)
          Hive::Config.register_project(name: "b", path: b)
          result = Hive::Config.prune_missing_projects!
          assert_empty result.fetch(:removed),
                       "no rows should be dropped when every path exists"
          assert_equal 2, result.fetch(:kept_count)
          assert_equal 2, Hive::Config.registered_projects.size
        end
      end
    end
  end

  def test_prune_missing_projects_ignores_malformed_private_real_path_metadata
    with_tmp_global_config do |home|
      Dir.mktmpdir("hive-live-project") do |live_dir|
        File.write(
          File.join(home, "config.yml"),
          {
            "registered_projects" => [
              {
                "name" => "live",
                "path" => live_dir,
                "hive_state_path" => File.join(live_dir, ".hive-state"),
                "real_path" => 123
              }
            ]
          }.to_yaml
        )

        result = Hive::Config.prune_missing_projects!

        assert_empty result.fetch(:removed),
                     "invalid private real_path metadata must fall back to legacy path-existence behavior"
        assert_equal 1, result.fetch(:kept_count)
        assert_equal [ "live" ], Hive::Config.registered_projects.map { |project| project["name"] }
      end
    end
  end

  def test_prune_missing_projects_ignores_unexpandable_private_real_path_metadata
    with_tmp_global_config do |home|
      Dir.mktmpdir("hive-live-project") do |live_dir|
        File.write(
          File.join(home, "config.yml"),
          {
            "registered_projects" => [
              {
                "name" => "live",
                "path" => live_dir,
                "hive_state_path" => File.join(live_dir, ".hive-state"),
                "real_path" => [ "bad", "path" ].join(0.chr)
              }
            ]
          }.to_yaml
        )

        result = Hive::Config.prune_missing_projects!

        assert_empty result.fetch(:removed),
                     "unexpandable private real_path metadata must fall back to legacy path-existence behavior"
        assert_equal 1, result.fetch(:kept_count)
        assert_equal [ "live" ], Hive::Config.registered_projects.map { |project| project["name"] }
      end
    end
  end

  # Regression for the P0 Array#- subtraction bug: two registry rows
  # with identical content (same name + same path) used to be both
  # deleted by `entries - [removed]` because Array# uses Hash#==
  # equality. Index-based delete removes exactly the row at the matched
  # index. We can't reach this state via register_project (which dedups
  # by name) but a hand-edited config.yml or a write race can produce
  # it, and the loader's tolerance for malformed rows means it survives
  # to runtime.
  def test_unregister_project_with_identical_duplicate_entries_removes_only_one
    with_tmp_global_config do |home|
      File.write(
        File.join(home, "config.yml"),
        {
          "registered_projects" => [
            { "name" => "dup", "path" => "/tmp/hive-dup", "hive_state_path" => "/tmp/hive-dup/.hive-state" },
            { "name" => "dup", "path" => "/tmp/hive-dup", "hive_state_path" => "/tmp/hive-dup/.hive-state" }
          ]
        }.to_yaml
      )

      removed = Hive::Config.unregister_project(name: "dup")
      refute_nil removed
      assert_equal "dup", removed["name"]

      remaining = YAML.safe_load(File.read(File.join(home, "config.yml")))["registered_projects"]
      assert_equal 1, remaining.size,
                   "Array#- subtraction would have cleared both identical rows; index-based delete must keep one"
      assert_equal "dup", remaining.first["name"]
    end
  end

  # Loader tolerance: a hand-edited row (non-Hash, missing path, nil
  # path) used to crash `registered_projects` and brick every command.
  # Now the loader skips invalid rows so the rest of the surface stays
  # usable; `hive prune` operates below the loader and drops them.
  def test_registered_projects_skips_malformed_rows_instead_of_raising
    with_tmp_global_config do |home|
      File.write(
        File.join(home, "config.yml"),
        {
          "registered_projects" => [
            { "name" => "good", "path" => "/tmp/hive-good" },
            "not-a-hash",
            { "name" => "missing-path" },
            { "name" => nil, "path" => "/tmp/hive-anon" },
            { "name" => "nil-path", "path" => nil }
          ]
        }.to_yaml
      )

      assert_equal [ "good" ], Hive::Config.registered_projects.map { |p| p["name"] }
    end
  end

  def test_prune_drops_malformed_rows_and_reports_them
    with_tmp_global_config do |home|
      Dir.mktmpdir("hive-live") do |live_dir|
        File.write(
          File.join(home, "config.yml"),
          {
            "registered_projects" => [
              { "name" => "live", "path" => live_dir, "hive_state_path" => File.join(live_dir, ".hive-state") },
              "not-a-hash",
              { "name" => "missing-path" }
            ]
          }.to_yaml
        )

        result = Hive::Config.prune_missing_projects!
        assert_equal 2, result.fetch(:removed).size,
                     "the non-Hash row and the missing-path row must both be dropped"
        assert_equal 1, result.fetch(:kept_count)
      end
    end
  end

  # Psych::SyntaxError on malformed YAML used to leak as InternalError
  # (exit 70) — schemas promise exit 78 (CONFIG) for "bad config".
  def test_registered_projects_rewraps_psych_syntax_error_as_config_error
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), "registered_projects: [\nthis: is: not: yaml")

      err = assert_raises(Hive::ConfigError) { Hive::Config.registered_projects }
      assert_match(/not valid YAML/, err.message)
    end
  end

  # NEW-1: unregister_project must validate $HIVE_HOME first so a typoed
  # env var surfaces as ConfigError (exit 78), not as a missing-name
  # USAGE error (exit 64) that masks the real problem.
  def test_unregister_project_validates_hive_home_when_explicitly_missing
    prev = ENV["HIVE_HOME"]
    ENV["HIVE_HOME"] = "/tmp/hive-does-not-exist-#{Process.pid}-#{rand(1_000_000)}"
    err = assert_raises(Hive::ConfigError) { Hive::Config.unregister_project(name: "anything") }
    assert_match(/HIVE_HOME/, err.message)
  ensure
    ENV["HIVE_HOME"] = prev
  end

  def test_prune_missing_projects_validates_hive_home_when_explicitly_missing
    prev = ENV["HIVE_HOME"]
    ENV["HIVE_HOME"] = "/tmp/hive-does-not-exist-#{Process.pid}-#{rand(1_000_000)}"
    err = assert_raises(Hive::ConfigError) { Hive::Config.prune_missing_projects! }
    assert_match(/HIVE_HOME/, err.message)
  ensure
    ENV["HIVE_HOME"] = prev
  end

  # P3 #21: a hand-edited row with `name: 42` (Integer) used to be
  # invisible to `hive forget 42` because String != Integer. Stringify
  # both sides so CLI registry cleanup can still target it.
  def test_unregister_project_matches_integer_named_entry_via_string_coercion
    with_tmp_global_config do |home|
      File.write(
        File.join(home, "config.yml"),
        {
          "registered_projects" => [
            { "name" => 42, "path" => "/tmp/hive-int", "hive_state_path" => "/tmp/hive-int/.hive-state" }
          ]
        }.to_yaml
      )

      removed = Hive::Config.unregister_project(name: "42")
      refute_nil removed, "Integer name must be reachable via the String passed by the CLI"
      assert_equal 42, removed["name"]
    end
  end

  # P3 #22: EACCES on the config file used to surface as
  # `internal error: Errno::EACCES: ...` at exit 70. Now: ConfigError
  # (exit 78) — the root cause is a configuration-access problem, not
  # a Hive bug.
  def test_load_global_config_rewraps_eacces_as_config_error
    with_tmp_global_config do |home|
      path = File.join(home, "config.yml")
      File.write(path, { "registered_projects" => [] }.to_yaml)
      File.chmod(0o000, path)

      err = assert_raises(Hive::ConfigError) { Hive::Config.registered_projects }
      assert_match(/not readable/, err.message)
    ensure
      File.chmod(0o644, path) if path && File.exist?(path)
    end
  end

  # P3 #22 (write half): ENOSPC / EACCES on the config write surface
  # as ConfigError, not InternalError. This mirrors the read-side
  # classification so an agent's error envelope is consistent across
  # the two failure paths.
  def test_write_global_config_rewraps_eacces_as_config_error
    with_tmp_global_config do |home|
      path = File.join(home, "config.yml")
      File.write(path, { "registered_projects" => [] }.to_yaml)
      FileUtils.chmod(0o500, home)

      err = assert_raises(Hive::ConfigError) do
        Hive::Config.send(:write_global_config!, { "registered_projects" => [ { "name" => "x", "path" => "/tmp/x" } ] })
      end
      assert_match(/could not be locked/, err.message)
    ensure
      FileUtils.chmod(0o700, home) if home && File.directory?(home)
      File.chmod(0o644, path) if path && File.exist?(path)
    end
  end

  def test_write_global_config_preserves_existing_file_mode
    with_tmp_global_config do |home|
      path = File.join(home, "config.yml")
      File.write(path, { "registered_projects" => [] }.to_yaml)
      File.chmod(0o600, path)

      Hive::Config.send(:write_global_config!, { "registered_projects" => [ { "name" => "x", "path" => "/tmp/x" } ] })

      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal [ "x" ], Hive::Config.registered_projects.map { |project| project["name"] }
    end
  end

  def test_write_global_config_preserves_existing_file_mode_under_restrictive_umask
    with_tmp_global_config do |home|
      path = File.join(home, "config.yml")
      File.write(path, { "registered_projects" => [] }.to_yaml)
      File.chmod(0o644, path)
      previous_umask = File.umask(0o077)

      Hive::Config.send(:write_global_config!, { "registered_projects" => [ { "name" => "x", "path" => "/tmp/x" } ] })

      assert_equal 0o644, File.stat(path).mode & 0o777,
                   "atomic rewrite must restore the previous mode after tempfile creation applies umask"
    ensure
      File.umask(previous_umask) if previous_umask
    end
  end

  def test_write_global_config_rewraps_config_path_directory_as_config_error
    with_tmp_global_config do |home|
      path = File.join(home, "config.yml")
      FileUtils.rm_f(path)
      FileUtils.mkdir_p(path)

      err = assert_raises(Hive::ConfigError) do
        Hive::Config.send(:write_global_config!, { "registered_projects" => [] })
      end

      assert_match(/could not be written/, err.message)
    end
  end

  def test_global_config_lock_rewraps_lock_path_directory_as_config_error
    with_tmp_global_config do |home|
      FileUtils.mkdir_p(File.join(home, "config.yml.lock"))

      err = assert_raises(Hive::ConfigError) do
        Hive::Config.register_project(name: "x", path: "/tmp/x")
      end

      assert_match(/could not be locked/, err.message)
    end
  end

  def test_global_config_lock_rewraps_flock_errors_and_closes_lock
    with_tmp_global_config do |home|
      lock_path = File.join(home, "config.yml.lock")
      fake_lock = Object.new
      closed = false
      fake_lock.define_singleton_method(:flock) { |_mode| raise Errno::EIO, "flock failed" }
      fake_lock.define_singleton_method(:close) { closed = true }
      original_open = File.method(:open)
      replacement = lambda do |*args, &block|
        args.first == lock_path ? fake_lock : original_open.call(*args, &block)
      end

      err = nil
      with_replaced_singleton_method(File, :open, replacement) do
        err = assert_raises(Hive::ConfigError) do
          Hive::Config.send(:with_global_config_lock) { flunk "lock body must not run" }
        end
      end

      assert_match(/could not be locked/, err.message)
      assert_equal true, closed, "flock failure must still close the lock fd"
    end
  end

  def test_write_global_config_cleans_tempfile_when_rename_fails
    with_tmp_global_config do |home|
      path = File.join(home, "config.yml")
      File.write(path, { "registered_projects" => [] }.to_yaml)
      original_rename = File.method(:rename)
      replacement = lambda do |*args|
        raise Errno::ENOSPC, "full" if args.last == path

        original_rename.call(*args)
      end

      err = nil
      with_replaced_singleton_method(File, :rename, replacement) do
        err = assert_raises(Hive::ConfigError) do
          Hive::Config.send(:write_global_config!, { "registered_projects" => [ { "name" => "x", "path" => "/tmp/x" } ] })
        end
      end

      assert_match(/could not be written/, err.message)
      assert_empty Dir.glob(File.join(home, ".config.yml.tmp.*")), "failed atomic writes must clean tempfiles"
      assert_equal [], Hive::Config.registered_projects
    end
  end

  # ── ADR-024: daemon settings ──────────────────────────────────────────

  # Per-project default `daemon.enabled` is `false` so legacy projects
  # whose YAML predates the `daemon:` block don't silently flip on. Same
  # pattern ADR-023 used for stage agents.
  def test_load_returns_default_daemon_disabled_when_key_absent
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)
      assert_equal false, cfg.dig("daemon", "enabled"),
                   "legacy projects without daemon: key must default to disabled"
    end
  end

  def test_load_returns_default_babysitter_disabled_when_key_absent
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)

      assert_equal(
        {
          "enabled" => false,
          "interval" => "10m",
          "max_concurrent_prs" => 2,
          "labels_ignore" => %w[wip do-not-merge draft],
          "dry_run" => false,
          "auto_rebase" => true,
          "budget_minutes" => 30,
          "budget_usd" => 50
        },
        cfg.fetch("babysitter")
      )
    end
  end

  def test_load_merges_partial_babysitter_config_with_defaults
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        babysitter:
          enabled: true
      YAML

      cfg = Hive::Config.load(dir)

      assert_equal true, cfg.dig("babysitter", "enabled")
      assert_equal "10m", cfg.dig("babysitter", "interval")
      assert_equal 2, cfg.dig("babysitter", "max_concurrent_prs")
      assert_equal %w[wip do-not-merge draft], cfg.dig("babysitter", "labels_ignore")
    end
  end

  def test_load_babysitter_auto_rebase_defaults_true_and_round_trips
    with_tmp_dir do |dir|
      assert_equal true, Hive::Config.load(dir).dig("babysitter", "auto_rebase")

      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        babysitter:
          auto_rebase: false
      YAML
      assert_equal false, Hive::Config.load(dir).dig("babysitter", "auto_rebase")
    end
  end

  def test_load_rejects_non_boolean_babysitter_auto_rebase
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        babysitter:
          auto_rebase: "yes"
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/babysitter\.auto_rebase.*must be a boolean/, err.message)
    end
  end

  def test_load_rejects_non_boolean_babysitter_enabled
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        babysitter:
          enabled: "yes"
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/babysitter\.enabled.*must be a boolean/, err.message)
    end
  end

  def test_load_rejects_invalid_babysitter_interval
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        babysitter:
          interval: 10x
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/babysitter\.interval/, err.message)
    end
  end

  def test_load_rejects_non_string_babysitter_labels
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        babysitter:
          labels_ignore:
            - wip
            - 123
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/babysitter\.labels_ignore.*Array of Strings/, err.message)
    end
  end

  def test_load_returns_documented_daemon_numeric_defaults
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)
      assert_equal 30,    cfg.dig("daemon", "poll_interval_sec")
      assert_equal 1,     cfg.dig("daemon", "fast_poll_sec")
      assert_equal 30,    cfg.dig("daemon", "edit_debounce_sec")
      assert_equal 300,   cfg.dig("daemon", "pr_merge_poll_interval_sec")
      assert_equal 3,     cfg.dig("daemon", "max_concurrent_runs")
      assert_equal 3,     cfg.dig("daemon", "max_concurrent_per_project")
      assert_equal 50,    cfg.dig("daemon", "max_runs_per_day_per_project")
      assert_equal 60,    cfg.dig("daemon", "transient_retry_backoff_sec")
      assert_equal 600,   cfg.dig("daemon", "shutdown_grace_sec")
      # R-02 per-child timeout knobs.
      assert_equal 0,     cfg.dig("daemon", "child_timeout_sec")
      assert_equal 30,    cfg.dig("daemon", "child_kill_grace_sec")
      # The digest and answer-digest verbs ship a non-zero default cap so a
      # wedged child can't pin the single global digest slot forever; every
      # other verb stays at the (disabled) child_timeout_sec default.
      assert_equal({ "digest" => 3600, "answer-digest" => 3600 },
                   cfg.dig("daemon", "child_verb_timeouts"))
    end
  end

  def test_load_rejects_negative_daemon_child_timeout_sec
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          child_timeout_sec: -1
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/daemon.child_timeout_sec.*>= 0/, err.message)
    end
  end

  def test_load_honors_daemon_child_verb_timeouts_override
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          child_verb_timeouts:
            review: 10800
            develop: 5400
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal 10800, cfg.dig("daemon", "child_verb_timeouts", "review")
      assert_equal 5400,  cfg.dig("daemon", "child_verb_timeouts", "develop")
      # A user override deep-merges with the seeded default, so the digest
      # wedge backstop survives an operator setting other verb timeouts.
      assert_equal 3600,  cfg.dig("daemon", "child_verb_timeouts", "digest"),
                   "an operator override must not wipe the default digest verb timeout"
    end
  end

  def test_load_rejects_non_integer_daemon_child_verb_timeout
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          child_verb_timeouts:
            review: forever
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/daemon.child_verb_timeouts\["review"\].*integer >= 0/, err.message)
    end
  end

  def test_load_rejects_non_hash_daemon_child_verb_timeouts
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          child_verb_timeouts: 600
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/daemon.child_verb_timeouts.*must be a Hash/, err.message)
    end
  end

  def test_load_honors_per_project_daemon_enabled_true
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          enabled: true
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal true, cfg.dig("daemon", "enabled")
      # Other daemon defaults should still come from DEFAULTS via deep-merge.
      assert_equal 30, cfg.dig("daemon", "poll_interval_sec")
      assert_equal 1, cfg.dig("daemon", "fast_poll_sec")
    end
  end

  def test_load_honors_per_project_daemon_partial_override
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          enabled: true
          poll_interval_sec: 15
          max_concurrent_runs: 5
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal true, cfg.dig("daemon", "enabled")
      assert_equal 15,   cfg.dig("daemon", "poll_interval_sec")
      assert_equal 5,    cfg.dig("daemon", "max_concurrent_runs")
      # Unspecified keys still fall back to defaults via deep-merge.
      assert_equal 50,   cfg.dig("daemon", "max_runs_per_day_per_project")
    end
  end

  def test_load_rejects_non_boolean_daemon_enabled
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          enabled: "yes"
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/daemon.enabled.*must be a boolean/, err.message)
    end
  end

  def test_load_rejects_too_small_daemon_poll_interval
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          poll_interval_sec: 2
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/daemon.poll_interval_sec.*>= 5/, err.message)
    end
  end

  def test_load_rejects_too_small_daemon_fast_poll
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          fast_poll_sec: 0
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/daemon.fast_poll_sec.*>= 1/, err.message)
    end
  end

  def test_load_rejects_too_small_pr_merge_poll_interval
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          pr_merge_poll_interval_sec: 30
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/daemon.pr_merge_poll_interval_sec.*>= 60/, err.message)
    end
  end

  def test_load_rejects_zero_max_concurrent_runs
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          max_concurrent_runs: 0
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/daemon.max_concurrent_runs.*>= 1/, err.message)
    end
  end

  def test_load_rejects_negative_edit_debounce
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          edit_debounce_sec: -1
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/daemon.edit_debounce_sec.*>= 0/, err.message)
    end
  end

  def test_load_accepts_zero_edit_debounce
    # 0 is a valid choice (operator wants instant dispatch on first
    # mtime move, no debounce window).
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          edit_debounce_sec: 0
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal 0, cfg.dig("daemon", "edit_debounce_sec")
    end
  end

  def test_load_rejects_non_hash_daemon_section
    # daemon: enabled    (scalar; user forgot the nested mapping)
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon: enabled
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/daemon.*must be a Hash/, err.message)
    end
  end

  def test_load_rejects_non_boolean_daemon_autostart
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        daemon:
          autostart: sometimes
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/daemon.autostart.*must be a boolean/, err.message)
    end
  end

  # PR-40 review P1 #2: load_global_daemon merges the operator's
  # ~/Dev/hive/config.yml `daemon:` overrides over Config::DEFAULTS,
  # so `hive daemon start` actually honours configured caps.

  def test_load_global_daemon_returns_defaults_when_no_global_config
    with_tmp_global_config do |home|
      # Default with_tmp_global_config writes an empty registered_projects.
      # With no `daemon:` block in the global yaml, defaults flow through.
      File.write(File.join(home, "config.yml"), { "registered_projects" => [] }.to_yaml)
      cfg = Hive::Config.load_global_daemon
      assert_equal 30, cfg["poll_interval_sec"]
      assert_equal 1, cfg["fast_poll_sec"]
      assert_equal 3, cfg["max_concurrent_runs"]
      assert_equal 50, cfg["max_runs_per_day_per_project"]
    end
  end

  def test_load_global_daemon_honors_global_config_overrides
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        daemon:
          poll_interval_sec: 60
          fast_poll_sec: 2
          max_concurrent_runs: 8
          log_max_bytes: 524288
      YAML
      cfg = Hive::Config.load_global_daemon
      assert_equal 60,     cfg["poll_interval_sec"]
      assert_equal 2,      cfg["fast_poll_sec"]
      assert_equal 8,      cfg["max_concurrent_runs"]
      assert_equal 524_288, cfg["log_max_bytes"]
      # Unspecified keys still pull from defaults
      assert_equal 50, cfg["max_runs_per_day_per_project"]
      assert_equal 3,  cfg["max_concurrent_per_project"]
    end
  end

  def test_load_global_daemon_validates_overrides
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        daemon:
          poll_interval_sec: 1
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_daemon }
      assert_match(/daemon.poll_interval_sec.*>= 5/, err.message)
    end
  end

  def test_load_global_daemon_validates_fast_poll
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        daemon:
          fast_poll_sec: 0
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_daemon }
      assert_match(/daemon.fast_poll_sec.*>= 1/, err.message)
    end
  end

  def test_load_global_daemon_rejects_null_concurrency_limits
    %w[
      max_concurrent_runs
      max_concurrent_per_project
      max_concurrent_patrol_scans
      max_runs_per_day_per_project
    ].each do |key|
      with_tmp_global_config do |home|
        File.write(
          File.join(home, "config.yml"),
          { "registered_projects" => [], "daemon" => { key => nil } }.to_yaml
        )

        err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_daemon }
        assert_match(/daemon\.#{Regexp.escape(key)}.*integer >= 1/, err.message)
      end
    end
  end

  def test_load_global_daemon_rejects_non_hash_daemon_block
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        daemon: enabled
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_daemon }
      assert_match(/daemon.*must be a Hash/, err.message)
    end
  end

  def test_load_global_daemon_falls_back_to_defaults_when_no_file
    # No ~/Dev/hive/config.yml at all (first-run before any project
    # was registered): return bare DEFAULTS["daemon"] without raising.
    Dir.mktmpdir do |dir|
      old = ENV["HIVE_HOME"]
      ENV["HIVE_HOME"] = dir
      cfg = Hive::Config.load_global_daemon
      assert_equal 30, cfg["poll_interval_sec"]
      assert_equal 1, cfg["fast_poll_sec"]
    ensure
      ENV["HIVE_HOME"] = old
    end
  end

  def test_load_global_update_defaults_on
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), { "registered_projects" => [] }.to_yaml)
      cfg = Hive::Config.load_global_update
      assert_equal true, cfg["check"]
      assert_equal true, cfg["auto"]
    end
  end

  def test_load_global_update_honors_overrides
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        update:
          auto: false
      YAML
      cfg = Hive::Config.load_global_update
      assert_equal false, cfg["auto"], "operator opt-out of auto-update must take effect"
      assert_equal true, cfg["check"], "unspecified keys fall back to defaults"
    end
  end

  def test_load_global_update_falls_back_to_defaults_when_no_file
    Dir.mktmpdir do |dir|
      old = ENV["HIVE_HOME"]
      ENV["HIVE_HOME"] = dir
      cfg = Hive::Config.load_global_update
      assert_equal true, cfg["check"]
      assert_equal true, cfg["auto"]
    ensure
      ENV["HIVE_HOME"] = old
    end
  end

  def test_load_global_update_rejects_non_hash_block
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        update: enabled
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_update }
      assert_match(/update.*must be a Hash/, err.message)
    end
  end

  def test_load_global_update_rejects_non_boolean
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        update:
          check: sometimes
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_update }
      assert_match(/update\.check.*must be true or false/, err.message)
    end
  end

  def test_load_global_screenote_honors_base_url_config_and_env_override
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        screenote:
          base_url: https://screenote.example
      YAML

      with_env("HIVE_SCREENOTE_BASE_URL" => "https://screenote.env") do
        cfg = Hive::Config.load_global_screenote

        assert_equal "https://screenote.env", cfg["base_url"]
        refute cfg.key?("api_token")
      end
    end
  end

  def test_load_global_screenote_defaults_to_screenote_ai
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), { "registered_projects" => [] }.to_yaml)
      cfg = Hive::Config.load_global_screenote

      assert_equal "https://screenote.ai", cfg["base_url"]
      refute cfg.key?("api_token")
    end
  end

  def test_load_global_screenote_validates_shape_and_url
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        screenote:
          base_url: ftp://screenote.example
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_screenote }
      assert_match(/screenote\.base_url.*http\(s\) URL/, err.message)

      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        screenote: enabled
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_screenote }
      assert_match(/screenote.*must be a Hash/, err.message)

      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        screenote:
          api_token: old-secret
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_screenote }
      assert_match(/remove `screenote\.api_token`/, err.message)
      assert_match(/hive connect screenote/, err.message)
    end
  end

  def test_load_global_screenote_tolerates_blank_or_null_api_token_leftover
    # A bare `api_token:` (null) or empty string is inert config the old
    # config.example.yml shipped, so it must NOT fail. The catch-22 (the
    # prescribed `hive connect screenote` loads this same validation) is lifted
    # ONLY for these blank leftovers: a non-blank token still raises, so a
    # genuine leftover token keeps bricking bare connect until the key is
    # removed — that intended hard failure is covered by the sibling
    # rejects-non-blank test above.
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        screenote:
          base_url: https://screenote.example
          api_token: null
      YAML

      cfg = Hive::Config.load_global_screenote
      assert_equal "https://screenote.example", cfg["base_url"]

      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        screenote:
          api_token: ""
      YAML
      assert Hive::Config.load_global_screenote
    end
  end

  def test_project_config_with_screenote_api_token_gets_migration_error
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        screenote:
          api_token: old-secret
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/remove `screenote\.api_token`/, err.message)
      assert_match(/hive connect screenote/, err.message)
    end
  end

  # ── Daily digest global settings ─────────────────────────────────────

  def test_load_returns_documented_digest_defaults_when_key_absent
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)

      assert_equal false, cfg.dig("digest", "enabled")
      assert_nil cfg.dig("digest", "agent")
      assert_equal 7, cfg.dig("digest", "max_catchup_days")
      assert_equal false, cfg.dig("answer_digest", "enabled")
      assert_equal 9, cfg.dig("answer_digest", "hour")
    end
  end

  def test_load_global_answer_digest_block_honors_overrides
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        answer_digest:
          enabled: true
          hour: 11
      YAML

      cfg = Hive::Config.load_global_answer_digest_block

      assert_equal true, cfg["enabled"]
      assert_equal 11, cfg["hour"]
    end
  end

  def test_load_global_answer_digest_block_rejects_bad_shapes_and_values
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        answer_digest: enabled
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_answer_digest_block }
      assert_match(/answer_digest.*must be a Hash/, err.message)

      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        answer_digest:
          enabled: sometimes
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_answer_digest_block }
      assert_match(/answer_digest\.enabled.*must be a boolean/, err.message)

      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        answer_digest:
          hour: 24
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_answer_digest_block }
      assert_match(/answer_digest\.hour.*between 0 and 23/, err.message)

      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        answer_digest:
          hour: -1
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_answer_digest_block }
      assert_match(/answer_digest\.hour.*between 0 and 23/, err.message)
    end
  end

  def test_load_global_digest_block_honors_overrides
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        digest:
          enabled: true
          agent: codex
          max_catchup_days: 3
      YAML

      cfg = Hive::Config.load_global_digest_block

      assert_equal true, cfg["enabled"]
      assert_equal "codex", cfg["agent"]
      assert_equal 3, cfg["max_catchup_days"]
    end
  end

  def test_load_global_digest_block_defaults_enabled_on_when_bot_configured
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          enabled: true
          chat_id_allowlist:
            - 60499527
      YAML

      cfg = Hive::Config.load_global_digest_block

      assert_equal true, cfg["enabled"],
                   "digest should auto-enable when the Telegram bot is configured with a chat"
    end
  end

  def test_load_global_digest_block_honors_explicit_disable_even_with_bot
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        digest:
          enabled: false
        bot:
          enabled: true
          chat_id_allowlist:
            - 60499527
      YAML

      cfg = Hive::Config.load_global_digest_block

      assert_equal false, cfg["enabled"],
                   "an explicit digest.enabled: false must always be honored as an opt-out"
    end
  end

  def test_load_global_digest_block_stays_off_without_a_deliverable_bot
    with_tmp_global_config do |home|
      # Bot enabled but no chat to deliver to: auto-enabling would only
      # dispatch a paid categorizer that then fails at send time.
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          enabled: true
          chat_id_allowlist: []
      YAML

      assert_equal false, Hive::Config.load_global_digest_block["enabled"],
                   "no allowlisted chat means no deliverable digest, so stay off"
    end

    with_tmp_global_config do |home|
      # Chat present but bot disabled: the user has not turned Telegram on.
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          enabled: false
          chat_id_allowlist:
            - 60499527
      YAML

      assert_equal false, Hive::Config.load_global_digest_block["enabled"],
                   "a disabled bot means Telegram is not set up, so stay off"
    end
  end

  def test_load_global_digest_block_allows_zero_max_catchup_days_as_unbounded
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        digest:
          max_catchup_days: 0
      YAML

      cfg = Hive::Config.load_global_digest_block

      assert_equal 0, cfg["max_catchup_days"]
    end
  end

  def test_load_global_digest_block_rejects_bad_shapes_and_values
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        digest: enabled
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_digest_block }
      assert_match(/digest.*must be a Hash/, err.message)

      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        digest:
          enabled: sometimes
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_digest_block }
      assert_match(/digest\.enabled.*must be a boolean/, err.message)

      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        digest:
          max_catchup_days: -1
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_digest_block }
      assert_match(/digest\.max_catchup_days.*>= 0/, err.message)
    end
  end

  def test_load_global_digest_config_merges_bot_and_agent_limits
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        digest:
          enabled: true
        budget_usd:
          digest: 12
        timeout_sec:
          digest: 34
        bot:
          chat_id_allowlist:
            - 12345
      YAML

      cfg = Hive::Config.load_global_digest_config

      assert_equal true, cfg.dig("digest", "enabled")
      assert_equal 12, cfg.dig("budget_usd", "digest")
      assert_equal 34, cfg.dig("timeout_sec", "digest")
      assert_equal [ 12_345 ], cfg.dig("bot", "chat_id_allowlist")
      assert_equal File.join(home, "logs", "bot.log"), cfg.dig("bot", "log_file")
    end
  end

  def test_load_global_digest_config_rejects_non_positive_budget_and_timeout
    {
      "budget_usd" => "budget_usd.digest",
      "timeout_sec" => "timeout_sec.digest"
    }.each do |group, label|
      with_tmp_global_config do |home|
        File.write(File.join(home, "config.yml"), <<~YAML)
          registered_projects: []
          digest:
            enabled: true
          #{group}:
            digest: 0
        YAML

        err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_digest_config }
        assert_match(/#{Regexp.escape(label)}.*positive number/, err.message,
                     "a non-positive #{label} must be rejected at config load, not crash the categorizer")
      end

      with_tmp_global_config do |home|
        File.write(File.join(home, "config.yml"), <<~YAML)
          registered_projects: []
          #{group}:
            digest: "lots"
        YAML

        err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_digest_config }
        assert_match(/#{Regexp.escape(label)}.*positive number/, err.message)
      end
    end
  end

  # ── Telegram bot global settings ──────────────────────────────────────

  def test_load_returns_documented_bot_defaults_when_key_absent
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)

      assert_equal false, cfg.dig("bot", "enabled")
      assert_equal false, cfg.dig("bot", "pairing_enabled")
      assert_equal [], cfg.dig("bot", "chat_id_allowlist")
      assert_equal 30, cfg.dig("bot", "poll_interval_sec")
      assert_equal 25, cfg.dig("bot", "long_poll_timeout_sec")
      assert_nil cfg.dig("bot", "notification_dedupe_window_sec"),
                 "notification_dedupe_window_sec is deprecated and must be absent from DEFAULTS"
      assert_equal File.join(Hive::Paths.state_home, ".bot.alert_state.json"), cfg.dig("bot", "alert_state_file")
      assert_equal 28_800, cfg.dig("bot", "recovery_reminder_window_sec")
      assert_equal 3600, cfg.dig("bot", "conversation_ttl_sec")
      assert_equal true, cfg.dig("bot", "transcription", "enabled")
      assert_equal "https://api.openai.com/v1/audio/transcriptions", cfg.dig("bot", "transcription", "endpoint")
      assert_equal "whisper-1", cfg.dig("bot", "transcription", "model")
      assert_equal "HIVE_WHISPER_API_KEY", cfg.dig("bot", "transcription", "api_key_env")
      assert_equal 3, cfg.dig("bot", "transcription", "max_retries")
      assert_equal 2, cfg.dig("bot", "transcription", "retry_backoff_sec")
      assert_equal 120, cfg.dig("bot", "transcription", "timeout_sec")
      assert_equal 0.6, cfg.dig("bot", "transcription", "no_speech_threshold")
      assert_equal %w[en ru], cfg.dig("bot", "transcription", "supported_languages")
    end
  end

  def test_load_global_bot_rejects_non_hash_bot_block
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot: enabled
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot }
      assert_match(/bot.*must be a Hash/, err.message)
    end
  end

  def test_load_global_bot_rejects_non_boolean_enabled
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          enabled: sometimes
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot }
      assert_match(/bot\.enabled.*must be a boolean/, err.message)
    end
  end

  def test_load_global_bot_rejects_non_boolean_pairing_enabled
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          pairing_enabled: sometimes
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot }
      assert_match(/bot\.pairing_enabled.*must be a boolean/, err.message)
    end
  end

  def test_load_global_bot_rejects_non_array_allowlist
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          chat_id_allowlist: 12345
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot }
      assert_match(/bot\.chat_id_allowlist.*must be an Array/, err.message)
    end
  end

  def test_load_global_bot_rejects_blank_path
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          pid_file: " "
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot }
      assert_match(/bot\.pid_file.*non-empty String path/, err.message)
    end
  end

  def test_load_global_bot_honors_global_config_overrides
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          enabled: true
          chat_id_allowlist: [12345]
          poll_interval_sec: 10
          log_max_files: 2
      YAML

      cfg = Hive::Config.load_global_bot

      assert_equal true, cfg["enabled"]
      assert_equal [ 12_345 ], cfg["chat_id_allowlist"]
      assert_equal 10, cfg["poll_interval_sec"]
      assert_equal 2, cfg["log_max_files"]
      assert_equal 25, cfg["long_poll_timeout_sec"]
    end
  end

  def test_load_global_bot_uses_hive_home_for_default_paths
    Dir.mktmpdir do |dir|
      old = ENV["HIVE_HOME"]
      ENV["HIVE_HOME"] = dir

      cfg = Hive::Config.load_global_bot

      assert_equal File.join(dir, ".bot.pid"), cfg["pid_file"]
      assert_equal File.join(dir, "logs", "bot.log"), cfg["log_file"]
      assert_equal File.join(dir, ".bot.alert_state.json"), cfg["alert_state_file"]
      assert_equal File.join(dir, ".bot.last_seen_update_id"), cfg["last_seen_state_file"]
    ensure
      ENV["HIVE_HOME"] = old
    end
  end

  def test_load_global_bot_rejects_string_chat_id
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          chat_id_allowlist: ["12345"]
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot }
      assert_match(/bot.chat_id_allowlist\[0\].*Integer/, err.message)
    end
  end

  def test_load_global_bot_rejects_too_large_long_poll_timeout
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          long_poll_timeout_sec: 100
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot }
      assert_match(/bot.long_poll_timeout_sec.*between 5 and 50/, err.message)
    end
  end

  def test_load_global_bot_rejects_non_hash_transcription_block
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          transcription: enabled
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot }
      assert_match(/bot\.transcription.*must be a Hash/, err.message)
    end
  end

  def test_load_global_bot_rejects_bad_transcription_max_retries
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          transcription:
            max_retries: -1
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot }
      assert_match(/bot\.transcription\.max_retries.*integer >= 0/, err.message)
    end
  end

  def test_load_global_bot_rejects_non_boolean_transcription_enabled
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          transcription:
            enabled: sometimes
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot }
      assert_match(/bot\.transcription\.enabled.*boolean/, err.message)
    end
  end

  def test_load_global_bot_rejects_transcription_no_speech_threshold_above_one
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          transcription:
            no_speech_threshold: 1.2
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot }
      assert_match(/bot\.transcription\.no_speech_threshold.*between 0 and 1/, err.message)
    end
  end

  def test_load_global_bot_rejects_bad_transcription_timeout_and_backoff_bounds
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          transcription:
            timeout_sec: -1
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot }
      assert_match(/bot\.transcription\.timeout_sec.*integer >= 0/, err.message)

      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          transcription:
            retry_backoff_sec: -1
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot }
      assert_match(/bot\.transcription\.retry_backoff_sec.*integer >= 0/, err.message)
    end
  end

  def test_load_global_bot_rejects_scalar_transcription_languages
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          transcription:
            supported_languages: en
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot }
      assert_match(/bot\.transcription\.supported_languages.*Array of Strings/, err.message)
    end
  end

  def test_load_global_bot_rejects_blank_transcription_language_entries
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          transcription:
            supported_languages: ["en", " "]
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot }
      assert_match(/bot\.transcription\.supported_languages\[1\].*non-empty String/, err.message)
    end
  end

  def test_load_global_bot_rejects_blank_transcription_endpoint
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          transcription:
            endpoint: " "
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot }
      assert_match(/bot\.transcription\.endpoint.*non-empty String/, err.message)
    end
  end

  def test_load_global_bot_deep_merges_transcription_override
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          transcription:
            model: whisper-large-v3
            supported_languages: []
      YAML

      cfg = Hive::Config.load_global_bot

      assert_equal "whisper-large-v3", cfg.dig("transcription", "model")
      assert_equal [], cfg.dig("transcription", "supported_languages")
      assert_equal "https://api.openai.com/v1/audio/transcriptions", cfg.dig("transcription", "endpoint")
      assert_equal "HIVE_WHISPER_API_KEY", cfg.dig("transcription", "api_key_env")
    end
  end

  def test_load_global_bot_rejects_parent_directory_path_segments
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          pid_file: ../etc/passwd
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot }
      assert_match(/bot.pid_file.*must not contain '\.\.'/, err.message)
    end
  end

  def test_load_global_bot_runtime_requires_token
    with_tmp_global_config do |home|
      old = ENV.delete("HIVE_TELEGRAM_BOT_TOKEN")
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          chat_id_allowlist: [12345]
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot(require_runtime: true) }
      assert_match(/HIVE_TELEGRAM_BOT_TOKEN/, err.message)
    ensure
      ENV["HIVE_TELEGRAM_BOT_TOKEN"] = old if old
    end
  end

  def test_load_global_bot_runtime_requires_non_empty_allowlist
    with_tmp_global_config do
      old = ENV["HIVE_TELEGRAM_BOT_TOKEN"]
      ENV["HIVE_TELEGRAM_BOT_TOKEN"] = "token"

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot(require_runtime: true) }
      assert_match(/bot.chat_id_allowlist.*at least one chat_id/, err.message)
    ensure
      if old
        ENV["HIVE_TELEGRAM_BOT_TOKEN"] = old
      else
        ENV.delete("HIVE_TELEGRAM_BOT_TOKEN")
      end
    end
  end

  def test_load_global_bot_runtime_allows_empty_allowlist_when_pairing_enabled
    with_tmp_global_config do |home|
      old = ENV["HIVE_TELEGRAM_BOT_TOKEN"]
      ENV["HIVE_TELEGRAM_BOT_TOKEN"] = "token"
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          pairing_enabled: true
          chat_id_allowlist: []
      YAML

      cfg = Hive::Config.load_global_bot(require_runtime: true)

      assert_equal true, cfg["pairing_enabled"]
      assert_equal [], cfg["chat_id_allowlist"]
    ensure
      if old
        ENV["HIVE_TELEGRAM_BOT_TOKEN"] = old
      else
        ENV.delete("HIVE_TELEGRAM_BOT_TOKEN")
      end
    end
  end

  def test_load_global_bot_runtime_pairing_still_requires_token
    with_tmp_global_config do |home|
      old = ENV.delete("HIVE_TELEGRAM_BOT_TOKEN")
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          pairing_enabled: true
          chat_id_allowlist: []
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot(require_runtime: true) }
      assert_match(/HIVE_TELEGRAM_BOT_TOKEN/, err.message)
    ensure
      ENV["HIVE_TELEGRAM_BOT_TOKEN"] = old if old
    end
  end

  def test_load_global_bot_runtime_pairing_still_requires_integer_allowlist_entries
    with_tmp_global_config do |home|
      old = ENV["HIVE_TELEGRAM_BOT_TOKEN"]
      ENV["HIVE_TELEGRAM_BOT_TOKEN"] = "token"
      File.write(File.join(home, "config.yml"), <<~YAML)
        registered_projects: []
        bot:
          pairing_enabled: true
          chat_id_allowlist: ["12345"]
      YAML

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_bot(require_runtime: true) }
      assert_match(/bot.chat_id_allowlist\[0\].*Integer/, err.message)
    ensure
      if old
        ENV["HIVE_TELEGRAM_BOT_TOKEN"] = old
      else
        ENV.delete("HIVE_TELEGRAM_BOT_TOKEN")
      end
    end
  end

  # ---- Auto-rebase `rebase:` block (plan
  # docs/plans/2026-05-14-001-feat-hive-auto-rebase-stale-worktree-plan.md U5) ----

  def test_review_fix_auto_commit_sign_policy_defaults_to_inherit
    with_tmp_dir do |dir|
      cfg = Hive::Config.load(dir)
      assert_equal "inherit", cfg.dig("review", "fix", "auto_commit", "sign_policy")
    end
  end

  def test_review_fix_auto_commit_sign_policy_override_is_respected
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          fix:
            auto_commit:
              sign_policy: bypass
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal "bypass", cfg.dig("review", "fix", "auto_commit", "sign_policy")
    end
  end

  def test_review_fix_must_be_hash_for_auto_commit_config
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          fix: claude
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.fix.*must be a Hash/, err.message)
    end
  end

  def test_review_fix_auto_commit_must_be_hash
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          fix:
            auto_commit: inherit
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.fix\.auto_commit.*must be a Hash/, err.message)
    end
  end

  def test_review_fix_auto_commit_sign_policy_must_be_known
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          fix:
            auto_commit:
              sign_policy: always
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.fix\.auto_commit\.sign_policy.*must be one of/, err.message)
      assert_match(/inherit/, err.message)
      assert_match(/bypass/, err.message)
      assert_match(/fail/, err.message)
    end
  end

  def test_review_fix_auto_commit_sign_policy_must_be_string
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        review:
          fix:
            auto_commit:
              sign_policy: true
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/review\.fix\.auto_commit\.sign_policy.*must be one of/, err.message)
      assert_match(/TrueClass/, err.message)
    end
  end

  def test_rebase_defaults_when_block_absent
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), "")
      cfg = Hive::Config.load(dir)
      assert_equal true, cfg.dig("rebase", "enabled")
      assert_equal 2700, cfg.dig("rebase", "conflict_resolution_timeout_sec")
    end
  end

  def test_rebase_enabled_false_override_is_respected
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        rebase:
          enabled: false
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal false, cfg.dig("rebase", "enabled")
      assert_equal 2700, cfg.dig("rebase", "conflict_resolution_timeout_sec"),
                   "other keys keep their defaults when only `enabled` is overridden"
    end
  end

  def test_rebase_timeout_override_is_respected
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        rebase:
          conflict_resolution_timeout_sec: 600
      YAML
      cfg = Hive::Config.load(dir)
      assert_equal 600, cfg.dig("rebase", "conflict_resolution_timeout_sec")
    end
  end

  def test_rebase_enabled_must_be_boolean
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        rebase:
          enabled: "yes"
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/rebase\.enabled.*must be a boolean/, err.message)
    end
  end

  def test_rebase_timeout_must_be_positive_integer
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        rebase:
          conflict_resolution_timeout_sec: 0
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/conflict_resolution_timeout_sec.*must be an integer >= 60/, err.message)
    end
  end

  def test_rebase_timeout_must_be_integer_not_string
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        rebase:
          conflict_resolution_timeout_sec: "five"
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/conflict_resolution_timeout_sec.*must be an integer/, err.message)
    end
  end

  def test_rebase_block_must_be_hash_shaped
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, ".hive-state", "config.yml"), <<~YAML)
        rebase: true
      YAML
      err = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }
      assert_match(/rebase.*must be a Hash/, err.message)
    end
  end

  def test_claude_permission_mode_rejects_unknown_value
    err = assert_raises(Hive::ConfigError) do
      Hive::Config.claude_permission_mode("claude" => { "permission_mode" => "reckless" })
    end

    assert_match(/claude\.permission_mode must be one of/, err.message)
    assert_match(/reckless/, err.message)
  end

  def test_claude_mode_rejects_unknown_value
    err = assert_raises(Hive::ConfigError) do
      Hive::Config.claude_mode("claude" => { "mode" => "warm_pool" })
    end

    assert_match(/claude\.mode must be one of/, err.message)
    assert_match(/warm_pool/, err.message)
  end

  # ── deprecated_bot_keys ──────────────────────────────────────────────────

  def test_deprecated_bot_keys_returns_empty_array_when_bot_is_nil
    result = Hive::Config.deprecated_bot_keys(nil)
    assert_equal [], result,
                   "nil bot config must return empty deprecated list"
  end

  def test_deprecated_bot_keys_returns_empty_array_when_key_absent
    result = Hive::Config.deprecated_bot_keys({})
    assert_equal [], result,
                   "bot config without notification_dedupe_window_sec must return empty deprecated list"
  end

  def test_deprecated_bot_keys_flags_non_default_notification_dedupe_window_sec
    result = Hive::Config.deprecated_bot_keys({ "notification_dedupe_window_sec" => 600 })
    assert_equal 1, result.size,
                 "non-default notification_dedupe_window_sec must appear in deprecated list"
    assert_equal "bot.notification_dedupe_window_sec", result.first[:key]
    assert_includes result.first[:replacement], "alert_state_file"
  end

  def test_warn_deprecated_bot_dedupe_writes_one_stderr_line_per_deprecated_entry
    captured = +""
    Hive::Config.singleton_class.send(:public, :warn_deprecated_bot_dedupe!)
    $stderr = StringIO.new(captured)
    Hive::Config.warn_deprecated_bot_dedupe!({ "notification_dedupe_window_sec" => 600 }, "/tmp/hive-config.yml")
    assert_match(/hive: bot\.notification_dedupe_window_sec.*deprecated.*alert_state_file/,
                 captured,
                 "warn_deprecated_bot_dedupe! must emit one stderr line per deprecated key")
  ensure
    $stderr = STDERR
    Hive::Config.singleton_class.send(:private, :warn_deprecated_bot_dedupe!)
  end

  private

  def run_concurrent_global_config_writers(count)
    skip "fork unavailable" unless Process.respond_to?(:fork)

    reader, writer = IO.pipe
    pids = count.times.map do |i|
      Process.fork do
        writer.close
        reader.read(1)
        yield i
        exit! 0
      rescue Exception => e # rubocop:disable Lint/RescueException
        warn e.full_message
        exit! 1
      ensure
        reader&.close unless reader&.closed?
      end
    end

    reader.close
    count.times { writer.write(".") }
    writer.close
    statuses = pids.map { |pid| Process.wait2(pid).last }
    assert statuses.all?(&:success?), "all child config writers must exit cleanly"
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
    pids&.each do |pid|
      Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end
  end
end
