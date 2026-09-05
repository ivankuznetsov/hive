require "digest"
require "json"
require "time"
require "hive/attempts/repository"
require "hive/markers"
require "hive/secret_patterns"
require "hive/task_projection/reader"
require "hive/task_workspace"
require "hive/task_workspace/attempts"
require "hive/task_workspace/dependency_component"
require "hive/task_workspace/jsonl_reader"
require "hive/task_workspace/provenance"
require "hive/task_workspace/publication"
require "hive/task_workspace/resources"
require "hive/task_workspace/semantic_snapshot"
require "hive/task_workspace/timeline"
require "hive/task_workspace/usage"

module Hive
  module TaskWorkspace
    # Composes one exact, already-resolved task into the normalized workspace
    # document used by Rails HTML and JSON. Every source is isolated behind a
    # panel boundary; the builder never enters fleet discovery or a remote
    # transport and never exposes an executable action token or command.
    class Builder
      DependencyTask = Data.define(:folder, :project_root, :slug)

      def initialize(task:, native_task:, project:, status_availability: "fresh",
                     status_last_success_at: nil, status_error: nil,
                     dependency_context: nil, publication_cache: nil,
                     dependency_publication_reader: nil,
                     cursor_codec:, limits: Limits.new, attempt_store: nil,
                     history_reader: nil, history_read: nil,
                     event_reader: nil, journal_reader: nil, usage_reader: Hive::UsageDb,
                     current_context_observation: nil, questions: nil,
                     daemon_enabled: true, archive: false,
                     clock: -> { Time.now.utc })
        @task = task
        @native_task = native_task
        @project = project.to_s
        @status_availability = status_availability.to_s
        @status_last_success_at = status_last_success_at
        @status_error = status_error
        @dependency_context = dependency_context
        @publication_cache = publication_cache
        @dependency_publication_reader = dependency_publication_reader
        @cursor_codec = cursor_codec
        @limits = limits
        @history_reader = history_reader
        @supplied_history_read = history_read
        @attempt_store = attempt_store
        @event_reader = event_reader
        @journal_reader = journal_reader
        @usage_reader = BoundedUsageReader.wrap(usage_reader, limits: @limits)
        @current_context_observation = current_context_observation
        @questions = questions
        @daemon_enabled = daemon_enabled == true
        @archive = archive == true
        @clock = clock
      end

      def call
        read = history_read
        projection = projection_hash(read)
        attempts = attempts_panel(read: read, projection: projection)
        resources = panel("resources") do
          Resources.new(
            attempts_panel: attempts, usage_reader: @usage_reader, limits: @limits
          ).call
        end
        provenance = panel("provenance") do
          Provenance.new(
            task: @native_task, attempts_panel: attempts, limits: @limits,
            current_observation: @current_context_observation, clock: @clock
          ).call
        end
        publication = panel("publication") { publication_panel }
        dependencies = panel("dependencies") do
          dependency_panel(publication)
        end
        timeline = timeline_panel(read: read)
        artifacts = artifacts_panel
        panels = {
          "provenance" => provenance, "attempts" => attempts,
          "resources" => resources, "timeline" => timeline,
          "dependencies" => dependencies, "publication" => publication,
          "artifacts" => artifacts
        }
        status = status_payload(read)
        operator = operator_payload
        answerable_questions = status["freshness"] == "fresh" ? operator.fetch("questions") : []
        action_evidence_current = status["state"] == "current" &&
                                  decision_panels_current?(attempts, resources)

        snapshot_with_budget(
          generated_at: now,
          task: {
            "project" => @project, "slug" => task_value("slug"),
            "id" => task_value("id"), "stage" => task_value("stage"),
            "generation" => projection.dig("identity", "task_generation") ||
              task_value("condition_task_generation") || task_value("task_generation")
          },
          status: status,
          operator: operator,
          decision: decision_payload(
            attempts: attempts, resources: resources,
            action_evidence_current: action_evidence_current,
            answerable_questions: answerable_questions
          ),
          panels: panels
        )
      end

      # Concise, workflow-aware read model used by operator HTML and native
      # task inspection. The v1 audit snapshot above remains unchanged.
      def semantic
        read = history_read
        projection = projection_hash(read)
        attempts = attempts_panel(read: read, projection: projection)
        artifacts = artifacts_panel
        usage = semantic_usage(attempts)
        status = status_payload(read)
        result = semantic_result(artifacts)
        applicability = semantic_applicability(result)

        semantic_snapshot_with_budget(
          generated_at: now,
          task: semantic_task(projection),
          status: status.slice("state", "freshness", "observed_at"),
          headline: semantic_headline(status),
          action: semantic_action(status),
          result: result,
          applicability: applicability,
          usage: usage,
          evidence: semantic_evidence(applicability),
          diagnostic: semantic_diagnostic(projection)
        )
      end

      # Used by the authenticated cursor endpoint. It reuses the same bounded
      # projection/event source policy but does not construct unrelated panels.
      def timeline(cursor: nil, raw_cursor: nil)
        timeline_panel(read: history_read, cursor: cursor, raw_cursor: raw_cursor)
      end

      private

      def attempts_panel(read:, projection:)
        @attempts_panel ||= panel("attempts") do
          Attempts.new(
            projection: projection, attempt_store: attempt_store,
            activities: read.journal_records, limits: @limits
          ).call
        end
      end

      def artifacts_panel
        @artifacts_panel ||= panel("artifacts") { artifact_panel }
      end

      def semantic_snapshot_with_budget(**values)
        compaction = 0
        loop do
          return SemanticSnapshot.new(**values, limits: @limits).to_h
        rescue ArgumentError => e
          raise unless e.message.include?("workspace_bytes")

          case compaction
          when 0
            values.fetch(:result)["supporting"].each do |artifact|
              artifact["content"] = nil
              artifact["truncated"] = true
            end
          when 1
            values.fetch(:usage)["groups"] = []
            values.fetch(:usage)["details_truncated"] = true
          when 2
            primary = values.dig(:result, "primary")
            raise unless primary

            primary["content"] = nil
            primary["truncated"] = true
          else
            raise
          end
          compaction += 1
        end
      end

      def semantic_task(projection)
        {
          "project" => @project,
          "slug" => task_value("slug"),
          "id" => task_value("id"),
          "stage" => task_value("stage"),
          "generation" => projection.dig("identity", "task_generation") ||
            task_value("condition_task_generation") || task_value("task_generation"),
          "workflow" => task_value("workflow") ||
            (@native_task.workflow.id if @native_task.workflow.respond_to?(:id)),
          "patrol_fix" => task_value("patrol_fix"),
          "archived" => @archive ||
            task_value("action").to_s == Hive::Schemas::TaskActionKind::ARCHIVED
        }
      end

      def semantic_result(artifacts)
        contract = @native_task.workflow.result
        records = Array(artifacts["records"]).map { |record| semantic_artifact(record) }
        declared = contract.primary_artifact
        primary = records.find { |record| record["reference"] == declared }
        primary ||= current_stage_artifact(records)
        primary ||= records.first
        warning = if declared && primary&.fetch("reference", nil) != declared && semantic_completed?
          "Declared primary artifact #{declared} is unavailable for this completed task."
        end
        {
          "kind" => contract.kind.to_s,
          "declared_primary" => declared,
          "primary" => primary,
          "supporting" => records.reject { |record| primary && record["reference"] == primary["reference"] },
          "warning" => warning
        }
      end

      def semantic_artifact(record)
        row = record.to_h.transform_keys(&:to_s)
        {
          "name" => row["name"].to_s,
          "reference" => row["reference"].to_s,
          "content" => row["content"],
          "bytes" => row["bytes"],
          "truncated" => row["truncated"] == true,
          "binary" => row["binary"] == true
        }
      end

      def current_stage_artifact(records)
        stage = @native_task.workflow.stage_for_dir(task_value("stage").to_s) ||
                @native_task.workflow.stage_named(@native_task.stage_name.to_s)
        reference = stage&.state_file
        records.find { |record| record["reference"] == reference }
      rescue StandardError
        nil
      end

      def semantic_applicability(result)
        capabilities = @native_task.workflow.result.capabilities.map(&:to_s)
        actual_worktree = actual_worktree_evidence?
        actual_publication = !task_value("pr_url").to_s.empty?
        actual_dependencies = !task_value("depends_on").to_s.empty?
        supporting = result.fetch("supporting").any?
        {
          "worktree" => capabilities.include?("worktree") || actual_worktree,
          "diff" => capabilities.include?("diff") || actual_worktree,
          "publication" => capabilities.include?("publication") || actual_publication,
          "media" => capabilities.include?("media"),
          "dependencies" => capabilities.include?("dependencies") || actual_dependencies,
          "supporting_artifacts" => capabilities.include?("supporting_artifacts") || supporting
        }
      end

      def semantic_usage(attempts)
        value = Usage.new(
          project_slug: @project, task_slug: task_value("slug"),
          attempts_panel: attempts, usage_reader: @usage_reader, limits: @limits
        ).call
        value = deep_stringify(value)
        value.delete("sessions")
        value.delete("diagnostics")
        remove_key!(value, "provider_reported_cost")
        value
      rescue StandardError
        {
          "coverage" => "unavailable", "tokens" => nil,
          "harnesses" => [], "actual_providers" => [], "actual_models" => [],
          "billing_routes" => [], "billing_route" => "unknown",
          "api_equivalent" => {
            "coverage" => "unavailable", "subtotal_usd" => nil,
            "observed_subtotal_usd" => nil, "priced_sessions_count" => 0,
            "unpriced_sessions_count" => 0,
            "missing_dimensions" => [ "usage" ], "currency" => "USD"
          },
          "groups" => []
        }
      end

      def semantic_action(status)
        kind = task_value("action")&.to_s
        enabled = status["freshness"] == "fresh" && status["state"] == "current" &&
                  !@archive && !semantic_completed? && semantic_actionable?(kind)
        {
          "kind" => kind,
          "label" => task_value("action_label")&.to_s,
          "enabled" => enabled,
          "reason" => semantic_action_reason(enabled, status)
        }
      end

      def semantic_actionable?(kind)
        return false if kind.to_s.empty?
        return false if %w[
          agent_working agent_running archived blocked error held idle complete manual_steering
        ].include?(kind)

        true
      end

      def semantic_action_reason(enabled, status)
        return nil if enabled
        return "Archived and completed tasks are read-only." if @archive || semantic_completed?
        return "Refresh canonical task status before acting." unless
          status["freshness"] == "fresh" && status["state"] == "current"

        "The canonical task state has no operator action."
      end

      def semantic_headline(status)
        if @archive || semantic_completed?
          return {
            "state" => "completed", "label" => "Completed",
            "explanation" => "This task is complete and read-only."
          }
        end
        summary = semantic_diagnostic_summary
        if summary
          return {
            "state" => "needs_attention",
            "label" => task_value("action_label")&.to_s || "Needs attention",
            "explanation" => summary
          }
        end
        if status["freshness"] != "fresh" || status["state"] != "current"
          return {
            "state" => "unavailable", "label" => "Current state unavailable",
            "explanation" => "Canonical task status is stale or incomplete."
          }
        end
        {
          "state" => task_value("action")&.to_s || "current",
          "label" => task_value("action_label")&.to_s || "Current task",
          "explanation" => "Canonical workflow status is current."
        }
      end

      def semantic_diagnostic(projection)
        summary = semantic_diagnostic_summary
        return {
          "state" => "not_applicable", "summary" => nil,
          "log" => { "state" => "unavailable", "quality" => nil, "reference" => nil }
        } unless summary

        reference = correlated_log_reference(projection)
        {
          "state" => "current", "summary" => summary,
          "log" => {
            "state" => reference ? "current" : "unavailable",
            "quality" => reference ? "receipt_correlated" : nil,
            "reference" => reference
          }
        }
      end

      def semantic_diagnostic_summary
        diagnostic = task_value("diagnostic")
        value = diagnostic.is_a?(Hash) ? diagnostic["summary"] || diagnostic[:summary] : nil
        text = operator_text(value, 4 * 1024, nil_if_empty: true)
        recovery = task_value("action").to_s.start_with?("recover_") ||
                   task_value("action").to_s == "error"
        recovery ? (text || task_value("action_label")&.to_s) : text
      end

      def correlated_log_reference(projection)
        attempt_id = projection.dig("identity", "attempt_id").to_s
        return nil if attempt_id.empty?

        record = attempt_store.fetch(attempt_id)
        receipt = raw_value(record, "receipt")
        reference = raw_value(receipt, "log_reference") || raw_value(record, "log_reference")
        return nil unless reference.is_a?(Hash)

        value = deep_stringify(reference)
        TaskWorkspace.safe_value!(value)
      rescue StandardError
        nil
      end

      def semantic_evidence(applicability)
        applicability.to_h do |name, applicable|
          state = if !applicable
            "not_applicable"
          elsif name == "publication" && !task_value("pr_url").to_s.empty?
            "current"
          elsif %w[worktree diff].include?(name) && actual_worktree_evidence?
            "current"
          elsif name == "dependencies" && !task_value("depends_on").to_s.empty?
            "current"
          else
            "missing"
          end
          [ name, { "applicable" => applicable, "state" => state } ]
        end
      end

      def actual_worktree_evidence?
        path = task_value("worktree_path").to_s
        !path.empty? && File.directory?(path)
      rescue SystemCallError
        false
      end

      def semantic_completed?
        @archive || task_value("action").to_s == Hive::Schemas::TaskActionKind::ARCHIVED
      end

      def raw_value(value, key)
        value.respond_to?(:[]) ? value[key] : nil
      end

      def deep_stringify(value)
        case value
        when Hash
          value.to_h { |key, child| [ key.to_s, deep_stringify(child) ] }
        when Array
          value.map { |child| deep_stringify(child) }
        else
          value
        end
      end

      def remove_key!(value, forbidden)
        case value
        when Hash
          value.delete(forbidden)
          value.each_value { |child| remove_key!(child, forbidden) }
        when Array
          value.each { |child| remove_key!(child, forbidden) }
        end
        value
      end

      def history_read
        @history_read ||= begin
          @supplied_history_read || history_reader.read_bounded(marker: marker, limits: @limits)
        rescue StandardError => e
          Hive::TaskProjection::Reader::BoundedRead.new(
            projection: nil, state: "partial",
            diagnostics: [ diagnostic("task_projection", "bounded_projection_failed", e.class.name) ],
            truncated: false, journal_cursor: 0, journal_records: []
          )
        end
      end

      def history_reader
        @history_reader ||= Hive::TaskProjection::Reader.new(
          task_folder: @native_task.folder, task: @native_task
        )
      end

      def attempt_store
        @attempt_store ||= Hive::Attempts::Repository.open_default(create_directories: false).read_session
      end

      def marker
        Hive::Markers::State.new(
          name: task_value("marker").to_s.empty? ? :none : task_value("marker").to_sym,
          attrs: task_value("attrs").to_h,
          raw: nil
        )
      end

      def projection_hash(read)
        projection = read.projection
        value = projection.respond_to?(:to_h) ? projection.to_h : projection
        return value if value.is_a?(Hash)

        {
          "identity" => {
            "attempt_id" => task_value("current_attempt") || task_value("attempt_id"),
            "task_generation" => task_value("condition_task_generation") ||
              task_value("task_generation")
          },
          "journal" => {}
        }
      end

      def timeline_panel(read:, cursor: nil, raw_cursor: nil)
        decoder = Timeline.new(
          task_identity: {
            "project" => @project, "slug" => task_value("slug"),
            "task_id" => task_value("id")
          },
          journal_records: [], event_records: [],
          limits: @limits, cursor_codec: @cursor_codec, clock: @clock
        )
        before = cursor ? decoder.source_before(cursor) : {}
        journal = timeline_source_result(
          @journal_reader,
          reference: Hive::TaskJournal::JOURNAL_BASENAME, source: "task_journal",
          before: before["task_journal"], fallback_records: read.journal_records
        )
        events = timeline_source_result(
          @event_reader, reference: "events.jsonl", source: "event_stream",
          before: before["event_stream"]
        )
        value = Timeline.new(
          task_identity: {
            "project" => @project, "slug" => task_value("slug"),
            "task_id" => task_value("id")
          },
          journal_records: journal.records,
          event_records: events.records,
          source_positions: {
            "task_journal" => {
              "start" => journal.window_start, "end" => journal.window_end
            },
            "event_stream" => {
              "start" => events.window_start, "end" => events.window_end
            }
          },
          source_truncated: {
            "task_journal" => journal.truncated,
            "event_stream" => events.truncated
          },
          limits: @limits, cursor_codec: @cursor_codec, clock: @clock
        ).call(cursor: cursor, raw_cursor: raw_cursor)
        diagnostics = Array(value["diagnostics"]) + Array(read.diagnostics) +
                      Array(events.diagnostics)
        state = value["state"]
        state = "partial" if state != "unavailable" && diagnostics.any?
        TaskWorkspace.normalize_panel(
          "timeline",
          value.merge(
            "state" => state, "diagnostics" => diagnostics.uniq,
            "truncated" => value["truncated"] == true || read.truncated || events.truncated
          )
        )
      end

      def timeline_source_result(reader, reference:, source:, before:, fallback_records: [])
        reader ||= JsonlReader.new(
          root: @native_task.folder, reference: reference,
          max_bytes: @limits.fetch(:journal_suffix_bytes),
          max_records: @limits.fetch(:journal_events), source: source,
          preserve: Timeline.method(:material_record?)
        )
        result = before.nil? ? reader.call : reader.call(before: before)
        if result.records.empty? && result.observed_bytes.zero? && fallback_records.any? && before.nil?
          return JsonlReader::Result.new(
            records: fallback_records, diagnostics: [], truncated: false,
            observed_bytes: 0, observed_records: fallback_records.length,
            window_start: 0, window_end: 0
          )
        end
        result
      rescue StandardError => e
        JsonlReader::Result.new(
          records: [],
          diagnostics: [ diagnostic(source, "bounded_#{source}_read_failed", e.class.name) ],
          truncated: false, observed_bytes: 0, observed_records: 0,
          window_start: 0, window_end: 0
        )
      end

      def publication_panel
        if @task.respond_to?(:publication)
          @task.publication(cache: @publication_cache)
        else
          TaskWorkspace.unavailable_panel("publication")
        end
      end

      def artifact_panel
        if @task.respond_to?(:artifact_panel)
          @task.artifact_panel
        else
          TaskWorkspace.unavailable_panel("artifacts")
        end
      end

      def dependency_panel(publication)
        return TaskWorkspace.unavailable_panel("dependencies") unless @dependency_context

        DependencyComponent.new(
          context: @dependency_context, project: @project,
          slug: task_value("slug"), git_observations: git_observations(publication),
          git_observation_reader: method(:dependency_git_observation),
          limits: @limits
        ).call
      end

      def dependency_git_observation(task, project, deadline: nil)
        panel = if @dependency_publication_reader
          if accepts_deadline?(@dependency_publication_reader)
            @dependency_publication_reader.call(task, project, deadline: deadline)
          else
            @dependency_publication_reader.call(task, project)
          end
        else
          candidate = DependencyTask.new(task.folder, project.path, task.slug)
          Publication.new(
            task: candidate,
            expected_repository: project.repository_identity,
            cache: project.name.to_s == @project ? @publication_cache : nil,
            limits: @limits, deadline: deadline
          ).call
        end
        git_observation_from_publication(panel)
      end

      def git_observations(publication)
        observation = git_observation_from_publication(publication)
        return {} if observation.empty?

        { "#{@project}:#{task_value('slug')}" => observation }
      end

      def git_observation_from_publication(publication)
        local = publication["local"]
        pr = publication["pull_request"]
        return {} unless local.is_a?(Hash)

        {
          "repository" => local["repository"],
          "base_branch" => local["base_branch"],
          "base_oid" => local["base_oid"],
          "observed_base_oid" => local["observed_base_oid"],
          "current_branch" => local["branch"],
          "head_oid" => local["head_oid"],
          "pr_number" => pr.is_a?(Hash) ? pr["number"] : nil
        }
      end

      def status_payload(read)
        freshness = case @status_availability
        when "fresh", "" then "fresh"
        when "degraded", "stale" then "stale"
        when "partial" then "partial"
        else "unavailable"
        end
        state = if read.truncated
          "partial"
        else
          case [ freshness, read.state.to_s ]
          in [ "unavailable", _ ] then "unavailable"
          in [ "stale", _ ] then "stale"
          in [ _, "stale" ] then "stale"
          in [ _, "busy" ] then "unavailable"
          in [ _, "partial" ] then "partial"
          else "current"
          end
        end
        diagnostics = Array(read.diagnostics).dup
        unless @status_availability.empty? || @status_availability == "fresh"
          diagnostics << diagnostic(
            "status_snapshot", "status_#{@status_availability}",
            status_error_class
          )
        end
        {
          "state" => state,
          "freshness" => freshness,
          "observed_at" => valid_time(
            task_value("observation_mtime") || @status_last_success_at || task_value("mtime")
          ),
          "diagnostics" => diagnostics.uniq
        }
      end

      def decision_payload(attempts:, resources:, action_evidence_current:,
                           answerable_questions:)
        action_kind = task_value("action")&.to_s
        action_label = task_value("action_label")&.to_s
        answer_evidence_current = answerable_questions.any?
        enabled, action_reason = action_enabled(
          evidence_current: action_evidence_current,
          answer_evidence_current: answer_evidence_current
        )
        posture, reason = if @archive
          [ "investigate", "Archived task evidence is read-only." ]
        elsif answer_evidence_current
          count = answerable_questions.length
          [ "answer", "#{count} required #{count == 1 ? 'question is' : 'questions are'} unanswered." ]
        elsif !action_evidence_current
          [ "investigate", "Action-driving workspace evidence is degraded or incomplete." ]
        elsif task_predicate(:passable?)
          [ "approve", "The current stage has a canonical completion marker." ]
        elsif task_predicate(:recovery_action_visible?) && task_predicate(:recovery_action_enabled?)
          [ "retry", "The canonical recovery path is available for the current observation." ]
        elsif wait_state?(attempts, resources)
          [ "wait", wait_reason(attempts, resources) ]
        elsif action_kind.to_s.start_with?("ready_") && @daemon_enabled
          [ "wait", "The daemon owns the next canonical dispatch." ]
        else
          [ "investigate", "No safe wait, answer, approval, or retry decision is established." ]
        end
        {
          "posture" => posture, "reason" => reason,
          "action" => {
            "kind" => action_kind, "label" => action_label,
            "enabled" => enabled, "reason" => action_reason
          }
        }
      end

      def decision_panels_current?(attempts, resources)
        current_id = attempts["current_attempt_id"].to_s
        current_attempt_present = !current_id.empty? && Array(attempts["records"]).any? do |attempt|
          attempt["attempt_id"].to_s == current_id && attempt["current"] == true
        end
        current_attempt_present && attempts["state"] == "current" &&
          attempts["truncated"] != true &&
          %w[current exhausted retry-after].include?(resources["state"]) &&
          resources["truncated"] != true
      end

      def accepts_deadline?(reader)
        reader.parameters.any? do |kind, name|
          kind == :keyrest || %i[key keyreq].include?(kind) && name == :deadline
        end
      end

      def operator_payload
        recovery = @task.respond_to?(:recovery) ? @task.recovery : nil
        recovery_visible = task_predicate(:recovery_action_visible?)
        {
          "questions" => Array(@questions).first(100).filter_map do |question|
            n = question_value(question, :n)
            n = operator_text(n, 256) if n.is_a?(String) || n.is_a?(Symbol)
            next unless n.is_a?(Integer) || n.is_a?(String)
            text = operator_text(question_value(question, :text), 16 * 1024)
            binding = operator_text(question_value(question, :binding), 16 * 1024)
            ordinal = Integer(question_value(question, :ordinal), exception: false)
            next if n.nil? || text.empty? || binding.empty? || ordinal.nil?

            { "n" => n, "text" => text, "binding" => binding, "ordinal" => ordinal }
          end,
          "recovery" => (recovery || recovery_visible) && {
            "status" => operator_text(recovery&.dig("status"), 128, nil_if_empty: true),
            "primary_label" => operator_text(
              @task.respond_to?(:recovery_primary_label) ? @task.recovery_primary_label : nil, 512
            ),
            "context" => Array(
              @task.respond_to?(:recovery_context) ? @task.recovery_context : []
            ).first(20).map { |item| operator_text(item, 4 * 1024) },
            "action_visible" => recovery_visible,
            "action_enabled" => task_predicate(:recovery_action_enabled?)
          },
          "diagnostic_summary" => operator_text(
            task_value("diagnostic").is_a?(Hash) ? task_value("diagnostic")["summary"] : nil,
            4 * 1024, nil_if_empty: true
          )
        }
      end

      def question_value(question, name)
        question.respond_to?(name) ? question.public_send(name) : question[name.to_s] || question[name]
      rescue StandardError
        nil
      end

      def operator_text(value, limit, nil_if_empty: false)
        text = Hive::SecretPatterns.redact(value.to_s).force_encoding(Encoding::UTF_8).scrub("")
        text = text.byteslice(0, limit).to_s.force_encoding(Encoding::UTF_8).scrub("")
        text = text.gsub(%r{(?<![A-Za-z0-9])/(?:[^\s/]+/)*[^\s]*}, "[REDACTED:path]")
        nil_if_empty && text.empty? ? nil : text
      end

      def action_enabled(evidence_current:, answer_evidence_current:)
        return [ false, "Archived tasks are read-only." ] if @archive
        return [ true, nil ] if answer_evidence_current
        unless evidence_current
          return [ false, "Refresh complete workspace evidence before acting." ]
        end
        return [ true, nil ] if task_predicate(:passable?)
        if task_predicate(:recovery_action_visible?)
          return task_predicate(:recovery_action_enabled?) ? [ true, nil ] :
            [ false, "Recovery is already queued, cooling down, or requires intervention." ]
        end
        if !@daemon_enabled && @task.respond_to?(:dispatch_action) && @task.dispatch_action
          return [ true, nil ]
        end

        [ false, "No existing canonical task control is enabled for this state." ]
      end

      def wait_state?(attempts, resources)
        return true if task_value("action").to_s == "agent_running"
        return true if task_value("held")
        return true if @task.respond_to?(:recovery) && @task.recovery &&
                       %w[queued cooldown running].include?(@task.recovery["status"].to_s)
        return true if Array(attempts["records"]).any? do |attempt|
          attempt["current"] && Array(attempt["sessions"]).any? { |session| session["live"] }
        end

        Array(resources["records"]).any? { |record| record["state"] == "retry-after" }
      end

      def wait_reason(attempts, resources)
        return "The current attempt has a live, durable session observation." if
          Array(attempts["records"]).any? do |attempt|
            attempt["current"] && Array(attempt["sessions"]).any? { |session| session["live"] }
          end
        return "A resource guard has a scheduled retry time." if
          Array(resources["records"]).any? { |record| record["state"] == "retry-after" }
        return "Recovery is already in progress or cooling down." if
          @task.respond_to?(:recovery) && @task.recovery
        return "The task is on an authorized hold." if task_value("held")

        "The canonical task action reports an active agent."
      end

      def task_predicate(name)
        @task.respond_to?(name) && @task.public_send(name) == true
      rescue StandardError
        false
      end

      def panel(name, &block)
        TaskWorkspace.panel(name, &block)
      end

      def snapshot_with_budget(generated_at:, task:, status:, operator:, decision:, panels:)
        candidates = %w[artifacts dependencies timeline provenance attempts resources publication]
        working = JSON.parse(JSON.generate(panels))
        loop do
          return Snapshot.new(
            generated_at: generated_at, task: task, status: status,
            operator: operator, decision: decision, panels: working, limits: @limits
          ).to_h
        rescue ArgumentError => e
          raise unless e.message.include?("workspace_bytes")

          name = candidates.shift
          raise unless name

          working[name] = compact_for_workspace(name, working.fetch(name))
        end
      end

      def compact_for_workspace(name, value)
        observed = JSON.generate(value).bytesize
        records = if name == "artifacts"
          Array(value["records"]).map do |record|
            record.merge("content" => nil, "truncated" => true)
          end
        else
          []
        end
        {
          "state" => "partial", "records" => records,
          "diagnostics" => Array(value["diagnostics"]) + [
            diagnostic(
              "workspace", "limit_exhausted", nil,
              "cap" => "workspace_bytes", "limit" => @limits.fetch(:workspace_bytes),
              "observed" => observed, "panel" => name
            )
          ],
          "truncated" => true
        }
      end

      def task_value(key)
        @task.respond_to?(:[]) ? @task[key] : nil
      end

      def now
        value = @clock.call
        (value.respond_to?(:utc) ? value.utc : Time.iso8601(value.to_s).utc).iso8601(6)
      end

      def valid_time(value)
        return nil if value.to_s.empty?

        Time.iso8601(value.to_s).utc.iso8601(6)
      rescue ArgumentError
        nil
      end

      def status_error_class
        value = @status_error.to_s[/\A[A-Za-z0-9_:]+/]
        value.to_s.empty? ? nil : value
      end

      def diagnostic(source, reason, message = nil, **details)
        {
          "source" => source, "reason" => reason,
          "message" => Hive::SecretPatterns.redact(message.to_s),
          "details" => details
        }
      end
    end
  end
end
