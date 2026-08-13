require "test_helper"
require "hive/artifacts/outcome_evidence/store"

class OutcomeEvidenceStoreTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Data.define(:folder, :slug, :project_root)
  NOW = Time.utc(2026, 8, 13, 22, 30, 0)

  def test_round_trips_a_universal_append_only_generation_and_atomic_current_pointer
    with_store do |store, task, controller|
      requirement = store.open_generation!(
        identity: identity
      )
      generation = requirement.fetch("generation")

      assert_equal "outcome_evidence_required", requirement.fetch("requirement")
      assert_equal controller.fetch("recovery_epoch"), requirement.fetch("recovery_epoch")
      assert_equal identity.fetch("changed_paths"),
                   requirement.dig("implementation", "changed_paths")

      attempt = store.append_attempt!(
        generation: generation,
        attempt_id: "attempt-1",
        status: "accepted",
        evidence: [ document_evidence(task) ]
      )
      pointer = store.publish_current!(
        generation: generation, attempt_id: attempt.fetch("attempt_id")
      )

      assert_equal generation, pointer.fetch("generation")
      assert_equal pointer, store.current
      assert store.accepted?
      assert_equal 0o600,
                   File.stat(File.join(task.folder, "outcome-evidence", "current.json")).mode & 0o777
    end
  end

  def test_recovery_epoch_changes_generation_and_attempts_are_write_once
    with_store do |store, _task, controller|
      first = store.open_generation!(identity: identity)
      controller["recovery_epoch"] = 2
      second = store.open_generation!(identity: identity)
      refute_equal first.fetch("generation"), second.fetch("generation")

      attempt = {
        generation: first.fetch("generation"), attempt_id: "attempt-1",
        status: "rejected", evidence: [], diagnostic: "missing verification"
      }
      original = store.append_attempt!(**attempt)
      assert_equal original, store.append_attempt!(**attempt)
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.append_attempt!(**attempt.merge(diagnostic: "contradictory rewrite"))
      end
    end
  end

  def test_malformed_symlinked_oversize_and_legacy_inputs_never_become_accepted
    with_store do |store, task, _controller|
      requirement = store.open_generation!(identity: identity)
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
      second = store.open_generation!(identity: identity).fetch("generation")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        store.append_attempt!(
          generation: second, attempt_id: "traversal", status: "accepted",
          evidence: [ { "kind" => "artifact", "summary" => "escape", "path" => "../escape" } ]
        )
      end
      store.append_attempt!(
        generation: second, attempt_id: "second", status: "accepted",
        evidence: [ document_evidence(task, claims: [ "claim-second" ]) ]
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
    %w[
      hive-outcome-evidence-requirement
      hive-outcome-evidence-attempt
      hive-outcome-evidence-current
    ].each do |name|
      assert_equal 1, Hive::Schemas::SCHEMA_VERSIONS.fetch(name)
      schema = JSON.parse(File.read(Hive::Schemas.schema_path(name)))
      assert_equal false, schema.fetch("additionalProperties"), name
    end
  end

  private

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
    generation = store.open_generation!(identity: identity).fetch("generation")
    store.append_attempt!(
      generation: generation, attempt_id: attempt_id, status: "accepted",
      evidence: [ document_evidence(task, claims: [ "claim-first" ]) ]
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

  def representation(task, path, role:, media_type:)
    {
      "role" => role, "media_type" => media_type,
      "path" => Pathname.new(path).relative_path_from(Pathname.new(task.folder)).to_s,
      "sha256" => Digest::SHA256.file(path).hexdigest,
      "bytes" => File.size(path)
    }
  end
end
