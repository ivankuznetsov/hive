require "test_helper"
require "hive/commands/module/migration"
require_relative "../../support/patrol_evidence_scenario"

class ModuleMigrationCommandTest < Minitest::Test
  include HiveTestHelper
  include PatrolEvidenceScenario

  Outcome = Data.define(:state)

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

  def test_v1_report_rewrite_remains_repeatable_and_cutover_loadable
    with_tmp_dir do |root|
      report_path = File.join(root, "report.json")
      fixture = File.expand_path(
        "../../fixtures/module_migration/report-v1.json",
        __dir__
      )
      source = File.binread(fixture)
      File.binwrite(report_path, source)
      inbox = File.join(root, "report-evidence", "incoming")
      FileUtils.mkdir_p(inbox)
      %w[deterministic installed].each do |lane|
        File.binwrite(
          File.join(inbox, "#{lane}.json"),
          Hive::Modules::Migration::Report.canonical(
            qualification_bundle(lane: lane)
          )
        )
      end

      report = command(
        "report",
        root,
        yes: true,
        reviewer: "operator",
        live_bindings_resolver:
          qualification_live_resolver
      )
      report.define_singleton_method(:read_state) do
        { "status" => "shadowing" }
      end
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
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
        live_bindings_resolver:
          qualification_live_resolver
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
      repository.define_singleton_method(
        :incoming_bundles
      ) do
        File.binwrite(
          report_path,
          Hive::Modules::Migration::Report.canonical(
            interloper.payload
          )
        )
        {}
      end
      report = command(
        "report",
        root,
        yes: true,
        reviewer: "operator",
        live_bindings_resolver:
          qualification_live_resolver
      )
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
              live_bindings_resolver: nil)
    Hive::Commands::Module::Migration.new(
      action,
      project_root: project,
      json: json,
      stdout: StringIO.new,
      yes: yes,
      reviewer: reviewer,
      live_bindings_resolver: live_bindings_resolver
    )
  end

  def with_singleton_method(target, name, replacement)
    original = target.method(name)
    target.define_singleton_method(name, replacement)
    yield
  ensure
    target.define_singleton_method(name, original)
  end
end
