require "hive/artifacts/outcome_evidence/store"

module OutcomeEvidenceHelper
  EvidenceTask = Data.define(:folder, :slug, :project_root)

  def write_accepted_outcome_evidence(folder, slug:, project:, project_root:)
    fixture = outcome_evidence_fixture(
      folder, slug: slug, project: project, project_root: project_root
    )
    evidence = fixture.fetch(:evidence)
    hashes = evidence.fetch("representations").map { |item| item.fetch("sha256") }
    attempt = fixture.fetch(:store).append_attempt!(
      generation: fixture.dig(:requirement, "generation"),
      attempt_id: "attempt-01-web", status: "accepted", evidence: [ evidence ],
      producer: fixture.fetch(:actor).call("producer-1"),
      review: {
        "reviewer" => fixture.fetch(:actor).call("reviewer-1"),
        "review_scope_hashes" => hashes,
        "verdicts" => [
          {
            "target_id" => "claim-checkout", "verdict" => "accepted",
            "reason" => "The retained document directly explains the completed checkout outcome."
          }
        ]
      }
    )
    fixture.fetch(:store).publish_current!(
      generation: fixture.dig(:requirement, "generation"),
      attempt_id: attempt.fetch("attempt_id")
    )
    { store: fixture.fetch(:store), evidence: evidence }
  end

  def write_blocked_outcome_evidence(folder, slug:, project:, project_root:)
    fixture = outcome_evidence_fixture(
      folder, slug: slug, project: project, project_root: project_root
    )
    evidence = fixture.fetch(:evidence)
    hashes = evidence.fetch("representations").map { |item| item.fetch("sha256") }
    attempt = fixture.fetch(:store).append_attempt!(
      generation: fixture.dig(:requirement, "generation"),
      attempt_id: "attempt-01-blocked", status: "revise", evidence: [ evidence ],
      producer: fixture.fetch(:actor).call("producer-blocked"),
      diagnostic: "The checkout proof does not show the final confirmation state.",
      review: {
        "reviewer" => fixture.fetch(:actor).call("reviewer-blocked"),
        "review_scope_hashes" => hashes,
        "verdicts" => [
          {
            "target_id" => "claim-checkout", "verdict" => "revise",
            "reason" => "The checkout proof does not show the final confirmation state."
          }
        ]
      }
    )
    pointer = fixture.fetch(:store).publish_blocked!(
      generation: fixture.dig(:requirement, "generation"),
      reason: "recaptures_exhausted", failed_targets: [ "claim-checkout" ],
      reviewer_reasons: [ "The checkout proof does not show the final confirmation state." ],
      attempt_ids: [ attempt.fetch("attempt_id") ]
    )
    { store: fixture.fetch(:store), evidence: evidence, pointer: pointer }
  end

  private

  def outcome_evidence_fixture(folder, slug:, project:, project_root:)
    task = EvidenceTask.new(folder: folder.to_s, slug: slug, project_root: project_root.to_s)
    paths = [ "app/checkout.rb" ]
    head = "b" * 40
    identity = {
      "repository" => nil, "branch" => slug,
      "implementation_base" => "a" * 40, "merge_base" => "a" * 40,
      "implementation_head" => head, "changed_paths" => paths,
      "changed_paths_digest" => Digest::SHA256.hexdigest(paths.join("\0"))
    }
    original = File.join(folder, "outcome-evidence", "work", "checkout.md")
    review = File.join(folder, "outcome-evidence", "work", "checkout.txt")
    FileUtils.mkdir_p(File.dirname(original))
    File.write(original, "# Checkout outcome\n\nThe confirmation state is shown.\n")
    File.write(review, "Checkout outcome\nThe confirmation state is shown.\n")
    relative = ->(path) { Pathname.new(path).relative_path_from(Pathname.new(folder)).to_s }
    representation = lambda do |path, role, media_type|
      {
        "role" => role, "media_type" => media_type,
        "path" => relative.call(path), "sha256" => Digest::SHA256.file(path).hexdigest,
        "bytes" => File.size(path)
      }
    end
    evidence = {
      "kind" => "document", "summary" => "The checkout confirmation outcome is explained clearly.",
      "claims" => [ "claim-checkout" ],
      "source" => { "type" => "task", "name" => "artifact-agent", "source_sha" => head },
      "representations" => [
        representation.call(original, "original", "text/markdown"),
        representation.call(review, "review", "text/plain")
      ]
    }
    actor = lambda do |context|
      {
        "context_id" => context, "agent" => "codex",
        "model" => "gpt-test", "effort" => "medium"
      }
    end
    store = Hive::Artifacts::OutcomeEvidence::Store.new(
      task: task, project: project,
      controller_binding: -> { { "task_generation" => "1", "recovery_epoch" => 0 } }
    )
    requirement = store.open_generation!(
      identity: identity,
      claims: [
        {
          "id" => "claim-checkout",
          "statement" => "A buyer sees the checkout confirmation after completing payment.",
          "proof_kind" => "document", "changed_paths" => paths
        }
      ],
      exclusions: [], inference: actor.call("inference-1"),
      reviewer_capabilities: {
        "proof_kinds" => [ "document" ], "temporal_video" => false
      }
    )
    { store: store, evidence: evidence, actor: actor, requirement: requirement }
  end
end
