require "test_helper"
require "hive/commands/refactor_patrol_candidate_migration"

class RefactorPatrolCandidateMigrationCommandTest < Minitest::Test
  include HiveTestHelper

  class FakeMigration
    attr_reader :calls

    def initialize(payload)
      @payload = payload
      @calls = []
    end

    def call(**kwargs)
      @calls << kwargs
      @payload
    end
  end

  class FakeAuthority
    attr_reader :calls

    def initialize(candidate)
      @candidate = candidate
      @calls = 0
    end

    def authorize!
      @calls += 1
      @candidate
    end
  end

  class FakeRetryService
    attr_reader :candidates

    def initialize
      @candidates = []
    end

    def ensure!(runtime:)
      @candidates << runtime
    end
  end

  def test_sweeps_the_current_registry_persists_and_prints_typed_results_for_custom_state_roots
    with_tmp_dir do |home|
      projects = %w[alpha beta].map do |name|
        root = File.join(home, "projects", name)
        state = File.join(root, ".#{name}-runtime")
        FileUtils.mkdir_p(root)
        write_released_v2_job(state, "job-#{name}", malformed: name == "beta")
        {
          "name" => name,
          "path" => root,
          "real_path" => File.realpath(root),
          "hive_state_path" => state
        }
      end
      File.write(File.join(home, "config.yml"), { "registered_projects" => projects }.to_yaml)
      output = StringIO.new

      payload = with_env("HIVE_HOME" => home) do
        Hive::Commands::RefactorPatrolCandidateMigration.new(output: output).call
      end

      printed = JSON.parse(output.string)
      assert_equal payload, printed
      assert_equal "hive-user-profile-job-schema-migration", payload.fetch("schema")
      assert_equal 1, payload.fetch("schema_version")
      assert_equal Process.uid, payload.dig("user_profile", "uid")
      assert_equal home, payload.dig("user_profile", "config_home")
      assert_equal home, payload.dig("user_profile", "state_home")
      assert_match(/\A[0-9a-f]{64}\z/, payload.fetch("registry_digest"))
      assert_equal 3, payload.fetch("target_schema_version")
      assert_equal %w[migrated failed], payload.fetch("projects").map { |project| project.fetch("status") }
      assert_equal [
        File.join(home, "projects", "alpha", ".alpha-runtime"),
        File.join(home, "projects", "beta", ".beta-runtime")
      ], payload.fetch("projects").map { |project| project.fetch("hive_state_path") }
      assert_equal true, payload.fetch("projects").last.fetch("retryable")
      assert_match(/released refactor patrol v2 job/, payload.fetch("projects").last.fetch("error"))

      persisted = with_env("HIVE_HOME" => home) do
        Hive::RefactorPatrol::RegisteredProjectMigrationStatus.new.read
      end
      assert_equal payload, persisted
      schema = JSONSchemer.schema(JSON.parse(File.binread(
        File.expand_path(
          "../../../schemas/hive-user-profile-job-schema-migration.v1.json",
          __dir__
        )
      )))
      assert_empty schema.validate(payload).to_a
      registered = with_env("HIVE_HOME" => home) { Hive::Config.registered_projects }
      assert registered.all? { |project| !project.fetch("project_id").to_s.empty? }
    end
  end

  def test_all_users_prints_aggregate_receipt_and_requires_complete_discovery
    output = StringIO.new
    current = FakeMigration.new({})
    aggregate = FakeMigration.new(
      "schema" => "hive-installed-users-job-schema-migration",
      "schema_version" => 1,
      "status" => "partial",
      "profiles" => []
    )
    command = Hive::Commands::RefactorPatrolCandidateMigration.new(
      output: output,
      migration: current,
      all_users: true,
      all_users_migration: aggregate
    )

    error = assert_raises(Hive::Error) { command.call }

    assert_match(/migration is partial/, error.message)
    assert_empty current.calls
    assert_equal [ { force: true } ], aggregate.calls
    assert_equal "partial",
                 JSON.parse(output.string).fetch("status")
  end

  def test_all_users_returns_a_closed_complete_receipt
    output = StringIO.new
    aggregate = FakeMigration.new(
      "schema" => "hive-installed-users-job-schema-migration",
      "schema_version" => 1,
      "status" => "complete",
      "profiles" => []
    )
    command = Hive::Commands::RefactorPatrolCandidateMigration.new(
      output: output,
      all_users: true,
      all_users_migration: aggregate
    )

    payload = command.call

    assert_equal "complete", payload.fetch("status")
    assert_equal payload, JSON.parse(output.string)
    assert_equal [ { force: true } ], aggregate.calls
  end

  def test_all_users_resume_propagates_non_forced_child_sweeps
    aggregate = FakeMigration.new(
      "schema" => "hive-installed-users-job-schema-migration",
      "schema_version" => 1,
      "status" => "complete",
      "profiles" => []
    )
    Hive::Commands::RefactorPatrolCandidateMigration.new(
      output: StringIO.new,
      all_users: true,
      all_users_migration: aggregate,
      force: false
    ).call

    assert_equal [ { force: false } ], aggregate.calls
  end

  def test_install_wide_retry_is_activated_before_the_sweep
    candidate = Object.new
    runtime = Struct.new(:candidate).new(candidate)
    authority = FakeAuthority.new(runtime)
    retry_service = FakeRetryService.new
    aggregate = FakeMigration.new(
      "schema" => "hive-installed-users-job-schema-migration",
      "schema_version" => 1,
      "status" => "complete",
      "profiles" => []
    )
    command = Hive::Commands::RefactorPatrolCandidateMigration.new(
      output: StringIO.new,
      all_users: true,
      all_users_migration: aggregate,
      all_users_authority: authority,
      ensure_retry_service: true,
      retry_service_installer: retry_service
    )

    command.call

    assert_equal 1, authority.calls
    assert_equal [ runtime ], retry_service.candidates
    assert_equal [ { force: true } ], aggregate.calls
  end

  def test_retry_service_flag_is_rejected_for_current_user_migration
    command = Hive::Commands::RefactorPatrolCandidateMigration.new(
      output: StringIO.new,
      migration: FakeMigration.new({}),
      ensure_retry_service: true
    )

    error = assert_raises(Hive::ConfigError) { command.call }

    assert_match(/requires --all-users/, error.message)
  end

  private

  def write_released_v2_job(state_root, job_id, malformed: false)
    job = {
      "schema" => "hive-refactor-patrol-job",
      "schema_version" => 2,
      "job_id" => job_id,
      "source" => {
        "url" => "https://github.com/acme/demo/pull/7",
        "number" => 7,
        "repository" => "acme/demo",
        "registration" => "demo",
        "base_branch" => "main",
        "base_sha" => "a" * 40,
        "merge_sha" => "b" * 40,
        "merged_at" => "2026-07-10T12:00:00Z",
        "changed_paths" => [ "lib/checkout.rb" ],
        "manifest_checksum" => "c" * 64
      },
      "analysis_sha" => nil,
      "policy" => {
        "discovery" => true,
        "auto_fix" => false,
        "issue_filing" => false
      },
      "state" => "complete",
      "complete" => true,
      "dispositions" => {
        "accepted" => [], "flagged" => [], "suppressed" => []
      },
      "feature_results" => [],
      "review_errors" => [],
      "zero_reason" => "no_mapped_slice",
      "attempts" => [],
      "actions" => [],
      "created_at" => "2026-07-10T10:00:00Z",
      "updated_at" => "2026-07-10T10:01:00Z"
    }
    job.delete("source") if malformed
    path = File.join(state_root, "refactor_patrol", "v2", "jobs", "#{job_id}.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "#{JSON.pretty_generate(job)}\n")
  end
end
