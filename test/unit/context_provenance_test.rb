require "test_helper"
require "json_schemer"
require "hive/context_provenance"

class ContextProvenanceTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 12, 9, 30, 0)
  TaskStub = Struct.new(
    :id, :slug, :folder, :project_root, :stage_index, :stage_name,
    :project_name, :workflow, keyword_init: true
  )
  AttemptStub = Struct.new(:attempt_id, :data, keyword_init: true) do
    def [](key) = data[key]
    def task_input_epoch = data.fetch("task_input_epoch")
    def ownership_generation = data.fetch("ownership_generation")
  end
  ContextStub = Struct.new(
    :attempt_id, :task_generation, :ownership_generation, :project,
    :task_slug, :intended_stage, keyword_init: true
  )

  class ActivityRecorder
    attr_reader :calls

    def initialize
      @calls = []
    end

    def record(**attributes)
      @calls << attributes
      Struct.new(:event_id).new("event-#{@calls.length}")
    end
  end

  class FailingActivityRecorder < ActivityRecorder
    def record(**)
      raise Hive::TaskActivity::AppendFailed, "disk unavailable"
    end
  end

  def test_launch_receipt_preserves_repository_and_wiki_identity
    with_fixture do |task, attempt, _context|
      activity = ActivityRecorder.new
      receipt = Hive::ContextProvenance.capture_launch(
        task: task, attempt: attempt, activity: activity, clock: -> { NOW }
      )

      assert_equal "controller_launch", receipt.fetch("kind")
      assert_equal "observed_at_launch", receipt.fetch("quality")
      assert_equal git(task.project_root, "rev-parse", "HEAD"), receipt.dig("repository", "head_oid")
      assert_equal "git_tree", receipt.dig("wiki", "identity_kind")
      assert_match(/\A[0-9a-f]{40,64}\z/, receipt.dig("wiki", "identifier"))
      assert_equal "current", receipt.dig("repository", "state")
      assert_equal "context_launch_captured", activity.calls.fetch(0).fetch(:kind)
      schema = JSONSchemer.schema(
        JSON.parse(File.read(Hive::Schemas.schema_path("hive-context-receipt")))
      )
      assert schema.valid?(receipt), schema.validate(receipt).to_a.inspect

      persisted = JSON.parse(File.read(File.join(task.folder, "context-receipts", "attempt-1.launch.json")))
      assert_equal receipt, persisted

      File.write(File.join(task.project_root, "wiki", "index.md"), "changed\n")
      git(task.project_root, "add", "wiki/index.md")
      git(task.project_root, "commit", "-m", "change wiki")
      current = Hive::ContextProvenance.observe_current(task: task, clock: -> { NOW + 60 })

      refute_equal receipt.dig("repository", "head_oid"), current.dig("repository", "head_oid")
      refute_equal receipt.dig("wiki", "identifier"), current.dig("wiki", "identifier")
      assert_equal receipt, JSON.parse(File.read(File.join(task.folder, "context-receipts", "attempt-1.launch.json")))
    end
  end

  def test_launch_capture_is_idempotent_and_missing_wiki_is_explicit
    with_fixture(wiki: false) do |task, attempt, _context|
      first = Hive::ContextProvenance.capture_launch(task: task, attempt: attempt, clock: -> { NOW })
      second = Hive::ContextProvenance.capture_launch(task: task, attempt: attempt, clock: -> { NOW })

      assert_equal first, second
      assert_equal "missing", first.dig("wiki", "state")
      assert_equal "missing", first.dig("wiki", "identity_kind")
      assert_nil first.dig("wiki", "identifier")
    end
  end

  def test_agent_receipt_is_validated_promoted_and_recorded_without_claiming_consumption
    with_fixture do |task, _attempt, context|
      activity = ActivityRecorder.new
      candidate = agent_receipt(task, context).merge(
        "selection" => {
          "references" => [
            { "path" => "wiki/index.md", "kind" => "wiki", "label" => "workspace overview" }
          ],
          "queries" => [
            { "query" => "task detail workspace", "result_labels" => [ "wiki/index.md" ] }
          ],
          "rationale" => "The index establishes the task-page ownership boundary."
        }
      )
      write_candidate(task, context, candidate)

      result = Hive::ContextProvenance.promote_agent_receipt(
        task: task, context: context, activity: activity, clock: -> { NOW }
      )

      assert_equal :promoted, result.status
      assert_equal "agent_asserted_used", result.receipt.fetch("quality")
      assert_equal "context_selection_reported", activity.calls.fetch(0).fetch(:kind)
      assert_equal "agent asserted selected context", activity.calls.fetch(0).fetch(:reason)
      refute File.exist?(candidate_path(task, context))
      assert File.file?(File.join(task.folder, "context-receipts", "attempt-1.json"))

      repeated = Hive::ContextProvenance.promote_agent_receipt(
        task: task, context: context, activity: activity, clock: -> { NOW }
      )
      assert_equal :already_promoted, repeated.status
    end
  end

  def test_agent_receipt_rejects_wrong_binding_absolute_traversal_symlink_and_oversize
    with_fixture do |task, _attempt, context|
      cases = {
        wrong_attempt: agent_receipt(task, context).tap { |row| row["binding"]["attempt_id"] = "other" },
        absolute: with_reference(agent_receipt(task, context), "/etc/passwd"),
        traversal: with_reference(agent_receipt(task, context), "../secret.txt")
      }

      outside = File.join(File.dirname(task.project_root), "outside.txt")
      File.write(outside, "outside")
      File.symlink(outside, File.join(task.project_root, "wiki", "escape.md"))
      cases[:symlink] = with_reference(agent_receipt(task, context), "wiki/escape.md")

      cases.each do |label, candidate|
        write_candidate(task, context, candidate)
        result = Hive::ContextProvenance.promote_agent_receipt(
          task: task, context: context, clock: -> { NOW }
        )
        assert_equal :rejected, result.status, label
        refute File.exist?(File.join(task.folder, "context-receipts", "attempt-1.json")), label
        File.delete(candidate_path(task, context)) if File.exist?(candidate_path(task, context))
      end

      FileUtils.mkdir_p(File.dirname(candidate_path(task, context)))
      File.binwrite(candidate_path(task, context), "{" + ("x" * (Hive::ContextProvenance::MAX_RECEIPT_BYTES + 1)))
      oversized = Hive::ContextProvenance.promote_agent_receipt(
        task: task, context: context, clock: -> { NOW }
      )
      assert_equal :rejected, oversized.status
      assert_equal "receipt_too_large", oversized.reason
    end
  end

  def test_agent_receipt_rejects_absolute_host_paths_in_every_context_string_family
    with_fixture do |task, _attempt, context|
      url_receipt = agent_receipt(task, context)
      url_receipt["repository"] = repository_context(
        repository: "https://github.com/example/demo"
      )
      assert Hive::ContextProvenance::ContextReceipt.validate_agent!(
        url_receipt, task: task, context: context
      )

      mutations = {
        reference_label: ->(row) { row["selection"]["references"] = [
          { "path" => "wiki/index.md", "kind" => "wiki", "label" => "read /home/alice/wiki" }
        ] },
        query: ->(row) { row["selection"]["queries"] = [
          { "query" => "inspect /home/alice/project", "result_labels" => [ "index" ] }
        ] },
        result_label: ->(row) { row["selection"]["queries"] = [
          { "query" => "workspace", "result_labels" => [ "C:\\Users\\alice\\wiki" ] }
        ] },
        rationale: ->(row) { row["selection"]["rationale"] = "source=/tmp/private-note" },
        repository: ->(row) { row["repository"] = repository_context(
          repository: "/home/alice/project"
        ) },
        wiki: ->(row) { row["wiki"] = wiki_context(identifier: "/home/alice/wiki") },
        diagnostic: ->(row) { row["diagnostics"] = [
          { "code" => "agent_note", "detail" => "opened /etc/passwd" }
        ] },
        repository_diagnostic: ->(row) { row["repository"] = repository_context(
          diagnostics: [ { "code" => "agent_note", "detail" => "at /var/tmp/repo" } ]
        ) },
        wiki_diagnostic: ->(row) { row["wiki"] = wiki_context(
          diagnostics: [ { "code" => "agent_note", "detail" => "at \\\\host\\share\\wiki" } ]
        ) }
      }

      mutations.each do |_label, mutate|
        receipt = agent_receipt(task, context)
        mutate.call(receipt)
        assert_raises(Hive::ContextProvenance::ContextReceipt::InvalidReceipt) do
          Hive::ContextProvenance::ContextReceipt.validate_agent!(
            receipt, task: task, context: context
          )
        end
      end
    end
  end

  def test_already_promoted_retry_repairs_missing_selection_activity
    with_fixture do |task, _attempt, context|
      write_candidate(task, context, agent_receipt(task, context))
      failed = Hive::ContextProvenance.promote_agent_receipt(
        task: task, context: context, activity: FailingActivityRecorder.new,
        clock: -> { NOW }
      )
      assert_equal :promoted, failed.status

      activity = ActivityRecorder.new
      retried = Hive::ContextProvenance.promote_agent_receipt(
        task: task, context: context, activity: activity, clock: -> { NOW }
      )

      assert_equal :already_promoted, retried.status
      assert_equal [ "context_selection_reported" ],
                   activity.calls.map { |call| call.fetch(:kind) }
    end
  end

  def test_immutable_write_never_replaces_a_concurrent_receipt
    with_fixture do |task, _attempt, context|
      reference = Hive::ContextProvenance.promoted_reference(context.attempt_id)
      contender = agent_receipt(task, context).tap do |row|
        row["selection"]["rationale"] = "The concurrent writer won."
      end
      original_link = File.method(:link)
      link_with_contender = lambda do |source, destination|
        competing = "#{source}.competing"
        File.write(competing, JSON.pretty_generate(contender) + "\n")
        original_link.call(competing, destination)
        original_link.call(source, destination)
      ensure
        File.delete(competing) if competing && File.exist?(competing)
      end

      with_replaced_singleton_method(File, :link, link_with_contender) do
        error = assert_raises(Hive::ContextProvenance::UnsafeReceipt) do
          Hive::ContextProvenance.write_immutable(
            task.folder, reference, agent_receipt(task, context)
          )
        end
        assert_equal "receipt_conflict", error.reason
      end

      persisted = JSON.parse(File.read(File.join(task.folder, reference)))
      assert_equal "The concurrent writer won.", persisted.dig("selection", "rationale")
    end
  end

  def test_agent_receipt_redacts_secrets_and_schema_accepts_promoted_document
    with_fixture do |task, _attempt, context|
      candidate = agent_receipt(task, context)
      candidate["selection"]["rationale"] = "token sk-#{'a' * 30} was present"
      write_candidate(task, context, candidate)

      result = Hive::ContextProvenance.promote_agent_receipt(
        task: task, context: context, activity: ActivityRecorder.new,
        clock: -> { NOW }
      )
      assert_equal :promoted, result.status
      assert_includes result.receipt.dig("selection", "rationale"), "[REDACTED:openai_api_key]"

      schema = JSONSchemer.schema(
        JSON.parse(File.read(Hive::Schemas.schema_path("hive-context-receipt")))
      )
      assert schema.valid?(result.receipt), schema.validate(result.receipt).to_a.inspect
    end
  end

  def test_agent_receipt_types_and_redacts_repository_and_wiki_assertions
    with_fixture do |task, _attempt, context|
      candidate = agent_receipt(task, context)
      candidate["repository"] = {
        "state" => "partial", "head_oid" => "a" * 40,
        "branch" => "token sk-#{'a' * 30}",
        "repository" => "github.com/example/demo", "observed_from" => "local_git",
        "diagnostics" => [ { "code" => "agent_note", "detail" => "ghp_#{'b' * 36}" } ]
      }
      candidate["wiki"] = {
        "state" => "partial", "identity_kind" => "bounded_digest",
        "identifier" => "c" * 64, "file_count" => 1, "byte_count" => 12,
        "truncated" => false, "diagnostics" => []
      }
      write_candidate(task, context, candidate)

      result = Hive::ContextProvenance.promote_agent_receipt(
        task: task, context: context, activity: ActivityRecorder.new,
        clock: -> { NOW }
      )

      assert_equal :promoted, result.status
      refute_includes JSON.generate(result.receipt), "sk-#{'a' * 30}"
      refute_includes JSON.generate(result.receipt), "ghp_"

      wrong_selection_type = agent_receipt(task, context)
      wrong_selection_type["selection"]["references"] = "wiki/index.md"
      assert_raises(Hive::ContextProvenance::ContextReceipt::InvalidReceipt) do
        Hive::ContextProvenance::ContextReceipt.validate_agent!(
          wrong_selection_type, task: task, context: context
        )
      end

      malformed = agent_receipt(task, context)
      malformed["wiki"] = candidate["wiki"].merge("truncated" => "false")
      write_candidate(task, context, malformed)
      File.delete(File.join(task.folder, "context-receipts", "attempt-1.json"))
      assert_equal :rejected, Hive::ContextProvenance.promote_agent_receipt(
        task: task, context: context, clock: -> { NOW }
      ).status
    end
  end

  def test_repository_git_reads_disable_repository_local_execution_hooks
    captured = []
    replacement = lambda do |argv, timeout_sec:, max_bytes:|
      captured << [ argv, timeout_sec, max_bytes ]
      [ "", Struct.new(:success?).new(true), false ]
    end
    with_replaced_singleton_method(
      Hive::ContextProvenance::RepositorySnapshot, :capture_command, replacement
    ) do
      Hive::ContextProvenance::RepositorySnapshot.git("/tmp/demo", %w[status --porcelain])
    end

    argv = captured.fetch(0).fetch(0)
    assert_includes argv.each_cons(2).to_a, [ "-c", "core.fsmonitor=false" ]
    assert_includes argv.each_cons(2).to_a, [ "-c", "core.hooksPath=/dev/null" ]
  end

  def test_prompt_appendix_is_attempt_bound_bounded_and_optional
    with_fixture do |task, _attempt, context|
      prompt = "Keep the required artifact and write <!-- COMPLETE -->."
      decorated = Hive::ContextProvenance.decorate_prompt(
        task: task, prompt: prompt, context: context
      )

      assert decorated.start_with?(prompt)
      candidate = File.join(task.folder, "context-receipts", "attempt-1.json.next")
      assert_includes decorated, candidate
      refute_includes decorated, "write one JSON object to the task-relative path"
      assert_includes decorated, "optional"
      assert_includes decorated, "agent assertion"
      assert_includes decorated, "<!-- COMPLETE -->"
      assert_operator decorated.bytesize - prompt.bytesize, :<=,
                      Hive::ContextProvenance::MAX_PROMPT_APPENDIX_BYTES
      assert_equal prompt, Hive::ContextProvenance.decorate_prompt(
        task: task, prompt: prompt, context: nil
      )
    end
  end

  private

  def with_fixture(wiki: true)
    with_tmp_dir do |outer|
      project = File.join(outer, "demo")
      task_folder = File.join(project, ".hive-state", "stages", "4-execute", "task-260812-abcd")
      FileUtils.mkdir_p(task_folder)
      File.write(File.join(project, "README.md"), "demo\n")
      FileUtils.mkdir_p(File.join(project, "wiki")) if wiki
      File.write(File.join(project, "wiki", "index.md"), "# Workspace\n") if wiki
      git(project, "init")
      git(project, "config", "user.email", "test@example.com")
      git(project, "config", "user.name", "Test")
      git(project, "add", ".")
      git(project, "commit", "-m", "initial")
      git(project, "remote", "add", "origin", "git@github.com:example/demo.git")

      task = TaskStub.new(
        id: 7, slug: "task-260812-abcd", folder: task_folder, project_root: project,
        stage_index: 4, stage_name: "execute", project_name: "demo", workflow: :coding
      )
      attempt = AttemptStub.new(
        attempt_id: "attempt-1",
        data: {
          "task_id" => 7, "project" => "demo", "task_slug" => task.slug,
          "intended_stage" => "4-execute", "task_input_epoch" => 3,
          "ownership_generation" => "owner-3"
        }
      )
      context = ContextStub.new(
        attempt_id: "attempt-1", task_generation: 3,
        ownership_generation: "owner-3", project: "demo",
        task_slug: task.slug, intended_stage: "4-execute"
      )
      yield task, attempt, context
    end
  end

  def agent_receipt(task, context)
    {
      "schema" => "hive-context-receipt",
      "schema_version" => 1,
      "kind" => "agent_selection",
      "binding" => {
        "project" => task.project_name,
        "task_slug" => task.slug,
        "task_id" => task.id.to_s,
        "stage" => context.intended_stage,
        "attempt_id" => context.attempt_id,
        "task_generation" => context.task_generation,
        "ownership_generation" => context.ownership_generation
      },
      "captured_at" => NOW.iso8601(6),
      "quality" => "agent_asserted_used",
      "repository" => nil,
      "wiki" => nil,
      "selection" => {
        "references" => [], "queries" => [], "rationale" => "No additional context selected."
      },
      "diagnostics" => []
    }
  end

  def repository_context(repository: "github.com/example/demo", diagnostics: [])
    {
      "state" => "partial", "head_oid" => "a" * 40,
      "branch" => "feature", "repository" => repository,
      "observed_from" => "local_git", "diagnostics" => diagnostics
    }
  end

  def wiki_context(identifier: "b" * 64, diagnostics: [])
    {
      "state" => "partial", "identity_kind" => "bounded_digest",
      "identifier" => identifier, "file_count" => 1, "byte_count" => 12,
      "truncated" => false, "diagnostics" => diagnostics
    }
  end

  def with_reference(receipt, path)
    receipt.tap do |row|
      row["selection"]["references"] = [
        { "path" => path, "kind" => "source", "label" => "selected" }
      ]
    end
  end

  def candidate_path(task, context)
    File.join(task.folder, "context-receipts", "#{context.attempt_id}.json.next")
  end

  def write_candidate(task, context, payload)
    FileUtils.mkdir_p(File.dirname(candidate_path(task, context)))
    File.write(candidate_path(task, context), JSON.pretty_generate(payload))
  end

  def git(root, *args)
    FileUtils.mkdir_p(root)
    run!("git", "-C", root, *args).strip
  end
end
