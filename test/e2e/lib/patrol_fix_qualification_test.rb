require_relative "../../test_helper"
require_relative "patrol_qualification"
require "json_schemer"
require "pathname"

class E2EPatrolFixQualificationTest < Minitest::Test
  include Hive::E2E::PatrolQualification

  CORPUS_PATH = File.expand_path(
    "../fixtures/patrol_fix_qualification/corpus.json", __dir__
  )

  def test_frozen_corpus_covers_both_sources_and_all_four_llm_gates
    corpus = DecisionCorpus.load(CORPUS_PATH)

    assert_equal 8, corpus.cases.size
    assert_equal %w[architecture_patrol ordinary_patrol], corpus.cases.map(&:source).uniq.sort
    assert_equal %w[feature_classification inbox_routing independent_review semantic_admission],
                 corpus.cases.map(&:gate).uniq.sort
    assert_equal Digest::SHA256.hexdigest(corpus.bytes), corpus.digest
  end

  def test_corpus_runner_records_exact_provenance_and_flags_unsafe_disagreement
    corpus = DecisionCorpus.load(CORPUS_PATH)
    calls = []
    prompt_log = []
    adapter = production_adapter(corpus, prompt_log: prompt_log)
    gate_runner = lambda do |row, immutable_input:|
      calls << row.id
      adapter.call(row, immutable_input: immutable_input)
    end

    report = DecisionCorpusRunner.new(corpus:, gate_runner:).call(
      generated_at: "2026-08-21T10:00:00.000000Z"
    )

    assert_equal 8, calls.size
    assert_equal corpus.digest, report.fetch("corpus_digest")
    assert report.fetch("cases").all? { |row| row.fetch("status") == "match" }
    assert report.fetch("cases").all? do |row|
      row.values_at("provider", "model", "prompt_version", "model_receipt").none?(&:empty?)
    end
    prompt_log.each do |entry|
      report_row = report.fetch("cases").find { |row| row.fetch("case_id") == entry.fetch("case_id") }
      expected = Digest::SHA256.hexdigest(Hive::E2E::PatrolQualification.canonical(
        "production_input" => { "prompt" => entry.fetch("prompt") },
        "immutable_case_input_digest" => report_row.fetch("input_digest")
      ))
      assert_equal expected, report_row.fetch("production_input_digest")
    end
    replay = DecisionCorpusRunner.new(corpus:, gate_runner:).call(
      generated_at: "2026-08-21T10:00:00.000000Z"
    )
    assert_equal report.fetch("cases").map { |row| row.fetch("production_input_digest") },
                 replay.fetch("cases").map { |row| row.fetch("production_input_digest") }

    unsafe_gate = lambda do |row, immutable_input:|
      result = adapter.call(row, immutable_input: immutable_input)
      decision = row.safety_critical ? row.unsafe_decisions.first : row.baseline_decision
      result.merge("decision" => decision)
    end
    error = assert_raises(Error) do
      DecisionCorpusRunner.new(corpus:, gate_runner: unsafe_gate).call(
        generated_at: "2026-08-21T10:00:00.000000Z"
      )
    end
    assert_match(/unsafe qualification decision/, error.message)
  end

  def test_dogfood_report_round_trips_one_source_to_one_pr_with_replay_proof
    Dir.mktmpdir("patrol-fix-dogfood") do |root|
      path = File.join(root, "report.json")
      document = dogfood_document

      DogfoodReport.write(path, document)
      loaded = DogfoodReport.load(path)
      schema = JSONSchemer.schema(Pathname(
        Hive::Schemas.schema_path("hive-patrol-fix-dogfood-report")
      ))

      assert_equal document, loaded
      assert_empty schema.validate(loaded).to_a
      assert_equal %w[inbox fix validate review publish done],
                   loaded.fetch("stages").map { |row| row.fetch("stage") }
      assert_equal 0, loaded.dig("replay", "duplicate_task_count")
      assert_equal 0, loaded.dig("replay", "duplicate_pr_count")

      invalid = Marshal.load(Marshal.dump(document))
      invalid.fetch("replay")["pr_number"] = 42
      assert_raises(Error) { DogfoodReport.validate!(invalid) }
    end
  end

  def test_live_controller_writes_one_canonical_report_through_its_executable_seam
    Dir.mktmpdir("patrol-fix-live-controller") do |root|
      evidence_path = File.join(root, "qualification.json")
      controller = LiveDecisionCorpusController.new(
        project_root: root, corpus_path: CORPUS_PATH, evidence_path: evidence_path,
        adapter_factory: lambda do |corpus:, artifact_root:|
          production_adapter(corpus, artifact_root: artifact_root)
        end
      )

      report = controller.run!(generated_at: "2026-08-21T10:00:00.000000Z")

      assert_equal report, JSON.parse(File.binread(evidence_path))
      assert_equal 0o600, File.stat(evidence_path).mode & 0o777
      assert_equal 8, report.fetch("cases").size
    end
  end

  private

  def production_adapter(corpus, prompt_log: [], artifact_root: nil)
    semantic = lambda do |input|
      id = input.dig("source", "identity")
      row = corpus.cases.find { |candidate| candidate.id == id }
      assert_semantic_input_is_admissible(input)
      {
        "decision" => row.baseline_decision, "candidate_identity" =>
          (row.baseline_decision == "same_root" ? "repair-existing" : nil),
        "rationale" => "The production semantic contract selected the labeled route.",
        "evidence" => [ "src/example.rb:12" ], "model_receipt" => "receipt:#{id}"
      }
    end
    feature_provider = lambda do |prompt|
      decision = prompt.include?("six-shard") ? "feature" : "skip"
      {
        "decision" => decision, "rationale" => "The merge matches the frozen label.",
        "evidence" => [ "The production merge prompt contains the changed paths." ],
        "model_receipt" => "receipt:feature:#{decision}"
      }
    end
    root = artifact_root || Dir.mktmpdir("patrol-fix-feature-corpus")
    unless artifact_root
      @qualification_roots ||= []
      @qualification_roots << root
    end
    classifier = Hive::RefactorPatrol::MergeClassifier.new(
      root: root, decision_provider: feature_provider
    )
    structured = lambda do |gate:, prompt:, output_path:|
      row = corpus.cases.find { |candidate| prompt.include?(candidate.id) }
      prompt_log << { "case_id" => row.id, "prompt" => prompt, "output_path" => output_path }
      decision = row.baseline_decision
      route = gate == "independent_review" && decision == "approve" ? "publish" : decision
      schema = gate == "inbox_routing" ? "hive-patrol-fix-inbox-report" :
        "hive-patrol-fix-review-report"
      {
        "output" => JSON.generate(
          "schema" => schema, "schema_version" => 1, "route" => route,
          "rationale" => "The production prompt and parser preserve the label.",
          "evidence" => [ "src/example.rb:12" ], "blocker_owner" => "qualification"
        ),
        "provider" => "fake-provider", "model" => "fake-model",
        "model_receipt" => "receipt:#{row.id}"
      }
    end
    ProductionGateAdapter.new(
      semantic_runner: semantic, feature_classifier: classifier,
      structured_transport: structured,
      provenance: ->(_gate, _decision) { { "provider" => "fake-provider", "model" => "fake-model" } },
      artifact_root: root
    )
  end

  def assert_semantic_input_is_admissible(input)
    root = Dir.mktmpdir("patrol-fix-semantic-input")
    @qualification_roots ||= []
    @qualification_roots << root
    store = Hive::PatrolFix::AdmissionStore.new(root: root)
    source = Hive::PatrolFix::SourceSnapshot.new(input.fetch("source"))
    store.reserve!(occurrence_id: source.to_h.fetch("identity"), snapshot: source)
    inventory = {
      "count" => input.fetch("inventory_count"),
      "digest" => input.fetch("inventory_digest"),
      "context_digest" => input.fetch("candidate_context_digest"),
      "truncated" => input.fetch("candidate_context_truncated")
    }
    prepared = store.prepare_decision!(
      source.to_h.fetch("identity"), candidates: input.fetch("candidates"),
      current_head: input.fetch("current_head"), inventory: inventory
    )
    assert_equal input.fetch("candidate_digest"), prepared.fetch("candidate_digest")
  end

  def teardown
    Array(@qualification_roots).each { |root| FileUtils.remove_entry(root) if File.exist?(root) }
  end

  def dogfood_document
    digest = "a" * 64
    {
      "schema" => "hive-patrol-fix-dogfood-report",
      "schema_version" => 1,
      "run_id" => "patrol-fix-dogfood-20260821",
      "generated_at" => "2026-08-21T10:00:00.000000Z",
      "project" => "example",
      "source" => {
        "engine" => "ordinary_patrol", "identity" => "finding-1",
        "occurrence_id" => "occurrence-1", "source_digest" => digest
      },
      "task" => { "slug" => "repair-example", "generation" => 2, "evidence_digest" => digest },
      "stages" => %w[inbox fix validate review publish done].map.with_index do |stage, index|
        {
          "stage" => stage, "status" => "completed", "journal_digest" => digest,
          "observed_at" => format("2026-08-21T10:%02d:00.000000Z", index)
        }
      end,
      "validation" => [ { "command" => "bundle exec ruby test/example_test.rb",
                           "exit_code" => 0, "evidence_digest" => digest } ],
      "review" => { "decision" => "approve", "model_receipt" => "fake:review:1",
                      "evidence_digest" => digest },
      "publication" => {
        "phase" => "pr_created", "pr_number" => 41, "url" => "https://example.test/pull/41",
        "head_revision" => "a" * 40, "base_revision" => "b" * 40, "receipt_digest" => digest
      },
      "replay" => {
        "source_occurrence_id" => "occurrence-1", "task_slug" => "repair-example",
        "pr_number" => 41, "duplicate_task_count" => 0, "duplicate_pr_count" => 0
      }
    }
  end
end
