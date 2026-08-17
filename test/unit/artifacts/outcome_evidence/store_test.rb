require "test_helper"
require "hive/artifacts/outcome_evidence/store"

class OutcomeEvidenceStoreTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Data.define(:folder, :slug, :project_root)
  NOW = Time.utc(2026, 8, 13, 22, 30, 0)

  def test_round_trips_a_universal_append_only_generation_and_atomic_current_pointer
    with_store do |store, task, controller|
      requirement = store.open_generation!(**requirement_input)
      generation = requirement.fetch("generation")

      assert_equal "outcome_evidence_required", requirement.fetch("requirement")
      assert_equal controller.fetch("recovery_epoch"), requirement.fetch("recovery_epoch")
      assert_equal identity.fetch("changed_paths"),
                   requirement.dig("implementation", "changed_paths")

      attempt = store.append_attempt!(
        generation: generation,
        attempt_id: "attempt-1",
        status: "accepted",
        evidence: [ document_evidence(task) ],
        producer: actor("producer-1"),
        review: accepted_review(task, actor("reviewer-1"))
      )
      pointer = store.publish_current!(
        generation: generation, attempt_id: attempt.fetch("attempt_id")
      )

      assert_equal generation, pointer.fetch("generation")
      assert_equal "accepted", pointer.fetch("status")
      assert_equal pointer, store.current
      package = store.package
      assert_equal "accepted", package.dig("current", "status")
      assert_equal %w[screenshot video terminal document],
                   package.dig("requirement", "reviewer_capabilities", "proof_kinds")
      assert_equal [ "attempt-1" ], package.fetch("attempts").map { |item| item.fetch("attempt_id") }
      assert store.accepted?
      assert store.accepted_for_identity?(identity)
      refute store.accepted_for_identity?(identity.merge("implementation_head" => "c" * 40))
      assert_equal 0o600,
                   File.stat(File.join(task.folder, "outcome-evidence", "current.json")).mode & 0o777
    end
  end

  def test_metadata_package_avoids_reprocessing_retained_media
    with_store do |store, task, _controller|
      generation = accepted_generation(store, task, attempt_id: "attempt-metadata")
      store.publish_current!(generation: generation, attempt_id: "attempt-metadata")
      full = store.package
      full.fetch("attempts").flat_map { |attempt| attempt.fetch("evidence") }
        .flat_map { |entry| entry.fetch("representations") }
        .each { |representation| File.unlink(File.join(task.folder, representation.fetch("path"))) }
      replacement = lambda do |*, **|
        raise "retained representation admission must not run for metadata queries"
      end

      with_replaced_singleton_method(
        Hive::Artifacts::OutcomeEvidence::Proof, :admit!, replacement
      ) do
        package = store.package_metadata
        assert_equal "accepted", package.dig("current", "status")
        assert_equal [ "attempt-metadata" ],
                     package.fetch("attempts").map { |attempt| attempt.fetch("attempt_id") }
        assert_raises(RuntimeError) { store.package }
      end
    end
  end

  def test_recovery_epoch_changes_generation_and_attempts_are_write_once
    with_store do |store, task, controller|
      first = store.open_generation!(**requirement_input)
      controller["recovery_epoch"] = 2
      second = store.open_generation!(**requirement_input)
      refute_equal first.fetch("generation"), second.fetch("generation")

      attempt = {
        generation: first.fetch("generation"), attempt_id: "attempt-1",
        status: "revise", evidence: [ document_evidence(task) ],
        producer: actor("producer-revise"),
        review: revising_review(task, actor("reviewer-revise")),
        diagnostic: "semantic review requested a targeted revision for claim-a"
      }
      original = store.append_attempt!(**attempt)
      assert_equal original, store.append_attempt!(**attempt)
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.append_attempt!(**attempt.merge(diagnostic: "contradictory rewrite"))
      end
    end
  end

  def test_blocked_attempt_can_durably_record_a_producer_with_no_admitted_files
    with_store do |store, _task, _controller|
      requirement = store.open_generation!(**requirement_input)
      verdicts = %w[claim-a claim-b].map do |id|
        {
          "target_id" => id, "verdict" => "blocked",
          "reason" => "The producer returned no admissible representation for this claim."
        }
      end

      attempt = store.append_attempt!(
        generation: requirement.fetch("generation"), attempt_id: "attempt-empty",
        status: "blocked", evidence: [], producer: actor("producer-empty"),
        review: {
          "reviewer" => actor("reviewer-empty"),
          "review_scope_hashes" => [], "verdicts" => verdicts
        },
        diagnostic: "The producer returned no admissible evidence."
      )

      assert_equal "blocked", attempt.fetch("status")
      assert_empty attempt.fetch("evidence")
      assert_empty attempt.dig("review", "review_scope_hashes")
    end
  end

  def test_identity_shortcuts_require_the_current_controller_task_generation
    with_store do |store, task, controller|
      generation = accepted_generation(store, task, attempt_id: "attempt-current-generation")
      store.publish_current!(generation: generation, attempt_id: "attempt-current-generation")
      assert store.accepted_for_identity?(identity)

      controller["task_generation"] = "controller-generation-2"
      refute store.accepted_for_identity?(identity)
    end

    with_store do |store, task, controller|
      requirement = store.open_generation!(**requirement_input)
      attempt = store.append_attempt!(
        generation: requirement.fetch("generation"), attempt_id: "attempt-revise-generation",
        status: "revise", evidence: [ document_evidence(task) ],
        producer: actor("producer-generation"),
        review: revising_review(task, actor("reviewer-generation")),
        diagnostic: "The retained proof needs a clearer user outcome demonstration."
      )
      store.publish_blocked!(
        generation: requirement.fetch("generation"), reason: "review_blocked",
        failed_targets: [ "claim-a" ],
        reviewer_reasons: [ "The retained proof needs a clearer user outcome demonstration." ],
        attempt_ids: [ attempt.fetch("attempt_id") ]
      )
      assert store.blocked_for_identity?(identity)

      controller["task_generation"] = "controller-generation-2"
      refute store.blocked_for_identity?(identity)
    end
  end

  def test_materializes_one_append_only_exact_diff_for_read_only_roles
    with_tmp_dir do |root|
      repository = File.join(root, "repository")
      folder = File.join(root, "task")
      FileUtils.mkdir_p([ repository, folder ])
      assert system("git", "init", "-q", repository)
      assert system("git", "-C", repository, "config", "user.email", "hive@example.test")
      assert system("git", "-C", repository, "config", "user.name", "Hive Test")
      File.write(File.join(repository, "feature.txt"), "foundation — base\n" + ("a" * 300_000) + "\n")
      assert system("git", "-C", repository, "add", "feature.txt")
      assert system("git", "-C", repository, "commit", "-qm", "base")
      base = IO.popen([ "git", "-C", repository, "rev-parse", "HEAD" ], &:read).strip
      File.write(File.join(repository, "feature.txt"), "foundation — head\n" + ("b" * 300_000) + "\n")
      assert system("git", "-C", repository, "commit", "-qam", "head")
      head = IO.popen([ "git", "-C", repository, "rev-parse", "HEAD" ], &:read).strip
      changed = [ "feature.txt" ]
      frozen_identity = {
        "repository" => nil, "branch" => "main",
        "implementation_base" => base, "merge_base" => base,
        "implementation_head" => head, "changed_paths" => changed,
        "changed_paths_digest" => Digest::SHA256.hexdigest(changed.join("\0"))
      }
      task = FakeTask.new(folder: folder, slug: "demo-task", project_root: root)
      store = Hive::Artifacts::OutcomeEvidence::Store.new(
        task: task, project: "demo",
        controller_binding: -> { { "task_generation" => "1", "recovery_epoch" => 0 } }
      )

      receipt = store.materialize_review_context!(
        identity: frozen_identity, source_root: repository
      )
      path = File.join(folder, receipt.fetch("path"))
      assert_operator File.size(path), :>, Hive::Artifacts::OutcomeEvidence::Store::MAX_DOCUMENT_BYTES
      assert_includes File.read(path), "-#{'a' * 100}"
      assert_includes File.read(path), "+#{'b' * 100}"
      assert_equal Digest::SHA256.file(path).hexdigest, receipt.fetch("sha256")
      assert_equal receipt, store.review_context_for_identity(frozen_identity)
      assert_equal receipt, store.materialize_review_context!(
        identity: frozen_identity, source_root: repository
      )

      File.write(path, "tampered\n")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.materialize_review_context!(identity: frozen_identity, source_root: repository)
      end
    end
  end

  def test_retain_candidate_moves_producer_files_before_semantic_review
    with_store do |store, task, _controller|
      requirement = store.open_generation!(**requirement_input)
      source = document_evidence(task)
      retained = store.retain_candidate!(
        generation: requirement.fetch("generation"), attempt_id: "attempt-custody",
        evidence: [ source ]
      )
      entry = retained.fetch(0)
      hashes = entry.fetch("representations").map { |item| item.fetch("sha256") }
      entry.fetch("representations").each do |representation|
        assert_match(%r{/retained/attempt-custody/}, "/#{representation.fetch('path')}")
      end

      File.write(
        File.join(task.folder, source.dig("representations", 0, "path")),
        "producer rewrote its source after returning\n"
      )
      attempt = store.append_attempt!(
        generation: requirement.fetch("generation"), attempt_id: "attempt-custody",
        status: "accepted", evidence: retained, producer: actor("producer-custody"),
        review: {
          "reviewer" => actor("reviewer-custody"), "review_scope_hashes" => hashes,
          "verdicts" => %w[claim-a claim-b].map do |id|
            {
              "target_id" => id, "verdict" => "accepted",
              "reason" => "The controller-owned document verifies this bounded outcome directly."
            }
          end
        }
      )
      assert_equal entry, attempt.fetch("evidence").fetch(0)
    end
  end

  def test_retained_candidate_with_producer_can_resume_until_attempt_is_recorded
    with_store do |store, task, _controller|
      generation = store.open_generation!(**requirement_input).fetch("generation")
      producer = actor("producer-resume")
      retained = store.retain_candidate!(
        generation: generation, attempt_id: "attempt-resume",
        evidence: [ document_evidence(task) ], producer: producer
      )

      pending = store.pending_candidate(generation: generation)
      assert_equal "attempt-resume", pending.fetch("attempt_id")
      assert_equal producer.merge("model" => "provider-default", "effort" => "default"),
                   pending.fetch("producer")
      assert_equal retained, pending.fetch("evidence")

      hashes = retained.flat_map do |entry|
        entry.fetch("representations").map { |representation| representation.fetch("sha256") }
      end
      store.append_attempt!(
        generation: generation, attempt_id: "attempt-resume", status: "accepted",
        evidence: retained, producer: producer,
        review: {
          "reviewer" => actor("reviewer-resume"),
          "review_scope_hashes" => hashes,
          "verdicts" => %w[claim-a claim-b].map do |id|
            {
              "target_id" => id, "verdict" => "accepted",
              "reason" => "The retained document verifies this bounded outcome directly."
            }
          end
        }
      )

      assert_nil store.pending_candidate(generation: generation)
    end
  end

  def test_open_generation_is_idempotent_and_keeps_the_original_inference
    with_store do |store, _task, _controller|
      first = store.open_generation!(**requirement_input)
      changed = requirement_input.merge(
        inference: actor("inference-after-interruption"),
        claims: [
          {
            "id" => "claim-other", "statement" => "A later inference must not rewrite durable claims.",
            "proof_kind" => "document", "changed_paths" => identity.fetch("changed_paths")
          }
        ]
      )

      assert_equal first, store.open_generation!(**changed)
      assert_equal "inference-1", first.dig("inference", "context_id")
    end
  end

  def test_blocked_pointer_retains_attempt_history_and_a_guarded_recovery_digest
    with_store do |store, task, _controller|
      requirement = store.open_generation!(**requirement_input)
      generation = requirement.fetch("generation")
      attempt = store.append_attempt!(
        generation: generation, attempt_id: "attempt-01-deadbeef", status: "revise",
        evidence: [ document_evidence(task) ], producer: actor("producer-revise"),
        review: revising_review(task, actor("reviewer-revise")),
        diagnostic: "claim-a needs a clearer outcome explanation"
      )

      pointer = store.publish_blocked!(
        generation: generation, reason: "recaptures_exhausted",
        failed_targets: [ "claim-a" ],
        reviewer_reasons: [ "The retained document does not directly demonstrate this bounded outcome." ],
        attempt_ids: [ attempt.fetch("attempt_id") ]
      )

      assert_equal "blocked", pointer.fetch("status")
      assert_equal [ "claim-a" ], pointer.fetch("failed_targets")
      assert_equal 1, pointer.fetch("attempt_count")
      assert_match(/\A[0-9a-f]{64}\z/, pointer.fetch("recovery_digest"))
      refute store.accepted?
      assert store.blocked_for_identity?(identity)
      assert_equal "blocked", store.package.dig("current", "status")

      error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.publish_blocked!(
          generation: generation, reason: "recaptures_exhausted",
          failed_targets: [ "claim-a" ],
          reviewer_reasons: [
            "The review exposed api_key=abcdefghijklmnopqrstuvwxyz0123456789 in output."
          ],
          attempt_ids: [ attempt.fetch("attempt_id") ]
        )
      end
      assert_match(/secret-shaped/, error.message)
      refute_includes error.message, "abcdefghijklmnopqrstuvwxyz"
    end
  end

  def test_exclusion_only_rejection_is_retained_as_a_failed_review_target
    with_store do |store, task, _controller|
      input = requirement_input.merge(
        exclusions: [
          {
            "id" => "exclusion-support",
            "statement" => "The test helper is supporting work without a separate user surface.",
            "reason" => "It only constructs the fixture used by the claimed behavior.",
            "changed_paths" => [ "test/feature_test.rb" ]
          }
        ]
      )
      requirement = store.open_generation!(**input)
      review = accepted_review(task, actor("reviewer-exclusion"))
      review.fetch("verdicts") << {
        "target_id" => "exclusion-support", "verdict" => "blocked",
        "reason" => "The path changes observable behavior and cannot be excluded as supporting work."
      }
      attempt = store.append_attempt!(
        generation: requirement.fetch("generation"), attempt_id: "attempt-exclusion",
        status: "blocked", evidence: [ document_evidence(task) ],
        producer: actor("producer-exclusion"), review: review,
        diagnostic: "The proposed exclusion changes observable behavior."
      )
      pointer = store.publish_blocked!(
        generation: requirement.fetch("generation"), reason: "review_blocked",
        failed_targets: [ "exclusion-support" ],
        reviewer_reasons: [ "The path changes observable behavior and cannot be excluded as supporting work." ],
        attempt_ids: [ attempt.fetch("attempt_id") ]
      )

      assert_equal [ "exclusion-support" ], pointer.fetch("failed_targets")
      assert store.blocked_for_identity?(identity)
      assert_equal pointer, store.package.fetch("current")
    end
  end

  def test_malformed_symlinked_oversize_and_legacy_inputs_never_become_accepted
    with_store do |store, task, _controller|
      requirement = store.open_generation!(**requirement_input)
      generation = requirement.fetch("generation")

      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.append_attempt!(
          generation: generation, attempt_id: "legacy",
          status: "accepted",
          evidence: [ { "kind" => "legacy_capture", "summary" => "old manifest" } ]
        )
      end
      FileUtils.mkdir_p(File.join(task.folder, "media"))
      legacy = {
        "schema" => "hive-artifact-capture", "schema_version" => 2,
        "status" => "captured", "task" => "demo-task", "source_sha" => "b" * 40,
        "recorder" => {
          "kind" => "project_provider", "name" => "legacy-provider",
          "command" => [ "bin/capture" ]
        },
        "environment_keys" => [ "PATH" ],
        "started_at" => "2026-08-13T22:00:00Z",
        "finished_at" => "2026-08-13T22:00:01Z",
        "artifacts" => [
          { "file" => "proof.png", "bytes" => 1, "sha256" => "d" * 64 }
        ],
        "cleanup" => {
          "port" => "released", "processes" => "clean", "runtime" => "cleaned"
        },
        "diagnostic" => nil,
        "evidence" => { "type" => "project_provider", "details" => {} }
      }
      File.write(
        File.join(task.folder, "media", "capture-manifest.json"), JSON.generate(legacy)
      )
      assert_equal legacy, store.legacy_capture
      refute store.accepted?, "a readable legacy capture is not accepted outcome evidence"

      current_path = File.join(task.folder, "outcome-evidence", "current.json")
      File.write(current_path, %({"schema":"hive-outcome-evidence-current","schema":"duplicate"}\n))
      refute store.accepted?

      File.binwrite(current_path, "x" * (Hive::Artifacts::OutcomeEvidence::Store::MAX_DOCUMENT_BYTES + 1))
      refute store.accepted?

      FileUtils.rm_f(current_path)
      target = File.join(task.folder, "outside.json")
      File.write(target, "{}\n")
      File.symlink(target, current_path)
      refute store.accepted?
    end
  end

  def test_path_traversal_and_interrupted_pointer_publication_fail_closed
    with_store do |store, task, controller|
      first = accepted_generation(store, task, attempt_id: "first")
      first_pointer = store.publish_current!(generation: first, attempt_id: "first")

      controller["recovery_epoch"] = 2
      second = store.open_generation!(**requirement_input).fetch("generation")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.append_attempt!(
          generation: second, attempt_id: "traversal", status: "accepted",
          evidence: [ { "kind" => "artifact", "summary" => "escape", "path" => "../escape" } ]
        )
      end
      store.append_attempt!(
        generation: second, attempt_id: "second", status: "accepted",
        evidence: [ document_evidence(task, claims: [ "claim-a", "claim-b" ]) ],
        producer: actor("producer-2"), review: accepted_review(task, actor("reviewer-2"))
      )

      current_path = File.join(task.folder, "outcome-evidence", "current.json")
      original_write = Hive::AtomicFile.method(:write)
      replacement = lambda do |path, *args, **kwargs|
        raise Errno::EIO, "interrupted" if path == current_path

        original_write.call(path, *args, **kwargs)
      end
      with_replaced_singleton_method(Hive::AtomicFile, :write, replacement) do
        assert_raises(Errno::EIO) do
          store.publish_current!(generation: second, attempt_id: "second")
        end
      end

      assert_equal first_pointer, store.current
      refute Dir.children(File.dirname(current_path)).any? { |name| name.include?(".current.json.tmp") }
    end
  end

  def test_registered_schemas_are_strict
    schemas = %w[
      hive-outcome-evidence-requirement
      hive-outcome-evidence-candidate
      hive-outcome-evidence-attempt
      hive-outcome-evidence-current
    ].to_h do |name|
      assert_equal 1, Hive::Schemas::SCHEMA_VERSIONS.fetch(name)
      schema = JSON.parse(File.read(Hive::Schemas.schema_path(name)))
      assert_equal false, schema.fetch("additionalProperties"), name
      [ name, schema ]
    end

    requirement = schemas.fetch("hive-outcome-evidence-requirement")
    assert_equal 5, requirement.dig("properties", "claims", "maxItems")
    assert_equal 16, requirement.dig("properties", "exclusions", "maxItems")
    assert_equal 21,
                 requirement.dig(
                   "properties", "traceability", "additionalProperties", "maxItems"
                 )
    attempt = schemas.fetch("hive-outcome-evidence-attempt")
    assert_equal 5,
                 attempt.dig("$defs", "Evidence", "properties", "claims", "maxItems")
    current = schemas.fetch("hive-outcome-evidence-current")
    assert_equal 21, current.dig("properties", "failed_targets", "maxItems")
    assert_equal 21, current.dig("properties", "reviewer_reasons", "maxItems")
  end

  def test_generation_and_attempt_admission_rejects_malformed_controller_and_review_state
    with_store do |store, task, controller|
      controller["recovery_epoch"] = "not-an-integer"
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.open_generation!(**requirement_input)
      end
      controller["recovery_epoch"] = 1
      requirement = store.open_generation!(**requirement_input)
      generation = requirement.fetch("generation")

      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.append_attempt!(
          generation: generation, attempt_id: "empty", status: "accepted", evidence: []
        )
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.append_attempt!(
          generation: generation, attempt_id: "status-mismatch", status: "revise",
          evidence: [ document_evidence(task) ], producer: actor("producer-status"),
          review: accepted_review(task, actor("reviewer-status")), diagnostic: "review disagrees"
        )
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.append_attempt!(
          generation: generation, attempt_id: "missing-diagnostic", status: "revise",
          evidence: [ document_evidence(task) ], producer: actor("producer-diagnostic"),
          review: revising_review(task, actor("reviewer-diagnostic"))
        )
      end

      path = File.join(
        task.folder, "outcome-evidence", "generations", generation, "requirement.json"
      )
      tampered = JSON.parse(File.read(path))
      tampered["generation"] = "c" * 64
      File.write(path, JSON.generate(tampered) << "\n")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.append_attempt!(
          generation: generation, attempt_id: "contradictory", status: "accepted",
          evidence: [ document_evidence(task) ]
        )
      end
    end
  end

  def test_candidate_custody_is_single_use_and_removes_partial_attempt_roots
    with_store do |store, task, _controller|
      generation = store.open_generation!(**requirement_input).fetch("generation")
      evidence = [ document_evidence(task) ]
      store.retain_candidate!(
        generation: generation, attempt_id: "single-use", evidence: evidence
      )
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.retain_candidate!(
          generation: generation, attempt_id: "single-use", evidence: evidence
        )
      end

      replacement = ->(*) { raise Hive::Artifacts::OutcomeEvidence::StoreError, "copy failed" }
      with_replaced_singleton_method(
        Hive::Artifacts::OutcomeEvidence::Proof, :materialize, replacement
      ) do
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          store.retain_candidate!(
            generation: generation, attempt_id: "partial", evidence: evidence
          )
        end
      end
      refute File.exist?(
        File.join(
          task.folder, "outcome-evidence", "generations", generation,
          "retained", "partial"
        )
      )
    end
  end

  def test_publication_and_blocker_history_reject_contradictory_attempts
    with_store do |store, task, _controller|
      generation = store.open_generation!(**requirement_input).fetch("generation")
      accepted = store.append_attempt!(
        generation: generation, attempt_id: "attempt-1", status: "accepted",
        evidence: [ document_evidence(task) ], producer: actor("producer-accepted"),
        review: accepted_review(task, actor("reviewer-accepted"))
      )
      revised = store.append_attempt!(
        generation: generation, attempt_id: "attempt-2", status: "revise",
        evidence: [ document_evidence(task) ], producer: actor("producer-revised"),
        review: revising_review(task, actor("reviewer-revised")),
        diagnostic: "The reviewer requested another bounded representation."
      )

      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.publish_current!(
          generation: generation, attempt_id: accepted.fetch("attempt_id")
        )
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.publish_blocked!(
          generation: generation, reason: "unknown", failed_targets: [],
          reviewer_reasons: [], attempt_ids: []
        )
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.publish_blocked!(
          generation: generation, reason: "capability_blocked", failed_targets: [],
          reviewer_reasons: [], attempt_ids: [ revised.fetch("attempt_id") ] * 2
        )
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.publish_blocked!(
          generation: generation, reason: "review_blocked",
          failed_targets: [ "claim-a" ], reviewer_reasons: [ "Accepted is contradictory." ],
          attempt_ids: [ accepted.fetch("attempt_id") ]
        )
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.publish_blocked!(
          generation: generation, reason: "recaptures_exhausted",
          failed_targets: [ "claim-a" ], reviewer_reasons: [], attempt_ids: []
        )
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.publish_blocked!(
          generation: generation, reason: "capability_blocked",
          failed_targets: [], reviewer_reasons: [ "" ], attempt_ids: []
        )
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.publish_blocked!(
          generation: generation, reason: "review_blocked", failed_targets: [],
          reviewer_reasons: [ "The reviewer blocked the incomplete outcome package." ],
          attempt_ids: [ revised.fetch("attempt_id") ]
        )
      end
    end
  end

  def test_read_helpers_fail_closed_for_missing_invalid_and_stale_state
    with_store do |store, task, controller|
      assert_nil store.current
      assert_empty store.attempts(generation: "a" * 64)

      generation = store.open_generation!(**requirement_input).fetch("generation")
      attempts_dir = File.join(
        task.folder, "outcome-evidence", "generations", generation, "attempts"
      )
      File.write(File.join(attempts_dir, "unexpected"), "junk")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.attempts(generation: generation)
      end

      controller["recovery_epoch"] = "invalid"
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.requirement_for_identity(identity)
      end
    end
  end

  def test_package_revalidates_pointer_history_status_and_recovery_bindings
    with_store do |store, task, _controller|
      generation = accepted_generation(store, task, attempt_id: "accepted")
      store.publish_current!(generation: generation, attempt_id: "accepted")
      current_path = File.join(task.folder, "outcome-evidence", "current.json")
      original = JSON.parse(File.read(current_path))

      pointer = Marshal.load(Marshal.dump(original))
      pointer["requirement_sha256"] = "0" * 64
      File.write(current_path, JSON.generate(pointer) << "\n")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { store.package }

      pointer = Marshal.load(Marshal.dump(original))
      pointer["attempts"] = []
      pointer["attempt_count"] = 0
      File.write(current_path, JSON.generate(pointer) << "\n")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { store.package }

      pointer = Marshal.load(Marshal.dump(original))
      pointer["attempt_sha256"] = "0" * 64
      File.write(current_path, JSON.generate(pointer) << "\n")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { store.package }
    end

    with_store do |store, task, _controller|
      requirement = store.open_generation!(**requirement_input)
      pointer = store.publish_blocked!(
        generation: requirement.fetch("generation"), reason: "capability_blocked",
        failed_targets: [], reviewer_reasons: [], attempt_ids: []
      )
      current_path = File.join(task.folder, "outcome-evidence", "current.json")
      pointer = plain_copy(pointer)
      pointer["recovery_digest"] = "0" * 64
      File.write(current_path, JSON.generate(pointer) << "\n")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { store.package }
    end

    with_store do |store, _task, _controller|
      pointer = {
        "generation" => "a" * 64, "status" => "future",
        "attempts" => [], "attempt_count" => 0,
        "requirement_sha256" => "b" * 64
      }
      requirement = {
        "task" => "demo-task", "project" => "demo", "generation" => "a" * 64
      }
      store.define_singleton_method(:read_current!) { pointer }
      store.define_singleton_method(:requirement) { |generation:| requirement }
      store.define_singleton_method(:valid_pointer_digests?) { |_value| true }
      store.define_singleton_method(:attempts) { |generation:| [] }
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { store.package }
    end
  end

  def test_capability_identity_directory_and_durable_owner_validation_is_closed
    with_store do |store, _task, _controller|
      [
        { "proof_kinds" => %w[document], "temporal_video" => true, "extra" => true },
        { "proof_kinds" => %w[unknown], "temporal_video" => true },
        { "proof_kinds" => %w[document], "temporal_video" => "yes" },
        nil,
        1
      ].each do |capabilities|
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          store.send(:canonical_reviewer_capabilities, capabilities)
        end
      end

      invalid_identities = [
        identity.merge("changed_paths" => identity.fetch("changed_paths").reverse),
        identity.merge("changed_paths_digest" => "0" * 64),
        identity.merge("merge_base" => "c" * 40),
        identity.merge(
          "changed_paths" => [ "../escape" ],
          "changed_paths_digest" => Digest::SHA256.hexdigest("../escape")
        )
      ]
      invalid_identities.each do |candidate|
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          store.send(:canonical_identity, candidate)
        end
      end
    end

    with_tmp_dir do |root|
      task = FakeTask.new(folder: root, slug: "demo-task", project_root: root)
      store = Hive::Artifacts::OutcomeEvidence::Store.new(task: task, project: "demo")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.send(:controller_binding)
      end

      attempt_store = Object.new
      attempt_store.define_singleton_method(:fetch) { |_attempt_id| nil }
      owned = Hive::Artifacts::OutcomeEvidence::Store.new(
        task: task, project: "demo", attempt_store: attempt_store
      )
      with_attempt_context(
        attempt_id: "attempt-1", task_generation: 7,
        ownership_generation: "owner-1"
      ) do
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          owned.send(:controller_binding)
        end
      end

      values = {
        "project" => "demo", "task_slug" => "demo-task",
        "intended_stage" => "7-artifacts"
      }
      record = Object.new
      record.define_singleton_method(:[]) { |key| values[key] }
      record.define_singleton_method(:ownership_generation) { "owner-1" }
      record.define_singleton_method(:task_input_epoch) { 7 }
      attempt_store.define_singleton_method(:fetch) { |_attempt_id| record }
      with_attempt_context(
        attempt_id: "attempt-1", task_generation: 7,
        ownership_generation: "owner-1"
      ) do
        assert_equal "7", owned.send(:controller_binding).fetch("task_generation")
      end
    end
  end

  def test_existing_requirement_rejects_a_schema_valid_controller_identity_rewrite
    with_store do |store, task, _controller|
      requirement = store.open_generation!(**requirement_input)
      path = File.join(
        task.folder, "outcome-evidence", "generations",
        requirement.fetch("generation"), "requirement.json"
      )
      rewritten = JSON.parse(File.read(path))
      rewritten["project"] = "other-project"
      File.write(path, JSON.generate(rewritten) << "\n")

      error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.open_generation!(**requirement_input)
      end
      assert_match(/contradicts controller identity/, error.message)
    end
  end

  def test_private_directory_append_only_and_secure_digest_edges_fail_closed
    with_store do |store, task, _controller|
      directory = File.join(task.folder, "private")
      original_lstat = File.method(:lstat)
      fake_stat = Object.new
      fake_stat.define_singleton_method(:directory?) { false }
      fake_stat.define_singleton_method(:symlink?) { false }
      replacement = ->(path) { path == directory ? fake_stat : original_lstat.call(path) }
      with_replaced_singleton_method(File, :lstat, replacement) do
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          store.send(:ensure_private_directory!, directory, "private evidence")
        end
      end

      with_replaced_singleton_method(File, :lstat, ->(_path) { raise Errno::ELOOP }) do
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          store.send(:ensure_private_directory!, directory, "private evidence")
        end
      end

      requirement = store.open_generation!(**requirement_input)
      path = File.join(
        task.folder, "outcome-evidence", "generations",
        requirement.fetch("generation"), "requirement.json"
      )
      original_open = File.method(:open)
      replacement = lambda do |candidate, *args, **kwargs, &block|
        raise Errno::ELOOP if candidate == path && args.first.to_i & File::WRONLY != 0
        original_open.call(candidate, *args, **kwargs, &block)
      end
      with_replaced_singleton_method(File, :open, replacement) do
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          store.send(
            :write_once, path, requirement,
            schema: "hive-outcome-evidence-requirement", label: "requirement"
          )
        end
      end
      assert_nil store.send(:secure_file_digest, File.join(task.folder, "missing.json"))
    end
  end

  def test_publication_and_retained_documents_are_recanonicalized
    with_store do |store, task, _controller|
      generation = accepted_generation(store, task, attempt_id: "accepted")
      requirement = store.requirement(generation: generation)
      attempt = store.attempts(generation: generation).first

      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.send(
          :validate_publication!, requirement.merge("task" => "other"),
          attempt, generation, "accepted"
        )
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.send(
          :validate_publication!, requirement,
          attempt.merge("status" => "revise"), generation, "accepted"
        )
      end
      legacy = plain_copy(attempt)
      legacy["evidence"] = [ { "kind" => "legacy_capture" } ]
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.send(:validate_publication!, requirement, legacy, generation, "accepted")
      end

      noncanonical_evidence = plain_copy(attempt)
      noncanonical_evidence.dig("evidence", 0, "claims").reverse!
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.send(:validate_retained_evidence!, requirement, noncanonical_evidence)
      end

      noncanonical_producer = plain_copy(attempt)
      noncanonical_producer.fetch("producer").delete("model")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.send(:validate_retained_evidence!, requirement, noncanonical_producer)
      end

      noncanonical_review = plain_copy(attempt)
      noncanonical_review.dig("review", "review_scope_hashes").reverse!
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.send(:validate_retained_evidence!, requirement, noncanonical_review)
      end

      noncanonical_metadata = plain_copy(attempt)
      noncanonical_metadata.dig("evidence", 0, "claims").reverse!
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.send(:validate_retained_metadata!, requirement, noncanonical_metadata)
      end

      noncanonical_review_metadata = plain_copy(attempt)
      noncanonical_review_metadata.dig("review", "review_scope_hashes").reverse!
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.send(:validate_retained_metadata!, requirement, noncanonical_review_metadata)
      end
    end
  end

  def test_exact_diff_materialization_and_read_context_are_fail_closed
    with_store do |store, _task, _controller|
      requirement = store.open_generation!(**requirement_input)
      generation = requirement.fetch("generation")
      failed = Hive::AgentGitGate::ReadResult.new(
        operation: :diff, stdout: "", stderr: "failed", exitstatus: 1, overflow: false
      )
      with_replaced_singleton_method(Hive::AgentGitGate, :read, ->(*) { failed }) do
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          store.materialize_review_context!(identity: identity, source_root: "/source")
        end
      end

      with_replaced_singleton_method(
        Hive::AgentGitGate, :read, ->(*) { raise Hive::AgentGitGate::Error, "gate" }
      ) do
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          store.materialize_review_context!(identity: identity, source_root: "/source")
        end
      end

      assert_nil store.review_context_for_identity(identity)
      diff = File.join(
        store.send(:generation_root, generation), "implementation.diff"
      )
      Dir.mkdir(diff)
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.review_context_for_identity(identity)
      end
    end
  end

  def test_exact_diff_write_is_bounded_append_only_and_rejects_symlinks
    with_store do |store, _task, _controller|
      generation = store.open_generation!(**requirement_input).fetch("generation")
      root = store.send(:generation_root, generation)
      oversized = "x" * (Hive::Artifacts::OutcomeEvidence::Store::MAX_DIFF_BYTES + 1)
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.send(:write_once_bytes, File.join(root, "oversized.diff"), oversized,
                   generation: generation)
      end

      target = File.join(root, "target")
      File.write(target, "target")
      link = File.join(root, "linked.diff")
      File.symlink(target, link)
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.send(:write_once_bytes, link, "diff", generation: generation)
      end
    end
  end

  private

  def plain_copy(value)
    JSON.parse(JSON.generate(value), object_class: Hash)
  end

  def with_store
    with_tmp_dir do |root|
      folder = File.join(root, "task")
      FileUtils.mkdir_p(folder)
      task = FakeTask.new(folder: folder, slug: "demo-task", project_root: root)
      controller = {
        "task_generation" => "controller-generation-1",
        "recovery_epoch" => 1
      }
      store = Hive::Artifacts::OutcomeEvidence::Store.new(
        task: task, project: "demo", clock: -> { NOW },
        controller_binding: -> { controller }
      )
      yield store, task, controller
    end
  end

  def identity
    paths = [ "lib/feature.rb", "test/feature_test.rb" ]
    {
      "repository" => "github.com/acme/widgets",
      "branch" => "demo-task",
      "implementation_base" => "a" * 40,
      "merge_base" => "a" * 40,
      "implementation_head" => "b" * 40,
      "changed_paths" => paths,
      "changed_paths_digest" => Digest::SHA256.hexdigest(paths.join("\0"))
    }
  end

  def accepted_generation(store, task, attempt_id:)
    generation = store.open_generation!(**requirement_input).fetch("generation")
    store.append_attempt!(
      generation: generation, attempt_id: attempt_id, status: "accepted",
      evidence: [ document_evidence(task) ], producer: actor("producer-accepted"),
      review: accepted_review(task, actor("reviewer-accepted"))
    )
    generation
  end

  def document_evidence(task, claims: %w[claim-a claim-b])
    root = File.join(task.folder, "evidence")
    FileUtils.mkdir_p(root)
    original = File.join(root, "report.md")
    review = File.join(root, "report.txt")
    File.write(original, "# Verification\n\nAll checks passed.\n")
    File.write(review, "Verification\n\nAll checks passed.\n")
    {
      "kind" => "document", "summary" => "Focused contract passed",
      "claims" => claims,
      "source" => {
        "type" => "task", "name" => "artifact-agent",
        "source_sha" => identity.fetch("implementation_head")
      },
      "representations" => [
        representation(task, original, role: "original", media_type: "text/markdown"),
        representation(task, review, role: "review", media_type: "text/plain")
      ]
    }
  end

  def requirement_input
    {
      identity: identity,
      claims: [
        {
          "id" => "claim-a", "statement" => "Users receive the first verified feature outcome.",
          "proof_kind" => "document", "changed_paths" => [ "lib/feature.rb" ]
        },
        {
          "id" => "claim-b", "statement" => "The regression path verifies the second feature outcome.",
          "proof_kind" => "document", "changed_paths" => [ "test/feature_test.rb" ]
        }
      ],
      exclusions: [],
      inference: actor("inference-1")
    }
  end

  def actor(context_id)
    { "context_id" => context_id, "agent" => "claude" }
  end

  def accepted_review(task, reviewer)
    hashes = document_evidence(task).fetch("representations").map { |item| item.fetch("sha256") }
    {
      "reviewer" => reviewer,
      "review_scope_hashes" => hashes,
      "verdicts" => %w[claim-a claim-b].map do |id|
        {
          "target_id" => id, "verdict" => "accepted",
          "reason" => "The retained document directly verifies this bounded outcome claim."
        }
      end
    }
  end

  def revising_review(task, reviewer)
    accepted_review(task, reviewer).tap do |review|
      review.fetch("verdicts").first["verdict"] = "revise"
      review.fetch("verdicts").first["reason"] =
        "The retained document does not directly demonstrate this bounded outcome."
    end
  end

  def representation(task, path, role:, media_type:)
    {
      "role" => role, "media_type" => media_type,
      "path" => Pathname.new(path).relative_path_from(Pathname.new(task.folder)).to_s,
      "sha256" => Digest::SHA256.file(path).hexdigest,
      "bytes" => File.size(path)
    }
  end
end
