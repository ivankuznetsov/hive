require "digest"
require "json"
require "time"
require "timeout"
require "hive/commands/status"
require "hive/config"
require "hive/terminal_text"

module Hive
  module Commands
    # A bounded, read-only status observer for agents. Selection is resolved
    # once from a full task graph; subsequent polls emit only meaningful state
    # changes and never interpret a missing row as successful completion.
    class Watch
      SourceSnapshot = Data.define(:operational, :full_graph)
      Selection = Data.define(:project, :slug, :id, :physical_identity) do
        def target = "#{project}:#{slug}"
      end

      class UsageError < Hive::InvalidTaskPath; end
      class StatusUnavailableError < Hive::UnavailableError; end
      # The overall-deadline interrupt must bypass broad StandardError rescues
      # inside a status source. It is always caught at this command boundary.
      class DeadlineExceeded < Exception; end # rubocop:disable Lint/InheritException

      DEFAULT_INTERVAL = 15.0
      DEFAULT_TIMEOUT = 1_800.0
      DEFAULT_MAX_EVENTS = 100
      MAX_TARGETS = 100
      SOURCE_ERROR_BUDGET = 3
      SETTLED_STATES = %w[waiting_on_you needs_repair completion_ready].freeze
      EVENT_REASONS = %w[
        source_failure task_disappeared settled completion timeout event_cap
        status_unavailable interrupted terminated
      ].freeze
      EPIPE_TAG = :hive_watch_epipe

      class Clock
        def now = Time.now.utc

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      # Collects the compatibility graph once and derives the operational view
      # from that exact object, preventing a watch poll from joining two scans
      # taken at different moments.
      class DefaultSource
        def fetch
          projects = Hive::Config.registered_projects
          status = Hive::Commands::Status.new(json: true)
          full_graph = status.json_payload(projects)
          operational = status.operational_payload(projects, status_payload: full_graph)
          SourceSnapshot.new(operational: operational, full_graph: full_graph)
        end
      end

      def initialize(targets:, project: nil, until_condition: "settled",
                     timeout: DEFAULT_TIMEOUT, max_events: DEFAULT_MAX_EVENTS,
                     interval: DEFAULT_INTERVAL, json_lines: false, json: false,
                     source: nil, clock: nil, sleeper: nil, output: $stdout,
                     signal_checker: nil, identity_resolver: nil)
        @targets = Array(targets).map(&:to_s)
        @project = project&.to_s
        @until_condition = until_condition.to_s
        @timeout = timeout
        @max_events = max_events
        @interval = interval
        @json_lines = json_lines
        @json = json
        @source = source || DefaultSource.new
        @clock = clock || Clock.new
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
        @output = output
        @signal_checker = signal_checker
        @identity_resolver = identity_resolver || method(:task_physical_identity)
        @received_signal = nil
      end

      def call
        catch(EPIPE_TAG) do
          with_signal_handlers { run }
        end
        0
      end

      private

      def run
        validate_options!
        started_at = @clock.monotonic
        snapshot = initial_snapshot!(started_at)
        current, current_fingerprint = initial_projection!(snapshot, started_at)
        missing_counts = Hash.new(0)
        non_final_events = 0

        emit(event_payload("initial", non_final_events, current))
        non_final_events += 1
        return emit_final("timeout", current, non_final_events) if timed_out?(started_at)
        return emit_terminal_final(current, non_final_events) if terminal?(current)
        return emit_final("event_cap", current, non_final_events) if non_final_events >= @max_events

        source_failures = 0
        loop do
          check_signal!(current, non_final_events)
          return emit_final("timeout", current, non_final_events) if timed_out?(started_at)

          sleep_for = [ @interval, @timeout - elapsed(started_at) ].min
          @sleeper.call(sleep_for) if sleep_for.positive?

          check_signal!(current, non_final_events)
          return emit_final("timeout", current, non_final_events) if timed_out?(started_at)

          begin
            next_snapshot = fetch_snapshot!(started_at)
            next_targets, next_fingerprint = within_deadline(started_at) do
              targets = materialize(next_snapshot)
              [ targets, semantic_fingerprint(targets) ]
            end
            source_failures = 0
          rescue DeadlineExceeded
            return emit_final("timeout", current, non_final_events)
          rescue StandardError => error
            source_failures += 1
            emit(event_payload(
              "source_warning", non_final_events, current,
              reason: "source_failure",
              message: "status source unavailable (#{source_failures}/#{SOURCE_ERROR_BUDGET}): " \
                       "#{error.class}: #{error.message}"
            ))
            non_final_events += 1
            if source_failures >= SOURCE_ERROR_BUDGET
              emit_final(
                "status_unavailable", current, non_final_events,
                ok: false, message: "status source unavailable after #{SOURCE_ERROR_BUDGET} consecutive polls"
              )
              raise StatusUnavailableError,
                    "status source unavailable after #{SOURCE_ERROR_BUDGET} consecutive polls"
            end
            return emit_final("event_cap", current, non_final_events) if non_final_events >= @max_events
            next
          end

          return emit_final("timeout", current, non_final_events) if timed_out?(started_at)

          missing = next_targets.reject { |target| target.fetch("present") }
          @selection.each do |selection|
            key = selection.target
            if missing.any? { |target| target.fetch("target") == key }
              missing_counts[key] += 1
            else
              missing_counts[key] = 0
            end
          end

          unless missing.empty?
            current = next_targets
            current_fingerprint = next_fingerprint
            worst = missing.map { |target| missing_counts.fetch(target.fetch("target")) }.max
            emit(event_payload(
              "source_warning", non_final_events, current,
              reason: "task_disappeared",
              message: "selected task missing from both active and verified archive views " \
                       "(#{worst}/#{SOURCE_ERROR_BUDGET}): " \
                       "#{missing.map { |target| target.fetch('target') }.join(', ')}"
            ))
            non_final_events += 1
            if worst >= SOURCE_ERROR_BUDGET
              emit_final(
                "status_unavailable", current, non_final_events,
                ok: false, message: "selected task disappeared without verified archival"
              )
              raise StatusUnavailableError, "selected task disappeared without verified archival"
            end
            return emit_final("event_cap", current, non_final_events) if non_final_events >= @max_events
            next
          end

          if next_fingerprint != current_fingerprint
            current = next_targets
            emit(event_payload("transition", non_final_events, current))
            non_final_events += 1
          else
            current = next_targets
          end
          current_fingerprint = next_fingerprint

          return emit_terminal_final(current, non_final_events) if terminal?(current)
          return emit_final("event_cap", current, non_final_events) if non_final_events >= @max_events
        end
      end

      def validate_options!
        if @json
          raise UsageError,
                "hive watch is a stream; use --json-lines instead of the global --json document mode"
        end
        unless %w[settled completion].include?(@until_condition)
          raise UsageError, "--until must be settled or completion"
        end
        @interval = positive_finite_number!(@interval, "--interval")
        @timeout = positive_finite_number!(@timeout, "--timeout")
        unless @max_events.is_a?(Numeric) && @max_events.finite? &&
               @max_events.positive? && @max_events.to_i == @max_events
          raise UsageError, "--max-events must be a positive integer"
        end
        @max_events = @max_events.to_i
        if @project&.empty?
          raise UsageError, "--project must not be empty"
        end
        if @targets.empty? && @project.nil?
          raise UsageError, "pass at least one TARGET or use --project to select active tasks"
        end
        if @targets.any?(&:empty?)
          raise UsageError, "TARGET must not be empty"
        end
      end

      def positive_finite_number!(value, flag)
        unless value.is_a?(Numeric) && value.finite? && value.positive?
          raise UsageError, "#{flag} must be a positive finite number"
        end

        value.to_f
      end

      def initial_snapshot!(started_at)
        fetch_snapshot!(started_at)
      rescue DeadlineExceeded => error
        raise StatusUnavailableError,
              "initial status source exceeded the overall timeout: #{error.message}"
      rescue StandardError => error
        raise StatusUnavailableError,
              "initial status source unavailable: #{error.class}: #{error.message}"
      end

      def initial_projection!(snapshot, started_at)
        within_deadline(started_at) do
          @selection = resolve_selection(snapshot)
          targets = materialize(snapshot)
          [ targets, semantic_fingerprint(targets) ]
        end
      rescue DeadlineExceeded => error
        raise StatusUnavailableError,
              "initial task identity resolution exceeded the overall timeout: #{error.message}"
      end

      def fetch_snapshot!(started_at)
        snapshot = within_deadline(started_at) { @source.fetch }
        unless snapshot.is_a?(SourceSnapshot) && snapshot.operational.is_a?(Hash) &&
               snapshot.full_graph.is_a?(Hash)
          raise TypeError, "watch source returned an invalid snapshot"
        end
        unless snapshot.operational["ok"] == true && snapshot.full_graph["ok"] == true
          raise TypeError, "watch source returned an unsuccessful status payload"
        end

        snapshot
      end

      def within_deadline(started_at, &block)
        remaining = @timeout - elapsed(started_at)
        unless remaining.positive?
          raise DeadlineExceeded, "watch status source exceeded the overall timeout"
        end

        Timeout.timeout(
          remaining, DeadlineExceeded, "watch status source exceeded the overall timeout", &block
        )
      end

      def resolve_selection(snapshot)
        candidates = candidate_index(snapshot)
        selected = if @targets.empty?
          candidates.values
                    .select do |entries|
                      entries.first.fetch(:project) == @project &&
                        entries.none? { |entry| entry.fetch(:archived) }
                    end
                    .sort_by { |entries| entries.first.fetch(:target) }
                    .map { |entries| selection_for_entries!(entries, entries.first.fetch(:target)) }
        else
          @targets.map { |target| resolve_target(target, candidates, snapshot) }
        end
        selected = selected.uniq { |entry| entry.target }

        if selected.empty?
          if @targets.empty? && !known_project?(snapshot, @project, candidates)
            raise UsageError, "unknown project #{@project.inspect}"
          end
          raise UsageError, "no active tasks selected for project #{@project.inspect}"
        end
        if selected.size > MAX_TARGETS
          raise UsageError, "hive watch accepts at most #{MAX_TARGETS} targets (selected #{selected.size})"
        end

        selected
      end

      def resolve_target(target, candidates, snapshot)
        if target.include?(":")
          project, slug = target.split(":", 2)
          if project.empty? || slug.empty?
            raise UsageError, "qualified TARGET must be PROJECT:SLUG"
          end
          if @project && project != @project
            raise UsageError, "target #{target.inspect} contradicts --project #{@project}"
          end
          entries = candidates[target]
          return selection_for_entries!(entries, target) if entries

          return missing_target!(target, snapshot)
        end

        matches = candidates.values.select do |entries|
          entry = entries.first
          entry.fetch(:slug) == target && (@project.nil? || entry.fetch(:project) == @project)
        end
        if matches.size > 1
          alternatives = matches.map { |entries| entries.first.fetch(:target) }.sort
          raise UsageError,
                "ambiguous target #{target.inspect}; use one of: #{alternatives.join(', ')}"
        end
        return selection_for_entries!(matches.first, target) if matches.one?

        missing_target!(@project ? "#{@project}:#{target}" : target, snapshot)
      end

      def missing_target!(target, snapshot)
        task_graph_status = snapshot.operational.dig("source", "task_graph", "status")
        if task_graph_status != "complete"
          raise StatusUnavailableError,
                "cannot resolve #{target.inspect} from an incomplete task graph (#{task_graph_status || 'unknown'})"
        end

        raise UsageError, "no task matches #{target.inspect}"
      end

      def candidate_index(snapshot)
        full = Hash.new { |hash, key| hash[key] = [] }
        Array(snapshot.full_graph["projects"]).each do |project|
          Array(project["tasks"]).each do |row|
            project_name = (row["project"] || project["name"]).to_s
            slug = row["slug"].to_s
            next if project_name.to_s.empty? || slug.to_s.empty?

            target = "#{project_name}:#{slug}"
            full[target] << {
              target: target, project: project_name, slug: slug,
              id: normalized_task_id(row["id"]), stage: row["stage"]&.to_s,
              folder: row["folder"]&.to_s,
              archived: row["action"] == "archived"
            }
          end
        end
        operational = Hash.new { |hash, key| hash[key] = [] }
        Array(snapshot.operational["tasks"]).each do |row|
          project_name = row.dig("identity", "project").to_s
          slug = row.dig("identity", "slug").to_s
          next if project_name.to_s.empty? || slug.to_s.empty?

          target = "#{project_name}:#{slug}"
          operational[target] << {
            target: target, project: project_name, slug: slug,
            id: normalized_task_id(row.dig("identity", "id")),
            stage: row.dig("position", "stage")&.to_s,
            folder: row.dig("identity", "folder")&.to_s,
            archived: false
          }
        end

        (full.keys | operational.keys).sort.to_h do |target|
          entries = operational[target]
          if entries.empty?
            active = full[target].reject { |entry| entry.fetch(:archived) }
            entries = active.empty? ? full[target] : active
          end
          [ target, entries ]
        end
      end

      def known_project?(snapshot, project_name, candidates)
        Array(snapshot.full_graph["projects"]).any? { |project| project["name"] == project_name } ||
          candidates.values.flatten.any? { |entry| entry.fetch(:project) == project_name }
      end

      def materialize(snapshot)
        selected = @selection.to_h do |selection|
          [ [ selection.project, selection.slug ], true ]
        end
        active = Hash.new { |hash, key| hash[key] = [] }
        Array(snapshot.operational["tasks"]).each do |row|
          key = [ row.dig("identity", "project"), row.dig("identity", "slug") ]
          active[key] << row if selected.key?(key)
        end
        archived = Hash.new { |hash, key| hash[key] = [] }
        Array(snapshot.full_graph["projects"]).each do |project|
          Array(project["tasks"]).each do |row|
            next unless row["action"] == "archived"

            project_name = row["project"] || project["name"]
            key = [ project_name, row["slug"] ]
            archived[key] << row if selected.key?(key)
          end
        end

        promoted_selections = []
        targets = @selection.map do |selection|
          key = [ selection.project, selection.slug ]
          active_rows = matching_rows(selection, active.fetch(key, []), archived: false)
          archived_rows = matching_rows(selection, archived.fetch(key, []), archived: true)
          ensure_single_materialized_row!(selection, active_rows, archived: false)
          ensure_single_materialized_row!(selection, archived_rows, archived: true)
          ensure_no_cross_view_collision!(selection, active_rows, archived_rows)
          row = active_rows.first || archived_rows.first
          effective_selection = promote_selection_id(selection, row, archived: active_rows.empty?)
          promoted_selections << effective_selection
          if active_rows.one?
            active_target(effective_selection, active_rows.first)
          elsif archived_rows.one?
            archived_target(effective_selection, archived_rows.first)
          else
            absent_target(effective_selection)
          end
        end
        @selection = promoted_selections
        targets
      end

      def selection_for_entries!(entries, target)
        if entries.size > 1
          alternatives = entries.sort_by { |entry| [ entry.fetch(:stage).to_s, entry.fetch(:folder).to_s ] }
                                .map { |entry| candidate_label(entry) }
          raise UsageError,
                "ambiguous target #{target.inspect}; multiple task rows share this identity: " \
                "#{alternatives.join('; ')}"
        end

        entry = entries.first
        id = entry.fetch(:id)
        physical_identity = resolve_physical_identity(entry.fetch(:folder)) if id.nil?
        if id.nil? && physical_identity.nil?
          raise StatusUnavailableError,
                "cannot safely watch id-less task #{entry.fetch(:target)}; " \
                "task-directory identity is unavailable"
        end
        Selection.new(
          project: entry.fetch(:project), slug: entry.fetch(:slug), id: id,
          physical_identity: physical_identity
        )
      end

      def candidate_label(entry)
        stage = entry.fetch(:stage).to_s.empty? ? "unknown-stage" : entry.fetch(:stage)
        folder = entry.fetch(:folder).to_s.empty? ? "unknown-folder" : entry.fetch(:folder)
        "#{entry.fetch(:target)} at #{stage} (#{folder})"
      end

      def ensure_single_materialized_row!(selection, rows, archived:)
        return if rows.size <= 1

        alternatives = rows.map { |row| materialized_row_label(row, archived: archived) }.sort
        raise StatusUnavailableError,
              "status returned multiple rows for #{selection.target}: #{alternatives.join('; ')}"
      end

      def ensure_no_cross_view_collision!(selection, active_rows, archived_rows)
        return if active_rows.empty? || archived_rows.empty?

        alternatives = active_rows.map { |row| materialized_row_label(row, archived: false) }
        alternatives.concat(
          archived_rows.map { |row| materialized_row_label(row, archived: true) }
        )
        raise StatusUnavailableError,
              "status returned active and archived rows for #{selection.target}: " \
              "#{alternatives.sort.join('; ')}"
      end

      def materialized_row_label(row, archived:)
        stage = archived ? row["stage"] : row.dig("position", "stage")
        folder = archived ? row["folder"] : row.dig("identity", "folder")
        kind = archived ? "archived" : "active"
        "#{kind} at #{stage || 'unknown-stage'} (#{folder || 'unknown-folder'})"
      end

      def matching_rows(selection, rows, archived:)
        rows.select do |row|
          id = archived ? row["id"] : row.dig("identity", "id")
          if selection.id
            normalized_task_id(id) == selection.id
          else
            folder = archived ? row["folder"] : row.dig("identity", "folder")
            resolve_physical_identity(folder) == selection.physical_identity
          end
        end
      end

      def promote_selection_id(selection, row, archived:)
        return selection if selection.id || row.nil?

        id = archived ? row["id"] : row.dig("identity", "id")
        id = normalized_task_id(id)
        return selection unless id

        Selection.new(
          project: selection.project, slug: selection.slug, id: id,
          physical_identity: selection.physical_identity
        )
      end

      def normalized_task_id(value)
        id = value&.to_s
        id unless id.nil? || id.empty?
      end

      def resolve_physical_identity(folder)
        return if folder.to_s.empty?

        @identity_resolver.call(folder.to_s)
      end

      def task_physical_identity(folder)
        stat = File.stat(folder)
        [ stat.dev, stat.ino ].freeze
      rescue SystemCallError
        nil
      end

      def active_target(selection, row)
        action = row["action"]
        state = row["state"]
        {
          "target" => selection.target,
          "project" => selection.project,
          "slug" => selection.slug,
          "present" => true,
          "archived" => false,
          "state" => state,
          "blocker_owner" => row["blocker_owner"],
          "reason" => row["reason"],
          "reason_codes" => Array(row["reasons"]).filter_map { |reason| reason["code"] }.uniq,
          "position" => {
            "stage" => row.dig("position", "stage"),
            "marker" => row.dig("position", "marker")
          },
          "provider" => provider_subset(row["provider"]),
          "freshness" => {
            "scheduler_status" => row.dig("freshness", "scheduler_status") || "unavailable"
          },
          "liveness_status" => row.dig("liveness", "status"),
          "terminality" => {
            "settled" => SETTLED_STATES.include?(state),
            "completion" => false
          },
          "action_policy" => action_policy(action)
        }
      end

      def archived_target(selection, row)
        {
          "target" => selection.target,
          "project" => selection.project,
          "slug" => selection.slug,
          "present" => true,
          "archived" => true,
          "state" => "completion_ready",
          "blocker_owner" => "none",
          "reason" => "task is archived",
          "reason_codes" => [ "archived" ],
          "position" => { "stage" => row["stage"], "marker" => row["marker"] },
          "provider" => nil,
          "freshness" => { "scheduler_status" => "not_applicable" },
          "liveness_status" => "not_running",
          "terminality" => { "settled" => true, "completion" => true },
          "action_policy" => nil
        }
      end

      def absent_target(selection)
        {
          "target" => selection.target,
          "project" => selection.project,
          "slug" => selection.slug,
          "present" => false,
          "archived" => false,
          "state" => nil,
          "blocker_owner" => nil,
          "reason" => "task is absent from the current status snapshot",
          "reason_codes" => [ "task_disappeared" ],
          "position" => nil,
          "provider" => nil,
          "freshness" => { "scheduler_status" => "unavailable" },
          "liveness_status" => nil,
          "terminality" => { "settled" => false, "completion" => false },
          "action_policy" => nil
        }
      end

      def provider_subset(provider)
        return unless provider.is_a?(Hash)

        { "name" => provider["name"], "retry_after" => provider["retry_after"] }
      end

      def action_policy(action)
        return unless action.is_a?(Hash)

        {
          "action_id" => action["action_id"],
          "risk_class" => action["risk_class"],
          "confirmation_required" => action["confirmation_required"] == true
        }
      end

      def terminal?(targets)
        key = @until_condition == "completion" ? "completion" : "settled"
        targets.all? { |target| target.dig("terminality", key) == true }
      end

      def emit_terminal_final(targets, sequence)
        emit_final(@until_condition, targets, sequence)
      end

      def timed_out?(started_at)
        elapsed(started_at) >= @timeout
      end

      def elapsed(started_at)
        @clock.monotonic - started_at
      end

      def check_signal!(targets, sequence)
        code = effective_signal_checker.call
        return unless code

        reason = code.to_i == 143 ? "terminated" : "interrupted"
        emit_final(reason, targets, sequence)
        raise SystemExit.new(code.to_i)
      end

      def effective_signal_checker
        @signal_checker || -> { @received_signal }
      end

      def with_signal_handlers
        return yield if @signal_checker

        previous = {
          "INT" => Signal.trap("INT") { @received_signal ||= 130 },
          "TERM" => Signal.trap("TERM") { @received_signal ||= 143 }
        }
        yield
      ensure
        previous&.each { |signal, handler| Signal.trap(signal, handler) }
      end

      def semantic_fingerprint(targets)
        ::Digest::SHA256.hexdigest(JSON.generate(targets))
      end

      def event_payload(event, sequence, targets, reason: nil, message: nil, ok: true)
        raise ArgumentError, "unknown watch event reason: #{reason}" if reason && !EVENT_REASONS.include?(reason)

        {
          "schema" => "hive-watch-event",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-watch-event"),
          "ok" => ok,
          "event" => event,
          "sequence" => sequence,
          "observed_at" => @clock.now.utc.iso8601,
          "reason" => reason,
          "message" => message,
          "selected_count" => @selection&.size || 0,
          "targets" => targets
        }
      end

      def emit_final(reason, targets, sequence, ok: true, message: nil)
        emit(event_payload("final", sequence, targets, reason: reason, message: message, ok: ok))
      end

      def emit(payload)
        line = @json_lines ? JSON.generate(payload) : human_line(payload)
        @output.puts(line)
        @output.flush if @output.respond_to?(:flush)
      rescue Errno::EPIPE
        throw EPIPE_TAG
      end

      def human_line(payload)
        header = "[#{payload.fetch('sequence')}] #{payload.fetch('event').upcase}"
        header += " — #{payload.fetch('reason')}" if payload["reason"]
        header += ": #{payload.fetch('message')}" if payload["message"]
        rows = payload.fetch("targets").map do |target|
          state = target.fetch("present") ? target["state"] : "missing"
          owner = target["blocker_owner"] || "unknown"
          reason = target["reason"] || "status reason unavailable"
          "  #{target.fetch('target')} · #{state} · #{owner} — #{reason}"
        end
        ([ header ] + rows).map { |line| Hive::TerminalText.escape(line) }.join("\n")
      end
    end
  end
end
