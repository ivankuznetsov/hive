require "test_helper"
require "hive/commands/module"
require "hive/commands/module/migration"
require_relative "../../support/patrol_evidence_scenario"
require_relative "../../support/qualification_run_fixture"

class ModuleMigrationCommandTest < Minitest::Test
  include HiveTestHelper
  include PatrolEvidenceScenario
  include QualificationRunFixture

  Outcome = Data.define(:state)

  class TrackingEnvironment
    attr_reader :reads

    def initialize(values)
      @values = values
      @reads = []
    end

    def [](key)
      @reads << key
      @values[key]
    end
  end

  class FakeMigration
    attr_reader :rollbacks, :cutovers

    def initialize
      @rollbacks = 0
      @cutovers = []
    end

    def rollback!(now:)
      @rollbacks += 1
      Outcome.new({ "status" => "rolled_back", "at" => now.iso8601 })
    end

    def cutover!(report:, now:)
      @cutovers << [ report, now ]
      Outcome.new({ "status" => "cut_over", "at" => now.iso8601 })
    end

    attr_accessor :report

    def load_report_for_cutover = report
  end

  def test_rollback_and_cutover_emit_the_resulting_state
    with_tmp_dir do |project|
      migration = FakeMigration.new
      rollback = command("rollback", project, yes: true)
      rollback.instance_variable_set(:@migration, migration)

      assert_equal "rolled_back", rollback.call.fetch("status")
      assert_equal 1, migration.rollbacks

      report = Object.new
      cutover = command("cutover", project, yes: true)
      cutover.instance_variable_set(:@migration, migration)
      cutover.define_singleton_method(:migrate_report) { true }
      migration.report = report
      assert_equal "cut_over", cutover.call.fetch("status")
      assert_equal report, migration.cutovers.last.first
    end
  end

  def test_confirmation_state_and_project_identity_fail_closed
    with_tmp_dir do |project|
      denied = command("rollback", project, yes: false)
      assert_raises(Hive::Commands::Module::ConsentRequired) { denied.call }

      status = command("status", project, yes: false, json: false)
      status.define_singleton_method(:read_state) { { "status" => "shadowing" } }
      assert_equal({ "status" => "shadowing" }, status.call)
      assert_match(/Patrol module migration: shadowing/, status.instance_variable_get(:@stdout).string)

      missing = command("status", project, yes: false)
      with_singleton_method(Hive::Modules::Migration::Patrols, :read_state, ->(*) { nil }) do
        assert_raises(Hive::ConfigError) { missing.call }
      end

      registered = [ { "name" => "registered-name", "path" => File.expand_path(project) } ]
      with_singleton_method(Hive::Config, :registered_projects, -> { registered }) do
        assert_equal "registered-name", status.send(:project_name)
      end
      with_singleton_method(Hive::Config, :registered_projects, -> { [] }) do
        assert_equal File.basename(project), status.send(:project_name)
      end
    end
  end

  def test_report_requires_one_explicit_safe_run_id
    with_tmp_dir do |project|
      missing = command(
        "report", project, yes: false, reviewer: "operator"
      )
      missing.define_singleton_method(:read_state) do
        { "status" => "shadowing" }
      end
      error = assert_raises(Hive::Commands::Module::UsageError) do
        missing.call
      end
      assert_includes error.message, "--run-id"

      unsafe = command(
        "report", project, yes: true, reviewer: "operator",
        run_id: "../latest"
      )
      unsafe.define_singleton_method(:read_state) do
        { "status" => "shadowing" }
      end
      error = assert_raises(Hive::Commands::Module::UsageError) do
        unsafe.call
      end
      assert_includes error.message, "--run-id"
    end
  end

  def test_qualify_requires_one_exact_run_and_lane
    with_tmp_dir do |project|
      missing_run = command(
        "qualify", project, yes: false, lane: "installed"
      )
      error = assert_raises(Hive::Commands::Module::UsageError) do
        missing_run.call
      end
      assert_includes error.message, "--run-id"

      unsafe_lane = command(
        "qualify",
        project,
        yes: false,
        run_id: "patrol-#{"1" * 64}",
        lane: "../installed"
      )
      error = assert_raises(Hive::Commands::Module::UsageError) do
        unsafe_lane.call
      end
      assert_includes error.message, "--lane"
    end
  end

  def test_installed_qualify_defaults_closed_without_reading_live_inputs
    with_qualification_repository do |project, repository, run_id|
      environment = TrackingEnvironment.new(
        "HIVE_PATROL_QUALIFICATION_LIVE" => nil,
        "GITHUB_TOKEN" => "must-not-be-read",
        "OPENROUTER_API_KEY" => "must-not-be-read"
      )
      qualify = command(
        "qualify",
        project,
        yes: false,
        run_id: run_id,
        lane: "installed",
        environment: environment,
        registrations: -> { flunk "registry was read" },
        repository_identity: ->(*) { flunk "remote was read" }
      )
      qualify.instance_variable_set(:@repository, repository)

      payload = qualify.call

      assert_equal "blocked", payload.fetch("status")
      assert_equal "live_lane_not_authorized",
                   payload.fetch("failure_reason")
      assert_equal(
        [ "HIVE_PATROL_QUALIFICATION_LIVE" ],
        environment.reads
      )
      assert_equal(
        payload,
        Hive::Modules::Migration::QualificationLaneResult.load(
          repository.qualification_lane_result(
            run_id, "installed"
          )
        ).to_h
      )
      refute File.exist?(
        File.join(
          repository.root,
          "qualification/runs",
          run_id,
          "lanes/installed/bundle.json"
        )
      )
    end
  end

  def test_installed_live_consent_requires_yes_repository_registration_and_remote
    with_qualification_repository do |project, repository, run_id|
      environment = TrackingEnvironment.new(
        "HIVE_PATROL_QUALIFICATION_LIVE" => "1",
        "HIVE_PATROL_QUALIFICATION_REPOSITORY" =>
          "github.com/owner/evidence",
        "GITHUB_TOKEN" => "repository-token",
        "OPENROUTER_API_KEY" => "provider-token"
      )
      qualify = command(
        "qualify",
        project,
        yes: true,
        run_id: run_id,
        lane: "installed",
        environment: environment,
        registrations: -> {
          [
            {
              "name" => "demo",
              "project_id" => "project-1",
              "path" => project,
              "real_path" => File.realpath(project),
              "repository_identity" =>
                "github.com/owner/evidence"
            }
          ]
        },
        repository_identity: ->(root) {
          assert_equal File.expand_path(project), root
          "github.com/owner/evidence"
        }
      )
      qualify.instance_variable_set(:@repository, repository)

      payload = qualify.call

      assert_equal "blocked", payload.fetch("status")
      assert_equal "provider_unavailable",
                   payload.fetch("failure_reason")
      assert_equal(
        %w[
          HIVE_PATROL_QUALIFICATION_LIVE
          HIVE_PATROL_QUALIFICATION_REPOSITORY
          GITHUB_TOKEN
          OPENROUTER_API_KEY
        ],
        environment.reads
      )
    end
  end

  def test_installed_live_consent_mismatch_stays_unauthorized
    with_qualification_repository do |project, repository, run_id|
      environment = TrackingEnvironment.new(
        "HIVE_PATROL_QUALIFICATION_LIVE" => "1",
        "HIVE_PATROL_QUALIFICATION_REPOSITORY" =>
          "github.com/other/repository"
      )
      qualify = command(
        "qualify",
        project,
        yes: true,
        run_id: run_id,
        lane: "installed",
        environment: environment,
        registrations: -> { flunk "registry was read" },
        repository_identity: ->(*) { flunk "remote was read" }
      )
      qualify.instance_variable_set(:@repository, repository)

      payload = qualify.call

      assert_equal "live_lane_not_authorized",
                   payload.fetch("failure_reason")
    end
  end

  def test_report_preserves_result_only_lane_blocker_when_other_lane_failed
    with_qualification_repository do |project, repository, run_id|
      runner =
        Hive::Modules::Migration::QualificationLaneRunner.new(
          repository: repository,
          clock: -> { Time.utc(2026, 7, 31, 10) }
        )
      runner.call(
        run_id: run_id,
        lane: "deterministic"
      )
      runner.call(
        run_id: run_id,
        lane: "installed",
        live_authorized: false
      )
      fixture = qualification_run_fixture
      authority_provider =
        Hive::Modules::Migration::
          QualificationRunAuthorityProvider.new(
            repository: repository
          )
      resolver = qualification_live_resolver(
        project_provider: -> {
          fixture.dig(:payload, "project")
        },
        module_selections:
          fixture.dig(:payload, "module_selections"),
        run_authority_provider:
          authority_provider.method(:call)
      )
      report = command(
        "report",
        project,
        yes: true,
        reviewer: "operator",
        run_id: run_id,
        live_bindings_resolver: resolver
      )
      report.define_singleton_method(:read_state) do
        { "status" => "shadowing" }
      end
      report.instance_variable_set(:@repository, repository)

      payload = report.call

      assert_equal "failed", payload.fetch("status")
      assert_includes(
        payload.fetch("blockers"),
        "installed:qualification_lane_blocked:" \
          "live_lane_not_authorized"
      )
      installed = payload.dig("lanes", "installed")
      assert_equal "blocked", installed.fetch("status")
      assert_nil installed.fetch("bundle_path")
      assert_nil installed.fetch("bundle_digest")
    end
  end

  def test_v1_report_rewrite_remains_repeatable_and_cutover_loadable
    with_tmp_dir do |root|
      report_path = File.join(root, "report.json")
      fixture = File.expand_path(
        "../../fixtures/module_migration/report-v1.json",
        __dir__
      )
      source = File.binread(fixture)
      File.binwrite(report_path, source)
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      run_id = seed_qualification_lanes(repository)
      resolver = qualification_live_resolver(
        authority_documents:
          qualification_authority_documents(run_id: run_id)
      )

      report = command(
        "report",
        root,
        yes: true,
        reviewer: "operator",
        live_bindings_resolver: resolver,
        run_id: run_id
      )
      report.define_singleton_method(:read_state) do
        { "status" => "shadowing" }
      end
      report.instance_variable_set(
        :@repository,
        repository
      )

      payload = report.call
      assert_equal "evidence_ready_for_operator",
                   payload.fetch("status")
      archive = payload.dig("migration", "archive_path")
      assert_equal source, File.binread(File.join(root, archive))
      assert_equal 2, JSON.parse(File.binread(report_path))
                          .fetch("schema_version")

      repeated = Hive::Modules::Migration::ReportMigration.new(
        path: report_path,
        repository: repository
      ).ensure_current!
      assert_equal "current", repeated.status

      migration = FakeMigration.new
      migration.report = repository.load_report(
        live_bindings_resolver: resolver
      )
      cutover = command("cutover", root, yes: true)
      cutover.instance_variable_set(:@repository, repository)
      cutover.instance_variable_set(:@migration, migration)
      assert_equal "cut_over", cutover.call.fetch("status")
      assert_equal payload.fetch("report_id"),
                   migration.cutovers.last.first.payload.fetch("report_id")
    end
  end

  def test_report_replace_cas_cannot_overwrite_a_stale_snapshot
    with_tmp_dir do |root|
      repository =
        Hive::Modules::Migration::MigrationRepository.new(
          root: root
        )
      original = Hive::Modules::Migration::Report.evidence_required(
        blockers: [ "original" ],
        reviewer: "operator",
        reviewed_at: Time.utc(2026, 7, 30)
      )
      interloper =
        Hive::Modules::Migration::Report.evidence_required(
          blockers: [ "interloper" ],
          reviewer: "operator",
          reviewed_at: Time.utc(2026, 7, 30, 1)
        )
      repository.write_report(original)
      report = command(
        "report",
        root,
        yes: true,
        reviewer: "operator",
        live_bindings_resolver:
          qualification_live_resolver,
        run_id: RUN_ID
      )
      report.define_singleton_method(
        :qualification_lane_evidence
      ) do |_run_id|
        File.binwrite(
          report_path,
          Hive::Modules::Migration::Report.canonical(
            interloper.payload
          )
        )
        {}
      end
      report.define_singleton_method(:read_state) do
        { "status" => "shadowing" }
      end
      report.instance_variable_set(:@repository, repository)

      assert_raises(Hive::ConfigError) { report.call }
      assert_equal(
        interloper.payload,
        repository.load_report.payload
      )
    end
  end

  private

  def command(action, project, yes:, json: true, reviewer: nil,
              live_bindings_resolver: nil, run_id: nil, lane: nil,
              environment: ENV,
              registrations: -> { Hive::Config.registered_projects },
              repository_identity:
                ->(root) { Hive::RepositoryIdentity.current(root) })
    Hive::Commands::Module::Migration.new(
      action,
      project_root: project,
      json: json,
      stdout: StringIO.new,
      yes: yes,
      reviewer: reviewer,
      live_bindings_resolver: live_bindings_resolver,
      run_id: run_id,
      lane: lane,
      environment: environment,
      registrations: registrations,
      repository_identity: repository_identity
    )
  end

  def with_singleton_method(target, name, replacement)
    original = target.method(name)
    target.define_singleton_method(name, replacement)
    yield
  ensure
    target.define_singleton_method(name, original)
  end

  def seed_qualification_lanes(repository)
    fixture = qualification_run_fixture
    run_id = repository.import_qualification_run(
      descriptor_bytes: fixture.fetch(:descriptor),
      inputs: fixture.fetch(:inputs)
    )
    %w[deterministic installed].each do |lane|
      repository.publish_qualification_lane(
        run_id: run_id,
        lane: lane,
        result_bytes:
          Hive::Modules::Migration::QualificationLaneResult.canonical(
            Hive::Modules::Migration::QualificationLaneResult.build(
              run_id: run_id,
              lane: lane,
              status: "passed",
              started_at: "2026-07-30T09:00:00.000000Z",
              ended_at: "2026-07-30T09:00:01.000000Z",
              target_sha256:
                fixture_target_sha256(repository, run_id, lane),
              exit_code: 0
            ).to_h
          ),
        bundle_bytes:
          Hive::Modules::Migration::Report.canonical(
            qualification_bundle(
              lane: lane, run_id: run_id
            )
          ),
        artifacts: { "stdout.txt" => "ok\n" },
        repro_json: canonical(
          "run_id" => run_id, "lane" => lane
        ),
        repro_script: "#!/usr/bin/env bash\nexit 0\n"
      )
    end
    run_id
  end

  def fixture_target_sha256(repository, run_id, lane)
    descriptor =
      Hive::Modules::Migration::QualificationRunDescriptor.load(
        repository.qualification_descriptor(run_id)
      )
    key = lane == "installed" ?
      "installed_tree_sha256" : "source_archive_sha256"
    descriptor.candidate.fetch(key)
  end

  def with_qualification_repository
    with_tmp_dir do |project|
      fixture = qualification_run_fixture
      repository =
        Hive::Modules::Migration::MigrationRepository.new(
          root: File.join(project, "migration")
        )
      run_id = repository.import_qualification_run(
        descriptor_bytes: fixture.fetch(:descriptor),
        inputs: fixture.fetch(:inputs)
      )
      yield project, repository, run_id
    end
  end
end
