require "test_helper"
require "digest"
require "hive/modules/migration/migration_repository"
require "hive/modules/migration/qualification_lane_result"
require "hive/modules/migration/report"
require_relative "../../../support/qualification_run_fixture"

class ModulesMigrationRepositoryTest < Minitest::Test
  include HiveTestHelper
  include QualificationRunFixture

  def test_qualification_run_import_is_immutable_and_confined
    with_tmp_dir do |root|
      fixture = qualification_run_fixture
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)

      first = repository.import_qualification_run(
        descriptor_bytes: fixture.fetch(:descriptor),
        inputs: fixture.fetch(:inputs)
      )
      second = repository.import_qualification_run(
        descriptor_bytes: fixture.fetch(:descriptor),
        inputs: fixture.fetch(:inputs)
      )

      run_id = fixture.dig(:payload, "run_id")
      assert_equal run_id, first
      assert_equal first, second
      assert_equal(
        fixture.fetch(:descriptor),
        repository.qualification_descriptor(run_id)
      )
      assert_equal(
        fixture.dig(
          :inputs, "inputs/candidate/hive-cli-0.7.0.gem",
          :bytes
        ),
        repository.qualification_input(
          run_id, "inputs/candidate/hive-cli-0.7.0.gem"
        )
      )
      assert_raises(Hive::ConfigError) do
        repository.import_qualification_run(
          descriptor_bytes: fixture.fetch(:descriptor),
          inputs: fixture.fetch(:inputs).merge(
            "inputs/candidate/hive-cli-0.7.0.gem" => {
              bytes: "different", mode: 0o600
            }
          )
        )
      end
      assert_raises(Hive::ConfigError) do
        repository.import_qualification_run(
          descriptor_bytes: fixture.fetch(:descriptor),
          inputs: fixture.fetch(:inputs).merge(
            "../outside" => "unsafe"
          )
        )
      end
      assert_raises(Hive::ConfigError) do
        repository.qualification_descriptor("../outside")
      end
    end
  end

  def test_repository_exposes_no_global_incoming_qualification_inbox
    repository =
      Hive::Modules::Migration::MigrationRepository.new(
        root: Dir.mktmpdir("migration-repository")
      )

    refute_respond_to repository, :incoming_bundle
    refute_respond_to repository, :incoming_bundles
    refute Hive::Modules::Migration::MigrationRepository
      .const_defined?(:INCOMING_BUNDLE_ROOT, false)
  ensure
    FileUtils.rm_rf(repository&.root)
  end

  def test_qualification_lane_round_trips_nested_artifacts_and_modes
    with_tmp_dir do |root|
      fixture = qualification_run_fixture
      run_id = fixture.dig(:payload, "run_id")
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      repository.import_qualification_run(
        descriptor_bytes: fixture.fetch(:descriptor),
        inputs: fixture.fetch(:inputs)
      )
      lane = {
        run_id: run_id,
        lane: "deterministic",
        result_bytes:
          Hive::Modules::Migration::QualificationLaneResult.canonical(
            Hive::Modules::Migration::QualificationLaneResult.build(
              run_id: run_id,
              lane: "deterministic",
              status: "passed",
              started_at: "2026-07-30T09:00:00.000000Z",
              ended_at: "2026-07-30T09:00:01.000000Z",
              target_sha256:
                fixture.dig(
                  :payload, "candidate", "source_archive_sha256"
                ),
              exit_code: 0
            ).to_h
          ),
        bundle_bytes: canonical(
          "receipt" => {}, "records" => []
        ),
        artifacts: {
          "logs/deep/stdout.txt" => "ok\n"
        },
        repro_json: canonical("run_id" => run_id),
        repro_script: "#!/usr/bin/env bash\nexit 0\n"
      }

      repository.publish_qualification_lane(**lane)
      repository.publish_qualification_lane(**lane)
      loaded = repository.qualification_lane(
        run_id, "deterministic"
      )

      assert_equal "ok\n",
                   loaded.fetch(
                     "artifacts/logs/deep/stdout.txt"
                   )
      assert_equal lane.fetch(:result_bytes),
                   loaded.fetch("result.json")
      assert_raises(Hive::ConfigError) do
        repository.publish_qualification_lane(
          **lane.merge(result_bytes: "different")
        )
      end

      changed_mode = deep_copy_inputs(fixture.fetch(:inputs))
      changed_mode
        .fetch("inputs/installed-target/bin/hive")[:mode] =
          0o600
      assert_raises(Hive::ConfigError) do
        repository.import_qualification_run(
          descriptor_bytes: fixture.fetch(:descriptor),
          inputs: changed_mode
        )
      end
      assert_raises(Hive::ConfigError) do
        repository.publish_qualification_lane(
          **lane.merge(
            artifacts: {
              "#{"nested/" * 33}artifact.txt" => "too deep"
            }
          )
        )
      end
    end
  end

  def test_terminal_qualification_lane_result_is_a_standalone_immutable_sentinel
    with_tmp_dir do |root|
      fixture = qualification_run_fixture
      run_id = fixture.dig(:payload, "run_id")
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      repository.import_qualification_run(
        descriptor_bytes: fixture.fetch(:descriptor),
        inputs: fixture.fetch(:inputs)
      )
      result =
        Hive::Modules::Migration::QualificationLaneResult.build(
          run_id: run_id,
          lane: "installed",
          status: "failed",
          started_at: "2026-07-30T09:00:00.000000Z",
          ended_at: "2026-07-30T09:00:01.000000Z",
          target_sha256:
            fixture.dig(
              :payload, "candidate", "installed_tree_sha256"
            ),
          exit_code: 1,
          failure_reason: "provider_failed"
        )
      bytes =
        Hive::Modules::Migration::QualificationLaneResult.canonical(
          result.to_h
        )

      repository.publish_qualification_lane_result(
        run_id: run_id,
        lane: "installed",
        result_bytes: bytes
      )
      repository.publish_qualification_lane_result(
        run_id: run_id,
        lane: "installed",
        result_bytes: bytes
      )

      assert_equal(
        bytes,
        repository.qualification_lane_result(
          run_id, "installed"
        )
      )
      assert_raises(Hive::ConfigError) do
        repository.publish_qualification_lane_result(
          run_id: run_id,
          lane: "installed",
          result_bytes:
            Hive::Modules::Migration::QualificationLaneResult.canonical(
              result.to_h.merge(
                "failure_reason" => "scenario_failed"
              )
            )
        )
      end
    end
  end

  def test_blocked_qualification_diagnostics_are_append_only_and_retryable
    with_tmp_dir do |root|
      fixture = qualification_run_fixture
      run_id = fixture.dig(:payload, "run_id")
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      repository.import_qualification_run(
        descriptor_bytes: fixture.fetch(:descriptor),
        inputs: fixture.fetch(:inputs)
      )
      attributes = {
        run_id: run_id,
        lane: "installed",
        status: "blocked",
        started_at: "2026-07-30T09:00:00.000000Z",
        ended_at: "2026-07-30T09:00:01.000000Z",
        target_sha256:
          fixture.dig(
            :payload, "candidate", "installed_tree_sha256"
          )
      }
      unauthorized =
        Hive::Modules::Migration::QualificationLaneResult.build(
          **attributes,
          failure_reason: "live_lane_not_authorized"
        )
      provider =
        Hive::Modules::Migration::QualificationLaneResult.build(
          **attributes,
          failure_reason: "provider_unavailable"
        )
      [ unauthorized, unauthorized, provider ].each do |result|
        repository.publish_qualification_lane_diagnostic(
          run_id: run_id,
          lane: "installed",
          result_bytes:
            Hive::Modules::Migration::
              QualificationLaneResult.canonical(
                result.to_h
              )
        )
      end

      assert_nil repository.qualification_lane_result(
        run_id, "installed", missing: true
      )
      assert_equal(
        %w[
          live_lane_not_authorized provider_unavailable
        ],
        repository.qualification_lane_diagnostics(
          run_id,
          "installed"
        ).map(&:failure_reason).sort
      )
      blocked_bytes =
        Hive::Modules::Migration::
          QualificationLaneResult.canonical(
            unauthorized.to_h
          )
      assert_raises(Hive::ConfigError) do
        repository.publish_qualification_lane_result(
          run_id: run_id,
          lane: "installed",
          result_bytes: blocked_bytes
        )
      end
    end
  end

  def test_qualification_lane_result_is_validated_before_immutable_publication
    with_tmp_dir do |root|
      fixture = qualification_run_fixture
      run_id = fixture.dig(:payload, "run_id")
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      repository.import_qualification_run(
        descriptor_bytes: fixture.fetch(:descriptor),
        inputs: fixture.fetch(:inputs)
      )

      assert_raises(Hive::ConfigError) do
        repository.publish_qualification_lane_result(
          run_id: run_id,
          lane: "installed",
          result_bytes: canonical(
            "run_id" => run_id,
            "lane" => "installed"
          )
        )
      end
      assert_nil repository.qualification_lane_result(
        run_id, "installed", missing: true
      )
    end
  end

  def test_full_lane_publishes_result_only_after_the_capture
    with_tmp_dir do |root|
      fixture = qualification_run_fixture
      run_id = fixture.dig(:payload, "run_id")
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      repository.import_qualification_run(
        descriptor_bytes: fixture.fetch(:descriptor),
        inputs: fixture.fetch(:inputs)
      )

      assert_raises(Hive::ConfigError) do
        repository.publish_qualification_lane(
          run_id: run_id,
          lane: "deterministic",
          result_bytes:
            Hive::Modules::Migration::QualificationLaneResult.canonical(
              Hive::Modules::Migration::QualificationLaneResult.build(
                run_id: run_id,
                lane: "deterministic",
                status: "passed",
                started_at: "2026-07-30T09:00:00.000000Z",
                ended_at: "2026-07-30T09:00:01.000000Z",
                target_sha256:
                  fixture.dig(
                    :payload, "candidate", "source_archive_sha256"
                  ),
                exit_code: 0
              ).to_h
            ),
          bundle_bytes: canonical(
            "receipt" => {}, "records" => []
          ),
          artifacts: { "stdout.txt" => "partial capture\n" },
          repro_json: canonical(
            "run_id" => run_id,
            "lane" => "deterministic"
          ),
          repro_script:
            "x" * (
              Hive::Modules::Migration::MigrationRepository::
                MAX_QUALIFICATION_REPRO_BYTES + 1
            )
        )
      end

      assert_nil repository.qualification_lane_result(
        run_id, "deterministic", missing: true
      )
    end
  end

  def test_mutation_lock_refuses_symlinks_and_non_regular_entries
    with_tmp_dir do |root|
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      outside = File.join(root, "outside")
      File.binwrite(outside, "sentinel")
      lock = File.join(root, ".mutation.lock")
      File.symlink(outside, lock)

      assert_raises(Hive::ConfigError) do
        repository.with_lock { flunk "unsafe symlink lock yielded" }
      end
      assert_equal "sentinel", File.binread(outside)

      File.unlink(lock)
      FileUtils.mkdir_p(lock)
      assert_raises(Hive::ConfigError) do
        repository.with_lock { flunk "non-regular lock yielded" }
      end
    end
  end

  def test_report_and_cutover_transactions_serialize_on_one_lock
    with_tmp_dir do |root|
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      entered = Queue.new
      release = Queue.new
      second = Queue.new
      writer = Thread.new do
        repository.with_lock do
          entered << true
          release.pop
        end
      end
      entered.pop
      cutover = Thread.new do
        repository.with_lock { second << true }
      end

      sleep 0.05
      assert second.empty?, "cutover entered while report transaction held the lock"
      release << true
      writer.join
      cutover.join
      assert_equal true, second.pop
    ensure
      writer&.kill
      cutover&.kill
    end
  end

  def test_report_compare_and_swap_rejects_stale_and_missing_snapshots
    with_tmp_dir do |root|
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      first = report("first")
      second = report("second")
      stale = report("stale")
      repository.write_report(first)
      first_bytes = repository.read_report_bytes
      repository.write_report(second)

      assert_raises(Hive::ConfigError) do
        repository.write_report(
          stale,
          expected_digest:
            Digest::SHA256.hexdigest(first_bytes)
        )
      end
      assert_equal second.payload, repository.load_report.payload
      assert_raises(Hive::ConfigError) do
        repository.write_report(
          stale,
          expected_digest:
            Hive::Modules::Migration::MigrationRepository::EXPECTED_MISSING
        )
      end
      assert_equal second.payload, repository.load_report.payload
    end
  end

  def test_report_write_prunes_only_unreferenced_content_addressed_bundles
    with_tmp_dir do |root|
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      bytes = "{}"
      digest = Digest::SHA256.hexdigest(bytes)
      relative = "report-evidence/#{digest}.json"
      repository.write_bundle(relative, bytes)

      repository.write_report(report("replacement"))

      assert_nil repository.read_bundle(relative, missing: true)
      assert_raises(Hive::ConfigError) do
        repository.write_bundle(
          "report-evidence/#{"f" * 64}.json",
          bytes
        )
      end
    end
  end

  def test_for_creates_an_absent_state_root_from_an_existing_ancestor
    with_tmp_dir do |project_root|
      state_root = File.join(project_root, "nested", ".hive-state")
      repository =
        Hive::Modules::Migration::MigrationRepository.for(
          project_root: project_root,
          hive_state_path: state_root
        )

      assert_nil repository.read_state_bytes
      assert File.directory?(repository.root)
      assert_equal(
        File.join(state_root, "module-runtime", "migration"),
        repository.root
      )
    end
  end

  def test_for_retains_a_symlink_state_root_as_an_unsafe_anchor
    with_tmp_dir do |project_root|
      outside = File.join(project_root, "outside")
      state_root = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(outside)
      File.symlink(outside, state_root)
      repository =
        Hive::Modules::Migration::MigrationRepository.for(
          project_root: project_root,
          hive_state_path: state_root
        )

      assert_raises(Hive::ConfigError) do
        repository.read_state_bytes
      end
      refute_path_exists File.join(outside, "module-runtime")
    end
  end

  def test_for_retains_a_dangling_symlink_state_root_as_an_unsafe_anchor
    with_tmp_dir do |project_root|
      state_root = File.join(project_root, ".hive-state")
      File.symlink(File.join(project_root, "missing"), state_root)
      repository =
        Hive::Modules::Migration::MigrationRepository.for(
          project_root: project_root,
          hive_state_path: state_root
        )

      assert_raises(Hive::ConfigError) do
        repository.read_state_bytes
      end
      assert File.symlink?(state_root)
    end
  end

  def test_for_retains_a_non_directory_state_root_as_an_unsafe_anchor
    with_tmp_dir do |project_root|
      state_root = File.join(project_root, ".hive-state")
      File.binwrite(state_root, "sentinel")
      repository =
        Hive::Modules::Migration::MigrationRepository.for(
          project_root: project_root,
          hive_state_path: state_root
        )

      assert_raises(Hive::ConfigError) do
        repository.read_state_bytes
      end
      assert_equal "sentinel", File.binread(state_root)
    end
  end

  def test_for_fails_closed_when_the_state_root_has_a_non_directory_ancestor
    with_tmp_dir do |project_root|
      blocker = File.join(project_root, "blocker")
      File.binwrite(blocker, "sentinel")
      repository =
        Hive::Modules::Migration::MigrationRepository.for(
          project_root: project_root,
          hive_state_path: File.join(blocker, ".hive-state")
        )

      assert_raises(Hive::ConfigError) do
        repository.read_state_bytes
      end
      assert_equal "sentinel", File.binread(blocker)
    end
  end

  def test_explicit_anchor_rejects_escape_and_symlink_rebinding
    with_tmp_dir do |root|
      anchor = File.join(root, "state")
      FileUtils.mkdir_p(anchor)
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::MigrationRepository.new(
          root: File.join(root, "outside"),
          anchor: anchor
        )
      end

      real = File.join(root, "real-state")
      FileUtils.mkdir_p(real)
      FileUtils.rm_rf(anchor)
      File.symlink(real, anchor)
      repository =
        Hive::Modules::Migration::MigrationRepository.new(
          root: File.join(anchor, "module-runtime", "migration"),
          anchor: anchor
        )
      assert_raises(Hive::ConfigError) do
        repository.with_lock { flunk "symlink anchor yielded" }
      end
    end
  end

  private

  def deep_copy_inputs(inputs)
    inputs.to_h do |path, entry|
      [
        path,
        {
          bytes: entry.fetch(:bytes).dup,
          mode: entry.fetch(:mode)
        }
      ]
    end
  end

  def report(blocker)
    Hive::Modules::Migration::Report.evidence_required(
      blockers: [ blocker ],
      reviewer: "operator",
      reviewed_at: Time.utc(2026, 7, 30)
    )
  end
end
