require "test_helper"
require "json"
require "json_schemer"
require "yaml"
require "hive/commands/patrol"
require "hive/config"
require "hive/patrol/feature"
require "hive/patrol/finding"
require "hive/patrol/state_store"

class PatrolCommandTest < Minitest::Test
  include HiveTestHelper

  class FakeMapper
    def initialize(features)
      @features = features
    end

    def call = @features
  end

  class FakeReviewer
    attr_reader :review_errors, :features

    def initialize(findings, review_errors: [])
      @findings = findings
      @review_errors = review_errors
    end

    def call(features)
      @features = features
      @findings
    end
  end

  def test_patrol_records_findings_for_the_workflow_without_local_fix_or_publication
    with_patrol_project do |repo|
      finding = sample_finding

      out, err, status = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer: FakeReviewer.new([ finding ])
        ).call
      end

      assert_equal "", err
      assert_equal Hive::ExitCodes::SUCCESS, status
      payload = JSON.parse(out)
      assert patrol_schemer.valid?(payload),
             patrol_schemer.validate(payload).map { |failure| failure["error"] }.inspect
      assert_equal 1, payload.fetch("findings")
      assert_equal 1, payload.fetch("fix_candidates")
      assert_equal 0, payload.fetch("fixes_attempted")
      assert_equal 0, payload.fetch("fixes_validated")
      assert_equal 0, payload.fetch("prs_opened")
      assert_empty payload.fetch("pr_urls")
      assert_empty payload.fetch("fix_results")

      store = patrol_store(repo)
      pending = store.patrol_fix_admission_outbox.pending
      assert_equal 1, pending.length
      assert_equal finding.id, pending.first.dig("snapshot", "identity")
      assert_empty Dir[File.join(repo, ".hive-state", "patrol", "patches", "*.json")]
    end
  end

  def test_validation_commands_are_no_longer_a_discovery_precondition
    with_patrol_project do |repo|
      config_path = File.join(repo, ".hive-state", "config.yml")
      config = YAML.safe_load_file(config_path, aliases: true)
      config["patrol"]["commands"] = {
        "docs" => nil, "format" => nil, "lint" => nil,
        "public_contract" => nil, "typecheck" => nil, "test" => nil
      }
      File.write(config_path, config.to_yaml)

      out, _err, status = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer: FakeReviewer.new([ sample_finding ])
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      assert_equal 1, JSON.parse(out).fetch("findings")
      assert_equal 1, patrol_store(repo).patrol_fix_admission_outbox.pending.length
    end
  end

  def test_semantic_duplicate_does_not_duplicate_workflow_admission
    with_patrol_project do |repo|
      first = sample_finding
      duplicate = sample_finding
      duplicate.id = "finding-duplicate"

      first_out, = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer: FakeReviewer.new([ first ])
        ).call
      end
      second_out, = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer: FakeReviewer.new([ duplicate ])
        ).call
      end

      assert_equal 1, JSON.parse(first_out).fetch("findings")
      second_payload = JSON.parse(second_out)
      assert_equal 1, second_payload.fetch("findings")
      assert_equal 1, patrol_store(repo).findings.length
      assert_equal 1, patrol_store(repo).patrol_fix_admission_outbox.pending.length
    end
  end

  def test_review_error_keeps_the_scanned_sha_unadvanced
    with_patrol_project do |repo|
      state_path = File.join(repo, ".hive-state", "patrol", "state.json")
      out, _err, status = with_captured_exit do
        command_for(
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer: FakeReviewer.new(
            [], review_errors: [ { "feature_id" => "route-home", "error" => "agent failed" } ]
          )
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      payload = JSON.parse(out)
      refute payload.fetch("review_complete")
      state = JSON.parse(File.read(state_path))
      assert_equal "", state.fetch("last_scanned_sha", "")
      assert_equal true, state.fetch("feature_review_active")
    end
  end

  def test_dry_run_never_materializes_a_workflow_admission
    with_patrol_project do |repo|
      out, _err, status = with_captured_exit do
        command_for(
          dry_run: true,
          mapper: FakeMapper.new([ sample_feature ]),
          reviewer: FakeReviewer.new([ sample_finding ])
        ).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      assert_equal true, JSON.parse(out).fetch("dry_run")
      assert_empty patrol_store(repo).patrol_fix_admission_outbox.pending
    end
  end

  def test_unknown_project_emits_json_config_error
    out, err, status = with_captured_exit do
      Hive::Commands::Patrol.new("missing", json: true).call
    end

    assert_equal Hive::ExitCodes::CONFIG, status
    payload = JSON.parse(out)
    assert_equal false, payload.fetch("ok")
    assert_equal "config", payload.fetch("error_kind")
    assert_includes err, "unknown project"
  end

  def test_manual_capture_refuses_a_reserved_daemon_occurrence
    state = Object.new
    state.define_singleton_method(:recovery_active?) { true }
    command = Hive::Commands::Patrol.new("demo")

    error = assert_raises(Hive::ConfigError) do
      command.send(:patrol_capture, {}, state)
    end

    assert_equal "patrol cycle is already reserved; wait for daemon recovery",
                 error.message
  end

  def test_manual_capture_requires_the_selected_migration_authority
    with_patrol_project do
      entry = Hive::Config.find_project("demo")
      command = Hive::Commands::Patrol.new(
        "demo", migration_authority: :module
      )

      error = assert_raises(Hive::ConfigError) do
        command.send(:build_manual_capture, entry)
      end

      assert_equal "patrol mutation authority is not admitted", error.message
    end
  end

  def test_capture_validation_rejects_wrong_types_and_missing_identity_keys
    entry = {
      "project_id" => "project-1",
      "name" => "demo",
      "path" => "/tmp/demo",
      "hive_state_path" => "/tmp/demo/.hive-state"
    }
    command = Hive::Commands::Patrol.new("demo")

    wrong_type = assert_raises(Hive::ConfigError) do
      command.send(:validate_capture!, Object.new, entry)
    end
    missing_key = assert_raises(Hive::ConfigError) do
      command.send(
        :validate_capture!,
        patrol_capture_for(entry).with(project: {}),
        entry
      )
    end

    assert_match(/does not match the command project or authority/, wrong_type.message)
    assert_match(/does not match the command project or authority/, missing_key.message)
  end

  private

  def patrol_capture_for(entry)
    now = Time.utc(2026, 7, 28, 12, 0, 0)
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "patrol",
      project: {
        "project_id" => entry.fetch("project_id"),
        "name" => entry.fetch("name"),
        "repository" => entry["repository_identity"]
      },
      trigger: { "kind" => "manual", "id" => "manual-1" },
      reservation: { "kind" => "ordinary", "id" => "reservation-1" },
      owner: "legacy",
      owner_epoch: 1,
      selection_input: {
        "kind" => "operation",
        "operation" => "patrol-command-test"
      },
      selection:
        Hive::Modules::Migration::PatrolDecisionProjection.build(
          module_name: "patrol",
          rationale: "due"
        ),
      outcome_class: nil,
      outcome: nil,
      occurred_at: now,
      recorded_at: now
    )
  end

  def with_patrol_project
    previous_usage_path = Hive::UsageDb.instance_variable_get(:@path)
    with_tmp_global_config do |global_home|
      Hive::UsageDb.path = File.join(global_home, "usage.db")
      with_tmp_git_repo do |repo|
        FileUtils.mkdir_p(File.join(repo, ".hive-state"))
        config = Hive::Config.deep_merge(
          Hive::Config.deep_dup(Hive::Config::DEFAULTS),
          {
            "project_name" => "demo",
            "default_branch" => "master",
            "patrol" => {
              "enabled" => true,
              "commands" => { "test" => "true" }
            }
          }
        )
        File.write(File.join(repo, ".hive-state", "config.yml"), config.to_yaml)
        Hive::Config.register_project(name: "demo", path: repo)
        yield repo
      end
    end
  ensure
    Hive::UsageDb.path = previous_usage_path
  end

  def command_for(dry_run: false, mapper: FakeMapper.new([]), reviewer: FakeReviewer.new([]))
    Hive::Commands::Patrol.new(
      "demo",
      json: true,
      dry_run: dry_run,
      mapper_factory: ->(_root, _cfg, _state) { mapper },
      reviewer_factory: ->(_root, _cfg, _state) { reviewer }
    )
  end

  def sample_feature
    Hive::Patrol::Feature.new(
      id: "route-home",
      kind: "route",
      entrypoints: [ "app.rb" ],
      owned_files: [ "app.rb" ],
      context_files: [],
      tests: [ "test/app_test.rb" ]
    )
  end

  def sample_finding
    Hive::Patrol::Finding.new(
      id: "finding-1",
      feature_id: "route-home",
      category: "bug",
      severity: "high",
      confidence: "medium",
      title: "Nil route receiver",
      description: "The route calls through a nil receiver.",
      recommendation: "Guard the receiver before use.",
      scope: "cross_feature",
      contract: "A missing route record must return not found.",
      root_cause: "A route can resolve without a receiver.",
      evidence: [ { "file" => "app.rb", "line" => 1, "snippet" => "route.call" } ]
    )
  end

  def patrol_schemer
    @patrol_schemer ||= JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-patrol")))
    )
  end

  def patrol_store(repo)
    entry = Hive::Config.find_project("demo")
    Hive::Patrol::StateStore.new(
      repo, hive_state_path: entry.fetch("hive_state_path")
    )
  end
end
