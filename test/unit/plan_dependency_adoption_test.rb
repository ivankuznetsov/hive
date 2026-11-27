require "test_helper"
require "hive/plan_dependency_adoption"
require "hive/task_closure"
require "hive/task_meta"

class PlanDependencyAdoptionTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(:folder, :slug, :id, :project_name, :project_root, keyword_init: true)

  def setup_project(root, name: "app", repository_identity: "github.com/acme/#{name}")
    project_root = File.join(root, name)
    FileUtils.mkdir_p(File.join(project_root, ".hive-state", "stages", "3-plan"))
    { "name" => name, "path" => project_root, "repository_identity" => repository_identity }
  end

  def create_task(project_entry, stage:, slug:, id:, depends_on: nil, plan: nil,
                  idempotency_key: nil, input_fingerprint: nil)
    root = project_entry.fetch("path")
    folder = File.join(root, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(
      folder,
      id: id, slug: slug, display_name: slug,
      depends_on: depends_on,
      idempotency_key: idempotency_key,
      input_fingerprint: idempotency_key ? (input_fingerprint || "fp-#{id}") : nil
    )
    File.write(File.join(folder, "plan.md"), plan) if plan
    FakeTask.new(
      folder: folder, slug: slug, id: id,
      project_name: project_entry.fetch("name"), project_root: root
    )
  end

  def with_identities(map)
    with_replaced_singleton_method(Hive::RepositoryIdentity, :current, ->(path) { map[File.expand_path(path)] }) do
      yield
    end
  end

  def test_no_assertion_and_matching_scalar_singleton_and_multi_lists_are_valid
    with_tmp_dir do |root|
      app = setup_project(root)
      create_task(app, stage: "3-plan", slug: "first-task", id: 1)
      create_task(app, stage: "9-done", slug: "second-task", id: 2)
      identities = { File.expand_path(app["path"]) => app["repository_identity"] }

      with_identities(identities) do
        no_assertion = create_task(app, stage: "3-plan", slug: "no-assert", id: 10,
                                        depends_on: "first-task", plan: "# Plain plan\n")
        res = Hive::PlanDependencyAdoption.validate(no_assertion, registry_entries: [ app ])
        assert res.ok?
        refute res.adoptable?
        assert_equal "first-task", res.prospective_depends_on

        matching_scalar = create_task(app, stage: "3-plan", slug: "match-scalar", id: 11,
                                           depends_on: "first-task",
                                           plan: "---\ndepends_on: first-task\n---\n# Plan\n")
        res = Hive::PlanDependencyAdoption.validate(matching_scalar, registry_entries: [ app ])
        assert res.ok?
        refute res.adoptable?

        singleton = create_task(app, stage: "3-plan", slug: "match-singleton", id: 12,
                                     depends_on: [ "first-task" ],
                                     plan: "---\ndepends_on:\n  - first-task\n---\n# Plan\n")
        res = Hive::PlanDependencyAdoption.validate(singleton, registry_entries: [ app ])
        assert res.ok?
        refute res.adoptable?
        assert_equal [ "first-task" ], res.prospective_depends_on

        multi = create_task(app, stage: "3-plan", slug: "match-multi", id: 13,
                                 depends_on: %w[first-task second-task],
                                 plan: "---\ndepends_on:\n  - first-task\n  - second-task\n  - first-task\n---\n# Plan\n")
        res = Hive::PlanDependencyAdoption.validate(multi, registry_entries: [ app ])
        assert res.ok?
        refute res.adoptable?
        assert_equal %w[first-task second-task], res.plan_declaration
      end
    end
  end

  def test_adoptable_list_scalar_to_list_growth_list_growth_and_deduplication
    with_tmp_dir do |root|
      app = setup_project(root)
      create_task(app, stage: "3-plan", slug: "first-task", id: 1)
      create_task(app, stage: "9-done", slug: "archived-task", id: 2)
      create_task(app, stage: "4-execute", slug: "third-task", id: 3)
      identities = { File.expand_path(app["path"]) => app["repository_identity"] }

      with_identities(identities) do
        # Absent metadata + deduplicated singleton list preserves array shape & resolves archived target
        absent = create_task(
          app, stage: "3-plan", slug: "absent-meta", id: 10,
          plan: "---\ndepends_on:\n  - archived-task\n  - archived-task\n---\n# Plan\n"
        )
        Hive::TaskMeta.with_observation(absent.folder) do |obs|
          outcome = Hive::PlanDependencyAdoption.adopt_validated!(
            absent, observation: obs, registry_entries: [ app ]
          )
          assert outcome.adopted?
          assert_equal [ "archived-task" ], Hive::TaskMeta.read(absent.folder)[:depends_on]
        end

        # Scalar metadata grows into strict-superset list (target below gate is valid!)
        grow_scalar = create_task(
          app, stage: "3-plan", slug: "grow-scalar", id: 11,
          depends_on: "first-task",
          plan: "---\ndepends_on:\n  - app:first-task\n  - archived-task\n---\n# Plan\n"
        )
        Hive::TaskMeta.with_observation(grow_scalar.folder) do |obs|
          outcome = Hive::PlanDependencyAdoption.adopt_validated!(
            grow_scalar, observation: obs, registry_entries: [ app ]
          )
          assert outcome.adopted?
          assert_equal %w[app:first-task archived-task], Hive::TaskMeta.read(grow_scalar.folder)[:depends_on]
        end

        # Existing list grows into strict-superset list
        grow_list = create_task(
          app, stage: "3-plan", slug: "grow-list", id: 12,
          depends_on: %w[first-task archived-task],
          plan: "---\ndepends_on:\n  - first-task\n  - archived-task\n  - third-task\n---\n# Plan\n"
        )
        Hive::TaskMeta.with_observation(grow_list.folder) do |obs|
          outcome = Hive::PlanDependencyAdoption.adopt_validated!(
            grow_list, observation: obs, registry_entries: [ app ]
          )
          assert outcome.adopted?
          assert_equal %w[first-task archived-task third-task], Hive::TaskMeta.read(grow_list.folder)[:depends_on]
        end
      end
    end
  end

  def test_refused_removal_replacement_subset_reorder_and_respelling_report_mismatch
    with_tmp_dir do |root|
      app = setup_project(root)
      create_task(app, stage: "9-done", slug: "first-task", id: 1)
      create_task(app, stage: "9-done", slug: "second-task", id: 2)
      create_task(app, stage: "9-done", slug: "third-task", id: 3)
      identities = { File.expand_path(app["path"]) => app["repository_identity"] }

      cases = [
        [ "replacement", "first-task", "---\ndepends_on: second-task\n---\n" ],
        [ "subset", %w[first-task second-task], "---\ndepends_on:\n  - first-task\n---\n" ],
        [ "list-to-scalar", %w[first-task second-task], "---\ndepends_on: first-task\n---\n" ],
        [ "scalar-to-singleton", "first-task", "---\ndepends_on:\n  - first-task\n---\n" ],
        [ "reorder", %w[first-task second-task], "---\ndepends_on:\n  - second-task\n  - first-task\n---\n" ],
        [ "respell", "first-task", "---\ndepends_on: app:first-task\n---\n" ],
        [ "replace-one", %w[first-task second-task], "---\ndepends_on:\n  - first-task\n  - third-task\n---\n" ]
      ]

      with_identities(identities) do
        cases.each_with_index do |(slug, meta_dep, plan_text), idx|
          task = create_task(app, stage: "3-plan", slug: slug, id: 20 + idx,
                             depends_on: meta_dep, plan: plan_text)
          res = Hive::PlanDependencyAdoption.validate(task, registry_entries: [ app ])
          assert res.covered_defect?, "expected covered defect for #{slug}, got #{res.inspect}"
          assert_equal "plan_dependency_mismatch", res.reason_code, slug
          refute res.adoptable?, slug
          assert_equal meta_dep, Hive::TaskMeta.read(task.folder)[:depends_on]
        end
      end
    end
  end

  def test_list_with_one_unknown_target_blocks_adoption_until_corrected
    with_tmp_dir do |root|
      app = setup_project(root)
      create_task(app, stage: "4-execute", slug: "first-task", id: 1)
      create_task(app, stage: "9-done", slug: "second-task", id: 2)
      task = create_task(
        app, stage: "3-plan", slug: "target-task", id: 3,
        depends_on: "first-task",
        plan: "---\ndepends_on:\n  - first-task\n  - ghost-task\n---\n# Plan\n"
      )
      identities = { File.expand_path(app["path"]) => app["repository_identity"] }

      with_identities(identities) do
        Hive::TaskMeta.with_observation(task.folder) do |obs|
          bad = Hive::PlanDependencyAdoption.adopt_validated!(
            task, observation: obs, registry_entries: [ app ]
          )
          assert bad.covered_defect?
          assert_equal "plan_dependency_invalid", bad.validation.reason_code
          assert_equal [ 1 ], bad.validation.issues.map(&:index)
          assert_equal [ "ghost-task" ], bad.validation.issues.map(&:raw_value)
          assert_equal "first-task", Hive::TaskMeta.read(task.folder)[:depends_on]

          File.write(File.join(task.folder, "plan.md"),
                     "---\ndepends_on:\n  - first-task\n  - second-task\n---\n# Plan\n")
          good = Hive::PlanDependencyAdoption.adopt_validated!(
            task, observation: obs, registry_entries: [ app ]
          )
          assert good.adopted?
          assert_equal %w[first-task second-task], Hive::TaskMeta.read(task.folder)[:depends_on]
        end
      end
    end
  end

  def test_task_code_list_reports_every_index_value_and_individual_eligible_hint
    with_tmp_dir do |root|
      app = setup_project(root)
      # C4: both slug prefix AND idempotency key agree -> unique hint
      create_task(app, stage: "4-execute", slug: "c4-auth-261030-aaaa", id: 1,
                       idempotency_key: "app:c4:v1")
      # F2: active prefix match vs archived idempotency match -> ambiguous -> suppressed
      create_task(app, stage: "4-execute", slug: "f2-active-261030-bbbb", id: 2)
      create_task(app, stage: "9-done", slug: "renamed-archived-261030-cccc", id: 3,
                       idempotency_key: "app:F2:v2")
      # F3: archived idempotency match only (unique) -> hint returned
      create_task(app, stage: "9-done", slug: "workspace-pin-261030-dddd", id: 4,
                       idempotency_key: "app:f3:2026-10-30")
      # Malformed key should be ignored
      create_task(app, stage: "4-execute", slug: "noise-task", id: 5,
                       idempotency_key: "app:f3")

      task = create_task(
        app, stage: "3-plan", slug: "consumer-task", id: 10,
        plan: "---\ndepends_on:\n  - C4\n  - F2\n  - F3\n---\n# Plan\n"
      )
      identities = { File.expand_path(app["path"]) => app["repository_identity"] }

      with_identities(identities) do
        res = Hive::PlanDependencyAdoption.validate(task, registry_entries: [ app ])
        assert res.covered_defect?
        assert_equal "plan_dependency_invalid", res.reason_code
        assert_equal "C4, F2, F3", res.offending_ref
        assert_equal [ 0, 1, 2 ], res.issues.map(&:index)
        assert_equal %w[C4 F2 F3], res.issues.map(&:raw_value)
        assert_equal [ "c4-auth-261030-aaaa", nil, "workspace-pin-261030-dddd" ],
                     res.issues.map(&:suggestion)

        # Verify JSON serialization retains every field
        serialized = JSON.parse(JSON.generate(res.to_h))
        assert_equal "covered_defect", serialized["status"]
        assert_equal 3, serialized["issues"].length
        assert_equal "c4-auth-261030-aaaa", serialized["issues"][0]["suggestion"]
        assert_nil serialized["issues"][1]["suggestion"]
        assert_equal "workspace-pin-261030-dddd", serialized["issues"][2]["suggestion"]
      end
    end
  end

  def test_cross_project_environmental_cancelled_superseded_and_cycles_do_not_consume_corrections
    with_tmp_dir do |root|
      app = setup_project(root, name: "app")
      other = setup_project(root, name: "other", repository_identity: "github.com/acme/other")
      create_task(other, stage: "9-done", slug: "remote-ok", id: 1)
      create_task(app, stage: "9-done", slug: "cancelled-task", id: 2)
      create_task(app, stage: "9-done", slug: "superseded-task", id: 3)
      create_task(app, stage: "4-execute", slug: "successor-task", id: 4)
      create_task(app, stage: "4-execute", slug: "cycle-peer", id: 5, depends_on: "cycle-root")

      closure_reader = lambda do |task, **|
        case task.slug
        when "cancelled-task"
          Hive::TaskClosure::ReadResult.new(
            status: "valid", receipt: { "reason" => "cancelled", "evidence" => [] },
            error: nil, quarantine_path: nil
          )
        when "superseded-task"
          Hive::TaskClosure::ReadResult.new(
            status: "valid",
            receipt: {
              "reason" => "superseded", "evidence" => [],
              "successor" => { "project" => "app", "slug" => "successor-task" }
            },
            error: nil, quarantine_path: nil
          )
        else
          Hive::TaskClosure::ReadResult.new(status: "absent", receipt: nil, error: nil, quarantine_path: nil)
        end
      end

      identities = {
        File.expand_path(app["path"]) => app["repository_identity"],
        File.expand_path(other["path"]) => "github.com/acme/wrong"
      }

      with_identities(identities) do
        with_replaced_singleton_method(Hive::TaskClosure, :read, closure_reader) do
          unknown_proj = create_task(app, stage: "3-plan", slug: "t1", id: 10,
                                          plan: "---\ndepends_on: missing:remote-ok\n---\n")
          r1 = Hive::PlanDependencyAdoption.validate(unknown_proj, registry_entries: [ app, other ])
          assert r1.noncovered_error?
          assert_equal "dependency_project_unknown", r1.reason_code

          mismatch_repo = create_task(app, stage: "3-plan", slug: "t2", id: 11,
                                           plan: "---\ndepends_on: other:remote-ok\n---\n")
          r2 = Hive::PlanDependencyAdoption.validate(mismatch_repo, registry_entries: [ app, other ])
          assert r2.noncovered_error?
          assert_equal "dependency_repository_mismatch", r2.reason_code

          cancelled_ref = create_task(app, stage: "3-plan", slug: "t3", id: 12,
                                           plan: "---\ndepends_on: cancelled-task\n---\n")
          r3 = Hive::PlanDependencyAdoption.validate(cancelled_ref, registry_entries: [ app, other ])
          assert r3.noncovered_error?
          assert_equal "dependency_validation_failed", r3.reason_code

          superseded_ref = create_task(app, stage: "3-plan", slug: "t4", id: 13,
                                            plan: "---\ndepends_on: superseded-task\n---\n")
          r4 = Hive::PlanDependencyAdoption.validate(superseded_ref, registry_entries: [ app, other ])
          assert r4.noncovered_error?
          assert_equal "dependency_validation_failed", r4.reason_code

          cycle_ref = create_task(app, stage: "3-plan", slug: "cycle-root", id: 14,
                                       plan: "---\ndepends_on: cycle-peer\n---\n")
          r5 = Hive::PlanDependencyAdoption.validate(cycle_ref, registry_entries: [ app, other ])
          assert r5.noncovered_error?
          assert_equal "dependency_cycle", r5.reason_code
        end
      end
    end
  end

  def test_custody_check_rejects_changed_lookup_observations_without_live_repo_probes
    with_tmp_dir do |root|
      app = setup_project(root, name: "app")
      other = setup_project(root, name: "other", repository_identity: "github.com/acme/other")
      create_task(other, stage: "9-done", slug: "remote-ok", id: 1)
      task = create_task(app, stage: "3-plan", slug: "dependent", id: 2,
                         plan: "---\ndepends_on: other:remote-ok\n---\n# Plan\n")
      probes = 0
      probe_fn = lambda do |path|
        probes += 1
        path == File.expand_path(other["path"]) ? other["repository_identity"] : app["repository_identity"]
      end

      validation = with_replaced_singleton_method(Hive::RepositoryIdentity, :current, probe_fn) do
        Hive::PlanDependencyAdoption.validate(task, registry_entries: [ app, other ])
      end
      assert validation.ok?
      assert validation.adoptable?
      assert_equal 1, probes

      # Under custody: zero live repo probes!
      Hive::TaskMeta.with_observation(task.folder) do |obs|
        with_replaced_singleton_method(Hive::RepositoryIdentity, :current, ->(_) { flunk "no live repo probe under custody" }) do
          assert Hive::PlanDependencyAdoption.fresh_under_custody?(task, observation: obs, validation: validation)

          # Mutating project lookup observations invalidates custody check
          create_task(app, stage: "4-execute", slug: "newly-added-task", id: 99)
          refute Hive::PlanDependencyAdoption.fresh_under_custody?(task, observation: obs, validation: validation)

          stale = Hive::PlanDependencyAdoption.adopt_validated!(
            task, observation: obs, validation: validation
          )
          assert stale.stale?
          assert_nil Hive::TaskMeta.read(task.folder)[:depends_on]
        end
      end
    end
  end

  def test_candidate_bytes_validation_never_mutates_plan_or_metadata
    with_tmp_dir do |root|
      app = setup_project(root)
      create_task(app, stage: "8-finalize", slug: "known-task", id: 1)
      task = create_task(app, stage: "3-plan", slug: "target", id: 2,
                         plan: "# Original canonical plan\n<!-- COMPLETE -->\n")
      identities = { File.expand_path(app["path"]) => app["repository_identity"] }

      with_identities(identities) do
        bad = Hive::PlanDependencyAdoption.validate(
          task,
          plan_bytes: "---\ndepends_on:\n  - known-task\n  - unknown-task\n---\n# Candidate\n",
          registry_entries: [ app ]
        )
        assert bad.covered_defect?
        assert_equal "plan_dependency_invalid", bad.reason_code
        assert_equal "# Original canonical plan\n<!-- COMPLETE -->\n",
                     File.read(File.join(task.folder, "plan.md"))
        assert_nil Hive::TaskMeta.read(task.folder)[:depends_on]
      end
    end
  end
end
