require "test_helper"
require "open3"
require "rbconfig"
require "hive/modules/migration/migration_repository"
require "hive/modules/migration/qualification_run_authority_provider"
require_relative "../../../support/qualification_run_fixture"

class ModulesMigrationQualificationRunAuthorityProviderTest <
    Minitest::Test
  include HiveTestHelper
  include QualificationRunFixture

  def test_resolves_only_the_exact_descriptor_owned_authority
    with_qualification_repository do |repository, fixture, run_id|
      publish_lane(repository, fixture, "deterministic")
      descriptor =
        Hive::Modules::Migration::QualificationRunDescriptor.load(
          fixture.fetch(:descriptor)
        )

      outcome = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "resolved", outcome.status
      assert_empty outcome.issues
      assert_equal(
        descriptor.authority_for("deterministic"),
        outcome.bindings.reject do |key, _value|
          key == "artifact_digests"
        end
      )
      assert_equal(
        %w[
          artifact.scenario-observations.json artifact.stdout.txt
          repro_json repro_script result
        ],
        outcome.bindings.fetch("artifact_digests").keys.sort
      )
    end
  end

  def test_missing_descriptor_is_blocked_and_never_scans_the_retired_inbox
    with_tmp_dir do |root|
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      legacy = File.join(root, "report-evidence", "incoming")
      FileUtils.mkdir_p(legacy)
      File.binwrite(
        File.join(legacy, "deterministic.json"),
        canonical(
          "run_id" => "patrol-#{"f" * 64}",
          "lane" => "deterministic",
          "authority" => "self-asserted"
        )
      )

      outcome = provider(repository).call(
        run_id: "patrol-#{"0" * 64}",
        lane: "deterministic"
      )

      assert_equal "blocked", outcome.status
      assert_equal(
        [ "qualification_descriptor_missing" ],
        outcome.issues
      )
      assert_nil outcome.bindings
    end
  end

  def test_malformed_descriptor_and_candidate_digest_drift_are_failed
    with_tmp_dir do |root|
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      run_id = "patrol-#{"0" * 64}"
      descriptor_path = File.join(
        root, "qualification", "runs", run_id, "descriptor.json"
      )
      FileUtils.mkdir_p(File.dirname(descriptor_path))
      File.binwrite(descriptor_path, "{}")

      malformed = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "failed", malformed.status
      assert_equal(
        [ "qualification_descriptor_malformed" ],
        malformed.issues
      )

      fixture = qualification_run_fixture
      run_id = repository.import_qualification_run(
        descriptor_bytes: fixture.fetch(:descriptor),
        inputs: fixture.fetch(:inputs)
      )
      source_ref =
        fixture.dig(
          :payload, "lanes", "deterministic", "target_ref"
        )
      File.binwrite(
        File.join(root, "qualification", "runs", run_id, source_ref),
        "substituted"
      )
      publish_lane(repository, fixture, "deterministic")

      drifted = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "failed", drifted.status
      assert_includes drifted.issues, "candidate_artifact_digest_mismatch"
      assert_nil drifted.bindings
    end
  end

  def test_unsafe_candidate_substitution_is_failed
    with_qualification_repository do |repository, fixture, run_id|
      source_ref =
        fixture.dig(
          :payload, "lanes", "deterministic", "target_ref"
        )
      source_path = File.join(
        repository.root, "qualification", "runs", run_id, source_ref
      )
      outside = File.join(repository.root, "outside.tar.gz")
      File.binwrite(outside, "outside")
      File.unlink(source_path)
      File.symlink(outside, source_path)
      publish_lane(repository, fixture, "deterministic")

      outcome = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "failed", outcome.status
      assert_includes outcome.issues, "qualification_input_unsafe"
      assert_nil outcome.bindings
    end
  end

  def test_foreign_result_run_or_lane_is_failed
    [
      { "run_id" => "patrol-#{"f" * 64}" },
      { "lane" => "installed" }
    ].each do |override|
      with_qualification_repository do |repository, fixture, run_id|
        publish_lane(
          repository, fixture, "deterministic",
          result_overrides: override
        )

        outcome = provider(repository).call(
          run_id: run_id, lane: "deterministic"
        )

        assert_equal "failed", outcome.status
        assert_includes(
          outcome.issues,
          override.key?("run_id") ?
            "qualification_result_run_mismatch" :
            "qualification_result_lane_mismatch"
        )
        assert_nil outcome.bindings
      end
    end
  end

  def test_failed_input_precedes_a_missing_lane
    with_qualification_repository do |repository, fixture, run_id|
      source_ref =
        fixture.dig(
          :payload, "lanes", "deterministic", "target_ref"
        )
      File.binwrite(
        File.join(
          repository.root,
          "qualification", "runs", run_id, source_ref
        ),
        "x" * fixture.dig(:inputs, source_ref, :bytes).bytesize
      )

      outcome = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "failed", outcome.status
      assert_equal(
        [ "candidate_artifact_digest_mismatch" ],
        outcome.issues
      )
    end
  end

  def test_provider_can_be_required_without_preloading_the_repository
    lib = File.expand_path("../../../../lib", __dir__)
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-I#{lib}",
      "-e",
      "require 'hive/modules/migration/" \
        "qualification_run_authority_provider'; " \
        "abort unless defined?(" \
        "Hive::Modules::Migration::MigrationRepository)"
    )

    assert status.success?, stderr
  end

  def test_candidate_and_scenario_inputs_require_exact_private_modes
    cases = {
      "inputs/candidate/manifest.json" =>
        "candidate_manifest_mode_mismatch",
      "inputs/scenarios/manifest.json" =>
        "scenario_input_mode_mismatch",
      "inputs/scenarios/patrol-case.yml" =>
        "scenario_input_mode_mismatch"
    }
    cases.each do |relative, issue|
      with_qualification_repository do |repository, _fixture, run_id|
        File.chmod(
          0o700,
          File.join(
            repository.root,
            "qualification", "runs", run_id, relative
          )
        )

        outcome = provider(repository).call(
          run_id: run_id, lane: "deterministic"
        )

        assert_equal "failed", outcome.status, relative
        assert_equal [ issue ], outcome.issues, relative
      end
    end
  end

  def test_nested_scenario_refs_are_inventoried_without_flattening
    with_tmp_dir do |root|
      fixture = nested_scenario_fixture
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      run_id = repository.import_qualification_run(
        descriptor_bytes: fixture.fetch(:descriptor),
        inputs: fixture.fetch(:inputs)
      )
      publish_lane(repository, fixture, "deterministic")

      resolved = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "resolved", resolved.status

      extra = nested_scenario_fixture
      extra.fetch(:inputs)[
        "inputs/scenarios/nested/unmanifested.yml"
      ] = { bytes: "unmanifested\n", mode: 0o600 }
      other_root = File.join(root, "with-extra")
      other_repository =
        Hive::Modules::Migration::MigrationRepository.new(
          root: other_root
        )
      other_run = other_repository.import_qualification_run(
        descriptor_bytes: extra.fetch(:descriptor),
        inputs: extra.fetch(:inputs)
      )
      publish_lane(other_repository, extra, "deterministic")

      substituted = provider(other_repository).call(
        run_id: other_run, lane: "deterministic"
      )

      assert_equal "failed", substituted.status
      assert_equal(
        [ "scenario_input_substitution" ],
        substituted.issues
      )
    end
  end

  def test_passed_installed_capture_replays_without_ambient_credentials
    with_qualification_repository do |repository, fixture, run_id|
      publish_lane(repository, fixture, "installed")

      absent = with_env(
        "GITHUB_TOKEN" => nil,
        "OPENROUTER_API_KEY" => nil
      ) do
        provider(repository).call(
          run_id: run_id, lane: "installed"
        )
      end
      rotated = with_env(
        "GITHUB_TOKEN" => "rotated-github-secret",
        "OPENROUTER_API_KEY" => "rotated-router-secret"
      ) do
        provider(repository).call(
          run_id: run_id, lane: "installed"
        )
      end

      assert_equal "resolved", absent.status
      assert_empty absent.issues
      assert_equal absent, rotated
      assert_equal(
        fixture.dig(
          :payload, "candidate", "installed_tree_sha256"
        ),
        absent.bindings.dig(
          "candidate", "installed_tree_sha256"
        )
      )
    end
  end

  def test_provider_has_no_environment_input
    with_tmp_dir do |root|
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)

      assert_raises(ArgumentError) do
        Hive::Modules::Migration::
          QualificationRunAuthorityProvider.new(
            repository: repository,
            environment: {}
          )
      end
    end
  end

  def test_installed_target_tree_drift_symlink_and_mode_are_failed
    cases = {
      "tree drift" => lambda do |path, root|
        File.binwrite(path, "substituted executable")
      end,
      "symlink" => lambda do |path, root|
        outside = File.join(root, "outside-hive")
        File.binwrite(outside, "outside")
        File.unlink(path)
        File.symlink(outside, path)
      end,
      "mode" => lambda do |path, root|
        root && File.chmod(0o600, path)
      end
    }
    expected = {
      "tree drift" => "installed_target_digest_mismatch",
      "symlink" => "qualification_input_unsafe",
      "mode" => "installed_target_executable_unsafe"
    }
    cases.each do |name, mutation|
      with_qualification_repository do |repository, fixture, run_id|
        executable = File.join(
          repository.root,
          "qualification", "runs", run_id,
          "inputs", "installed-target", "bin", "hive"
        )
        mutation.call(executable, repository.root)
        publish_lane(repository, fixture, "installed")

        outcome = provider(repository).call(
          run_id: run_id, lane: "installed"
        )

        assert_equal "failed", outcome.status, name
        assert_equal [ expected.fetch(name) ], outcome.issues, name
      end
    end
  end

  def test_blocked_result_uses_nil_exit_code_not_success
    with_qualification_repository do |repository, fixture, run_id|
      publish_lane(
        repository, fixture, "deterministic",
        result_overrides: {
          "status" => "blocked",
          "exit_code" => nil,
          "failure_reason" => "provider_unavailable"
        }
      )

      outcome = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "blocked", outcome.status
      assert_equal(
        [ "qualification_lane_blocked:provider_unavailable" ],
        outcome.issues
      )
    end

    with_qualification_repository do |repository, fixture, run_id|
      publish_lane(
        repository, fixture, "deterministic",
        result_overrides: {
          "status" => "blocked",
          "exit_code" => 0,
          "failure_reason" => "provider_unavailable"
        }
      )

      outcome = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "failed", outcome.status
      assert_equal(
        [ "qualification_result_malformed" ],
        outcome.issues
      )
    end
  end

  def test_result_failure_reason_is_a_closed_non_secret_code
    reasons = [
      "provider failed with sk-or-v1-secret",
      "provider_failed\nOPENROUTER_API_KEY=secret",
      "provider_failed\0",
      "provider-failed",
      "PROVIDER_FAILED",
      "x" * (
        Hive::Modules::Migration::QualificationLaneResult::MAX_BYTES
      )
    ]

    reasons.each do |reason|
      with_qualification_repository do |repository, fixture, run_id|
        publish_lane(
          repository, fixture, "deterministic",
          result_overrides: {
            "status" => "failed",
            "exit_code" => 1,
            "failure_reason" => reason
          }
        )

        outcome = provider(repository).call(
          run_id: run_id, lane: "deterministic"
        )

        assert_equal "failed", outcome.status, reason.inspect
        assert_equal(
          [ "qualification_result_malformed" ],
          outcome.issues,
          reason.inspect
        )
        refute_includes outcome.issues.join, "secret"
      end
    end
  end

  def test_closed_failed_result_reason_is_preserved
    with_qualification_repository do |repository, fixture, run_id|
      publish_lane(
        repository, fixture, "deterministic",
        result_overrides: {
          "status" => "failed",
          "exit_code" => 70,
          "failure_reason" => "evidence_verification_failed"
        }
      )

      outcome = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "failed", outcome.status
      assert_equal(
        [
          "qualification_lane_failed:" \
          "evidence_verification_failed"
        ],
        outcome.issues
      )
    end
  end

  def test_blocked_result_needs_no_patrol_capture
    with_qualification_repository do |repository, fixture, run_id|
      publish_result(
        repository, fixture, "installed",
        "status" => "blocked",
        "exit_code" => nil,
        "failure_reason" => "live_lane_not_authorized"
      )

      outcome = provider(repository).call(
        run_id: run_id, lane: "installed"
      )

      assert_equal "blocked", outcome.status
      assert_equal(
        [
          "qualification_lane_blocked:" \
          "live_lane_not_authorized"
        ],
        outcome.issues
      )
      assert_nil outcome.bindings
    end
  end

  def test_passed_result_still_requires_the_full_capture
    with_qualification_repository do |repository, fixture, run_id|
      publish_result(repository, fixture, "deterministic")

      outcome = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "failed", outcome.status
      assert_equal(
        [ "qualification_capture_incomplete_or_unsafe" ],
        outcome.issues
      )
      assert_nil outcome.bindings
    end
  end

  def test_passed_result_requires_scenario_observations_artifact
    with_qualification_repository do |repository, fixture, run_id|
      publish_lane(
        repository, fixture, "deterministic",
        include_observations: false
      )

      outcome = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "failed", outcome.status
      assert_equal(
        [ "qualification_scenario_observations_missing" ],
        outcome.issues
      )
      assert_nil outcome.bindings
    end
  end

  def test_passed_result_rejects_an_unknown_case_or_decision
    {
      "case_id" => "unknown-case",
      "decision_id" => "f" * 64
    }.each do |key, replacement|
      with_qualification_repository do |repository, fixture, run_id|
        publish_lane(repository, fixture, "deterministic")
        mutate_scenario_observations(
          repository, fixture, "deterministic"
        ) do |payload|
          payload.dig("observations", 0)[key] = replacement
        end

        outcome = provider(repository).call(
          run_id: run_id, lane: "deterministic"
        )

        assert_equal "failed", outcome.status, key
        assert_equal(
          [ "qualification_scenario_observation_unknown" ],
          outcome.issues,
          key
        )
        assert_nil outcome.bindings, key
      end
    end
  end

  def test_passed_result_rejects_a_missing_or_duplicate_case_decision
    fixture = qualification_fixture_with_second_decision
    with_qualification_repository(fixture) do |repository, value, run_id|
      publish_lane(repository, value, "deterministic")

      missing = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "failed", missing.status
      assert_equal(
        [ "qualification_scenario_observation_missing" ],
        missing.issues
      )
      assert_nil missing.bindings
    end

    with_qualification_repository do |repository, value, run_id|
      publish_lane(repository, value, "deterministic")
      mutate_scenario_observations(
        repository, value, "deterministic"
      ) do |payload|
        payload.fetch("observations") <<
          JSON.parse(JSON.generate(payload.dig("observations", 0)))
      end

      duplicate = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "failed", duplicate.status
      assert_equal(
        [ "qualification_scenario_observations_malformed" ],
        duplicate.issues
      )
      assert_nil duplicate.bindings
    end
  end

  def test_passed_result_requires_exact_comparator_record_inventory
    mutations = {
      "extra" => lambda do |records, fixture|
        records << record_for(
          module_name: "patrol",
          index: 1,
          decision_class: "clean_negative",
          configuration_digests: {
            "patrol" => "d" * 64,
            "architecture-patrol" => "e" * 64
          },
          project: fixture.dig(:payload, "project")
        )
      end,
      "missing" => ->(records, _fixture) { records.clear },
      "duplicate" => lambda do |records, _fixture|
        records << JSON.parse(JSON.generate(records.fetch(0)))
      end,
      "malformed" => ->(records, _fixture) { records.replace([ {} ]) }
    }
    mutations.each do |name, mutation|
      with_qualification_repository do |repository, fixture, run_id|
        publish_lane(repository, fixture, "deterministic")
        mutate_qualification_bundle(
          repository, fixture, "deterministic"
        ) do |bundle|
          mutation.call(bundle.fetch("records"), fixture)
        end

        outcome = provider(repository).call(
          run_id: run_id, lane: "deterministic"
        )

        assert_equal "failed", outcome.status, name
        assert_equal(
          [ "qualification_scenario_observation_record_unbound" ],
          outcome.issues,
          name
        )
        assert_nil outcome.bindings, name
      end
    end
  end

  def test_passed_result_requires_the_exact_observations_artifact_path
    with_qualification_repository do |repository, fixture, run_id|
      publish_lane(repository, fixture, "deterministic")
      artifact_root = File.join(
        repository.root,
        "qualification", "runs", run_id,
        fixture.dig(
          :payload, "artifact_refs", "deterministic", "artifacts"
        )
      )
      File.rename(
        File.join(artifact_root, "scenario-observations.json"),
        File.join(artifact_root, "scenario_observations.json")
      )

      outcome = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "failed", outcome.status
      assert_equal(
        [ "qualification_scenario_observations_missing" ],
        outcome.issues
      )
      assert_nil outcome.bindings
    end
  end

  def test_passed_result_rejects_a_comparator_semantic_mismatch
    with_qualification_repository do |repository, fixture, run_id|
      publish_lane(repository, fixture, "deterministic")
      mutate_scenario_observations(
        repository, fixture, "deterministic"
      ) do |payload|
        payload.dig(
          "observations", 0, "comparator_semantic_digest"
        ).replace("e" * 64)
      end

      outcome = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "failed", outcome.status
      assert_equal(
        [ "qualification_scenario_observation_comparator_mismatch" ],
        outcome.issues
      )
      assert_nil outcome.bindings
    end
  end

  def test_passed_result_rejects_a_capture_not_bound_to_the_record
    with_qualification_repository do |repository, fixture, run_id|
      publish_lane(repository, fixture, "deterministic")
      alternate =
        qualification_record_with_alternate_capture(fixture)
      mutate_qualification_bundle(
        repository, fixture, "deterministic"
      ) do |bundle|
        bundle["records"] = [ alternate ]
      end

      outcome = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "failed", outcome.status
      assert_equal(
        [ "qualification_scenario_observation_capture_mismatch" ],
        outcome.issues
      )
      assert_nil outcome.bindings
    end
  end

  def test_passed_result_rejects_unbound_effect_keys
    {
      "legacy_effect_keys" => [ "effect-#{"e" * 64}" ],
      "module_effect_keys" => [ "effect-#{"f" * 64}" ]
    }.each do |key, replacement|
      with_qualification_repository do |repository, fixture, run_id|
        publish_lane(repository, fixture, "deterministic")
        mutate_scenario_observations(
          repository, fixture, "deterministic"
        ) do |payload|
          payload.dig("observations", 0)[key] = replacement
        end

        outcome = provider(repository).call(
          run_id: run_id, lane: "deterministic"
        )

        assert_equal "failed", outcome.status, key
        assert_equal(
          [ "qualification_scenario_observation_effect_mismatch" ],
          outcome.issues,
          key
        )
        assert_nil outcome.bindings, key
      end
    end
  end

  def test_passed_result_rejects_descriptor_effects_not_observed
    fixture = qualification_run_fixture
    expected = [ "effect-#{"f" * 64}" ]
    fixture.dig(
      :payload, "scenarios", "cases", 0
    )["expected_legacy_effect_keys"] = expected
    fixture.dig(
      :payload, "expectations"
    )["expected_legacy_effect_keys"] = expected
    seal_qualification_payload!(fixture.fetch(:payload))
    fixture[:descriptor] = canonical(fixture.fetch(:payload))
    with_qualification_repository(fixture) do |repository, value, run_id|
      publish_lane(repository, value, "deterministic")

      outcome = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "failed", outcome.status
      assert_equal(
        [ "qualification_scenario_observation_effect_mismatch" ],
        outcome.issues
      )
      assert_nil outcome.bindings
    end
  end

  def test_passed_result_rejects_descriptor_label_mismatches
    {
      "repository_sha" => "3" * 40,
      "trigger_digest" => "4" * 64,
      "decision_class" => "clean_negative"
    }.each do |key, replacement|
      with_qualification_repository do |repository, fixture, run_id|
        publish_lane(repository, fixture, "deterministic")
        mutate_scenario_observations(
          repository, fixture, "deterministic"
        ) do |payload|
          payload.dig("observations", 0)[key] = replacement
        end

        outcome = provider(repository).call(
          run_id: run_id, lane: "deterministic"
        )

        assert_equal "failed", outcome.status, key
        assert_equal(
          [ "qualification_scenario_observation_descriptor_mismatch" ],
          outcome.issues,
          key
        )
        assert_nil outcome.bindings, key
      end
    end

    fixture = qualification_run_fixture
    descriptor_decisions = [
      fixture.dig(
        :payload, "scenarios", "cases", 0,
        "decision_expectations", 0
      ),
      fixture.dig(
        :payload, "expectations",
        "decision_expectations", 0
      )
    ]
    descriptor_decisions.each do |decision|
      decision["module"] = "architecture-patrol"
    end
    seal_qualification_payload!(fixture.fetch(:payload))
    fixture[:descriptor] = canonical(fixture.fetch(:payload))
    with_qualification_repository(fixture) do |repository, value, run_id|
      publish_lane(repository, value, "deterministic")

      outcome = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "failed", outcome.status, "module"
      assert_equal(
        [ "qualification_scenario_observation_descriptor_mismatch" ],
        outcome.issues,
        "module"
      )
      assert_nil outcome.bindings, "module"
    end
  end

  def test_passed_result_rejects_an_unobserved_required_fault
    with_qualification_repository do |repository, fixture, run_id|
      publish_lane(repository, fixture, "deterministic")
      mutate_scenario_observations(
        repository, fixture, "deterministic"
      ) do |payload|
        payload.dig(
          "observations", 0
        )["fault_checkpoint"] = nil
      end

      outcome = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "failed", outcome.status
      assert_equal(
        [ "qualification_scenario_fault_coverage_mismatch" ],
        outcome.issues
      )
      assert_nil outcome.bindings
    end
  end

  def test_passed_result_rejects_unobserved_matrix_classes
    fixture = qualification_run_fixture
    fixture.dig(
      :payload, "scenarios", "cases", 0, "matrix"
    ).replace([ "clean_negative" ])
    fixture.dig(
      :payload, "expectations", "required_matrix"
    ).replace([ "clean_negative" ])
    seal_qualification_payload!(fixture.fetch(:payload))
    fixture[:descriptor] = canonical(fixture.fetch(:payload))
    with_qualification_repository(fixture) do |repository, value, run_id|
      publish_lane(repository, value, "deterministic")

      outcome = provider(repository).call(
        run_id: run_id, lane: "deterministic"
      )

      assert_equal "failed", outcome.status
      assert_equal(
        [ "qualification_scenario_matrix_coverage_mismatch" ],
        outcome.issues
      )
      assert_nil outcome.bindings
    end
  end

  def test_passed_result_binds_attempts_to_descriptor_selection
    mutations = {
      "source_commit" => lambda do |row|
        row.dig("decision")["module_generation"] = "b" * 40
        row.fetch("attempts").each do |attempt|
          attempt.dig("subject")["module_generation"] = "b" * 40
        end
        reseal_attempt_lineage!(row)
      end,
      "configuration_digest" => lambda do |row|
        row.dig("decision")["configuration_digest"] = "e" * 64
        row.fetch("attempts").each do |attempt|
          attempt.dig("subject")["configuration_digest"] = "e" * 64
        end
        reseal_attempt_lineage!(row)
      end,
      "ownership_generation" => lambda do |row|
        row.fetch("attempts").each do |attempt|
          attempt["ownership_generation"] =
            "3:#{"a" * 40}"
        end
        reseal_attempt_lineage!(row)
      end,
      "task_input_epoch" => lambda do |row|
        row.fetch("attempts").each do |attempt|
          attempt["task_input_epoch"] = 3
        end
        reseal_attempt_lineage!(row)
      end
    }
    mutations.each do |name, mutation|
      with_qualification_repository do |repository, fixture, run_id|
        publish_lane(repository, fixture, "deterministic")
        mutate_scenario_observations(
          repository, fixture, "deterministic"
        ) do |payload|
          mutation.call(payload.dig("observations", 0))
        end

        outcome = provider(repository).call(
          run_id: run_id, lane: "deterministic"
        )

        assert_equal "failed", outcome.status, name
        assert_equal(
          [ "qualification_scenario_observation_selection_mismatch" ],
          outcome.issues,
          name
        )
        assert_nil outcome.bindings, name
      end
    end
  end

  private

  def provider(repository)
    Hive::Modules::Migration::QualificationRunAuthorityProvider.new(
      repository: repository
    )
  end

  def with_qualification_repository(
    fixture = qualification_run_fixture
  )
    with_tmp_dir do |root|
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      run_id = repository.import_qualification_run(
        descriptor_bytes: fixture.fetch(:descriptor),
        inputs: fixture.fetch(:inputs)
      )
      yield repository, fixture, run_id
    end
  end

  def publish_lane(repository, fixture, lane, result_overrides: {},
                   include_observations: true)
    result = qualification_result(fixture, lane, {})
    artifacts = {
      "stdout.txt" => "qualification passed\n"
    }
    if include_observations
      artifacts["scenario-observations.json"] = canonical(
        qualification_scenario_observations(
          fixture, lane: lane
        )
      )
    end
    repository.publish_qualification_lane(
      run_id: fixture.dig(:payload, "run_id"),
      lane: lane,
      result_bytes: canonical(result),
      bundle_bytes: canonical(
        "receipt" => {},
        "records" => [ fixture.fetch(:observation_record) ]
      ),
      artifacts: artifacts,
      repro_json: canonical(
        "run_id" => fixture.dig(:payload, "run_id"),
        "lane" => lane
      ),
      repro_script: "#!/usr/bin/env bash\nexit 0\n"
    )
    return if result_overrides.empty?

    # The repository refuses malformed or foreign completion bytes before
    # publication. Provider corruption tests therefore model an out-of-band
    # filesystem mutation after a valid immutable capture was published.
    result_ref =
      fixture.dig(:payload, "artifact_refs", lane, "result")
    File.binwrite(
      File.join(
        repository.root,
        "qualification/runs",
        fixture.dig(:payload, "run_id"),
        result_ref
      ),
      canonical(
        qualification_result(
          fixture, lane, result_overrides
        )
      )
    )
  end

  def mutate_scenario_observations(repository, fixture, lane)
    ref = fixture.dig(:payload, "artifact_refs", lane, "artifacts")
    path = File.join(
      repository.root,
      "qualification", "runs",
      fixture.dig(:payload, "run_id"),
      ref,
      "scenario-observations.json"
    )
    payload = JSON.parse(File.binread(path))
    yield payload
    File.binwrite(path, canonical(payload))
  end

  def mutate_qualification_bundle(repository, fixture, lane)
    ref = fixture.dig(:payload, "artifact_refs", lane, "bundle")
    path = File.join(
      repository.root,
      "qualification", "runs",
      fixture.dig(:payload, "run_id"),
      ref
    )
    payload = JSON.parse(File.binread(path))
    yield payload
    File.binwrite(path, canonical(payload))
  end

  def reseal_attempt_lineage!(row)
    base_generation =
      Hive::Modules::HookAttempt.run_id_for(
        row.dig("attempts", 0, "subject")
      )
    row.fetch("attempts").each do |attempt|
      charge = attempt.fetch("retry_charge")
      attempt["task_generation"] = if charge.zero?
        base_generation
      else
        sha(
          [
            "hive-module-hook-retry-v1",
            base_generation,
            charge
          ].join("\0")
        )
      end
      if attempt["receipt"]
        attempt["receipt"]["task_generation"] =
          attempt.fetch("task_generation")
        attempt["receipt"]["ownership_generation"] =
          attempt.fetch("ownership_generation")
        attempt["receipt"]["task_input_epoch"] =
          attempt.fetch("task_input_epoch")
        attempt["receipt_sha256"] =
          sha(canonical(attempt.fetch("receipt")))
      end
      attempt["projection_sha256"] = sha(
        canonical(
          attempt.reject do |key, _value|
            key == "projection_sha256"
          end
        )
      )
    end
  end

  def publish_result(repository, fixture, lane, result_overrides = {})
    repository.publish_qualification_lane_result(
      run_id: fixture.dig(:payload, "run_id"),
      lane: lane,
      result_bytes: canonical(
        qualification_result(fixture, lane, result_overrides)
      )
    )
  end

  def qualification_result(fixture, lane, result_overrides)
    run_id = fixture.dig(:payload, "run_id")
    candidate = fixture.fetch(:payload).fetch("candidate")
    target_sha256 = lane == "installed" ?
      candidate.fetch("installed_tree_sha256") :
      candidate.fetch("source_archive_sha256")
    {
      "schema" => "hive-patrol-qualification-lane-result",
      "schema_version" => 1,
      "run_id" => run_id,
      "lane" => lane,
      "status" => "passed",
      "exit_code" => 0,
      "failure_reason" => nil,
      "target_sha256" => target_sha256,
      "started_at" => "2026-07-30T09:00:00.000000Z",
      "ended_at" => "2026-07-30T09:01:00.000000Z"
    }.merge(result_overrides)
  end

  def qualification_fixture_with_second_decision
    fixture = qualification_run_fixture
    second_record = record_for(
      module_name: "patrol",
      index: 1,
      decision_class: "clean_negative",
      configuration_digests: {
        "patrol" => "d" * 64,
        "architecture-patrol" => "e" * 64
      },
      project: fixture.dig(:payload, "project")
    )
    second_decision = {
      "decision_id" => second_record.fetch("decision_id"),
      "module" => "patrol",
      "decision_class" => "clean_negative",
      "repository" => "github.com/owner/evidence",
      "repository_sha" => "3" * 40,
      "trigger_digest" =>
        second_record.fetch("trigger_digest"),
      "control" => "clean_negative"
    }
    payload = fixture.fetch(:payload)
    first_decision = payload.dig(
      "scenarios", "cases", 0, "decision_expectations", 0
    )
    decisions = [
      first_decision,
      second_decision
    ].sort_by { |row| row.fetch("decision_id") }
    effect_keys =
      Hive::Modules::Migration::PatrolEffectIndex.build(
        records: [
          fixture.fetch(:observation_record),
          second_record
        ]
      ).legacy_keys
    payload.dig(
      "scenarios", "cases", 0
    )["decision_expectations"] = decisions
    payload.dig(
      "scenarios", "cases", 0
    )["expected_legacy_effect_keys"] = effect_keys
    payload.dig(
      "scenarios", "cases", 0
    )["matrix"] = %w[
      clean_negative ordinary_positive_finding
    ]
    payload.dig(
      "expectations"
    )["decision_expectations"] =
      JSON.parse(JSON.generate(decisions))
    payload.dig(
      "expectations"
    )["expected_legacy_effect_keys"] = effect_keys
    payload.dig(
      "expectations"
    )["required_matrix"] = %w[
      clean_negative ordinary_positive_finding
    ]
    seal_qualification_payload!(payload)
    fixture[:descriptor] = canonical(payload)
    fixture
  end

  def nested_scenario_fixture
    fixture = qualification_run_fixture
    payload = Marshal.load(Marshal.dump(fixture.fetch(:payload)))
    inputs = fixture.fetch(:inputs).to_h do |path, entry|
      [
        path,
        { bytes: entry.fetch(:bytes).dup, mode: entry.fetch(:mode) }
      ]
    end
    old_ref = "inputs/scenarios/patrol-case.yml"
    new_ref = "inputs/scenarios/nested/patrol-case.yml"
    scenario = inputs.delete(old_ref)
    inputs[new_ref] = scenario
    manifest = JSON.parse(
      inputs.fetch("inputs/scenarios/manifest.json").fetch(:bytes)
    )
    manifest.fetch("cases").first["path"] = new_ref
    manifest_bytes = canonical(manifest)
    inputs.fetch(
      "inputs/scenarios/manifest.json"
    )[:bytes] = manifest_bytes
    payload.dig("scenarios", "cases").first[
      "scenario_ref"
    ] = new_ref
    payload.dig("scenarios", "manifest_sha256").replace(
      sha(manifest_bytes)
    )
    seal_qualification_payload!(payload)
    {
      payload: payload,
      descriptor: canonical(payload),
      observation_record: fixture.fetch(:observation_record),
      inputs: inputs
    }
  end
end
