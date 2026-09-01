require "fileutils"
require "json"
require "yaml"
require "hive/config"
require "hive/patrol_fix/task_manifest"
require "hive/task"
require "hive/task_journal"
require "hive/task_meta"
require "hive/task_projection/reader"

module HiveStatusProjectionScaleFixture
  TASK_COUNT = 251
  LOGICAL_PROOF_COUNT = 54_150
  DEEP_HISTORY_EVENTS = 1_000

  Result = Data.define(
    :project, :attempts, :deep_slug, :invalid_slug, :patrol_slug
  )

  class AttemptStoreFacade
    attr_reader :logical_proof_count, :point_fetches, :proof_directory_enumerations

    def initialize(attempts:, logical_proof_count:)
      @attempts = attempts
      @logical_proof_count = Integer(logical_proof_count)
      @point_fetches = 0
      @proof_directory_enumerations = 0
    end

    def fetch(attempt_id)
      @point_fetches += 1
      @attempts[attempt_id.to_s]
    end

    def fetch_terminal_diagnostic_binding(_attempt_id) = nil

    def scan
      @proof_directory_enumerations += 1
      raise "routine status must not enumerate proof storage"
    end
  end

  class InstrumentedJournalReader < Hive::TaskProjection::Reader
    def initialize(counters:, **options)
      @scale_counters = counters
      @scale_counters[:stores] += 1
      super(**options)
    end

    private

    def journal_bytes(limit: nil)
      bytes = super
      @scale_counters[:journal_reads] += 1
      @scale_counters[:journal_bytes] += bytes.bytesize
      @scale_counters[:journal_bytes_by_task][File.basename(task_folder)] += bytes.bytesize
      bytes
    end
  end

  module_function

  def build(root:)
    project_root = File.join(root, "status-scale-project")
    hive_state = File.join(project_root, ".hive-state")
    FileUtils.mkdir_p(File.join(hive_state, "stages"))
    Hive::Workflows.all_stage_dirs.each do |stage|
      FileUtils.mkdir_p(File.join(hive_state, "stages", stage))
    end
    File.write(File.join(hive_state, "config.yml"), Hive::Config::DEFAULTS.to_yaml)

    attempts = {}
    coding_tasks = Array.new(TASK_COUNT - 1) do |index|
      write_task(
        hive_state: hive_state,
        stage: "4-execute",
        slug: format("scale-task-%03d", index + 1),
        id: index + 1,
        attempts: attempts,
        history_events: index.zero? ? DEEP_HISTORY_EVENTS : 0
      )
    end
    patrol = write_task(
      hive_state: hive_state,
      stage: "2-fix",
      slug: "scale-patrol-fix",
      id: TASK_COUNT,
      workflow: Hive::PatrolFix::WORKFLOW_ID.to_s,
      attempts: attempts
    )
    invalid = coding_tasks.last
    File.write(File.join(invalid.folder, Hive::TaskJournal::JOURNAL_BASENAME), "{\n")

    Result.new(
      project: {
        "name" => File.basename(project_root),
        "path" => project_root,
        "hive_state_path" => hive_state
      },
      attempts: attempts.freeze,
      deep_slug: coding_tasks.first.slug,
      invalid_slug: invalid.slug,
      patrol_slug: patrol.slug
    )
  end

  def counters
    Hash.new(0).merge(
      stores: 0, journal_reads: 0, journal_bytes: 0,
      journal_bytes_by_task: Hash.new(0)
    )
  end

  def write_task(hive_state:, stage:, slug:, id:, attempts:, workflow: "coding",
                 history_events: 0)
    folder = File.join(hive_state, "stages", stage, slug)
    Hive::TaskMeta.write(
      folder,
      id: id,
      slug: slug,
      display_name: slug.tr("-", " ").capitalize,
      workflow: workflow
    )
    if workflow == Hive::PatrolFix::WORKFLOW_ID.to_s
      write_patrol_manifest(folder, slug)
    else
      File.write(File.join(folder, "execution.md"), "# Execute\n<!-- EXECUTE_WAITING -->\n")
    end

    attempt_id = "scale-attempt-#{id}"
    attempts[attempt_id] = attempt_record(
      attempt_id: attempt_id, slug: slug, id: id, stage: stage
    )
    events = [ condition_event(
      event_id: "scale-condition-#{id}", attempt_id: attempt_id,
      slug: slug, id: id, stage: stage, workflow: workflow
    ) ]
    history_events.times do |index|
      events << activity_event(
        event_id: "scale-history-#{id}-#{index}", attempt_id: attempt_id,
        slug: slug, id: id, stage: stage, workflow: workflow, index: index
      )
    end
    events << activity_event(
      event_id: "scale-suffix-#{id}", attempt_id: attempt_id,
      slug: slug, id: id, stage: stage, workflow: workflow,
      index: history_events + 1
    )
    File.write(
      File.join(folder, Hive::TaskJournal::JOURNAL_BASENAME),
      events.map { |event| JSON.generate(event) }.join("\n") + "\n"
    )
    Hive::Task.new(folder)
  end
  private_class_method :write_task

  def attempt_record(attempt_id:, slug:, id:, stage:)
    {
      "attempt_id" => attempt_id,
      "predecessor_attempt_id" => nil,
      "task_slug" => slug,
      "task_id" => id.to_s,
      "intended_stage" => stage,
      "task_input_epoch" => 1,
      "ownership_generation" => "scale-owner-#{id}",
      "accepted_at" => "2026-08-29T10:00:00.000000Z",
      "state" => "running",
      "outcome" => nil,
      "lease_version" => 1
    }
  end
  private_class_method :attempt_record

  def condition_event(event_id:, attempt_id:, slug:, id:, stage:, workflow:)
    Hive::TaskJournal::Envelope.authoritative({
      event_id: event_id,
      event_type: "condition_observed",
      occurred_at: "2026-08-29T10:00:00.000000Z",
      observed_at: "2026-08-29T10:00:00.000000Z",
      task: { "id" => id.to_s, "slug" => slug },
      workflow: workflow,
      stage: stage,
      attempt_id: attempt_id,
      task_generation: 1,
      ownership_generation: "scale-owner-#{id}",
      commit_generation: 0,
      reason: "scale_fixture",
      evidence: [ {
        "type" => "attempt_lease", "attempt_id" => attempt_id,
        "lease_version" => 1, "state" => "running"
      } ],
      provenance: { "source" => "test" },
      payload: { "condition" => "AgentHealthy", "state" => "satisfied" }
    })
  end
  private_class_method :condition_event

  def activity_event(event_id:, attempt_id:, slug:, id:, stage:, workflow:, index:)
    Hive::TaskJournal::Envelope.authoritative({
      event_id: event_id,
      event_type: "activity_recorded",
      occurred_at: "2026-08-29T10:00:00.000000Z",
      observed_at: "2026-08-29T10:00:00.000000Z",
      task: { "id" => id.to_s, "slug" => slug },
      workflow: workflow,
      stage: stage,
      attempt_id: attempt_id,
      task_generation: 1,
      ownership_generation: "scale-owner-#{id}",
      commit_generation: 0,
      reason: "scale_history",
      evidence: [],
      provenance: { "source" => "test" },
      payload: {
        "activity_kind" => "stage_transition",
        "operation_id" => "scale-history-op-#{id}-#{index}",
        "from_stage" => stage,
        "to_stage" => stage
      }
    })
  end
  private_class_method :activity_event

  def write_patrol_manifest(folder, slug)
    digest = "a" * 64
    revision = "b" * 40
    Hive::PatrolFix::TaskManifest.new(task_folder: folder).write!(
      "schema" => Hive::PatrolFix::TaskManifest::SCHEMA,
      "schema_version" => Hive::PatrolFix::TaskManifest::SCHEMA_VERSION,
      "task" => { "slug" => slug, "generation" => 1 },
      "evidence_revision" => { "generation" => 1, "digest" => digest },
      "target_revision" => revision,
      "sources" => [ {
        "engine" => "ordinary_patrol",
        "identity" => "scale-finding",
        "target_revision" => revision,
        "evidence" => [ "scale evidence" ],
        "affected_code" => [ "lib/hive/commands/status.rb" ],
        "reproduction_guidance" => "run the scale fixture",
        "discovery_run" => "scale-run",
        "semantic_lineage" => [ "scale-finding" ]
      } ],
      "aliases" => [],
      "relations" => { "successor" => nil, "issues" => [] }
    )
  end
  private_class_method :write_patrol_manifest
end
