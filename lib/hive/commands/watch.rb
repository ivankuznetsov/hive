require "digest"
require "json"
require "time"
require "hive/commands/status"
require "hive/config"
require "hive/daemon/operational_snapshot"
require "hive/operational_status"
require "hive/terminal_text"

module Hive
  module Commands
    # A bounded, read-only status observer for agents. Selection is resolved
    # once from a full task graph; subsequent polls emit only meaningful state
    # changes and never interpret a missing row as successful completion.
    class Watch
      SourceSnapshot = Data.define(:operational, :full_graph)
      Selection = Data.define(:project, :slug) do
        def target = "#{project}:#{slug}"
      end

      class UsageError < Hive::InvalidTaskPath; end
      class StatusUnavailableError < Hive::UnavailableError; end

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
          project_context = status.operational_project_context(projects)
          scheduler_snapshot = if project_context.any? { |_name, context| context["daemon_enabled"] == true }
            Hive::Daemon::OperationalSnapshot::Reader.new.read
          end
          operational = Hive::OperationalStatus.new(
            status_payload: full_graph,
            project_context: project_context,
            scheduler_snapshot: scheduler_snapshot
          ).to_h
          SourceSnapshot.new(operational: operational, full_graph: full_graph)
        end
      end

      def initialize(targets:, project: nil, until_condition: "settled",
                     timeout: DEFAULT_TIMEOUT, max_events: DEFAULT_MAX_EVENTS,
                     interval: DEFAULT_INTERVAL, json_lines: false, json: false,
                     source: nil, clock: nil, sleeper: nil, output: $stdout,
                     signal_checker: nil)
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
        snapshot = initial_snapshot!
        @selection = resolve_selection(snapshot)
        current = materialize(snapshot)
        missing_counts = Hash.new(0)
        non_final_events = 0

        emit(event_payload("initial", non_final_events, current))
        non_final_events += 1
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
            next_snapshot = fetch_snapshot!
            source_failures = 0
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

          next_targets = materialize(next_snapshot)
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

          if semantic_fingerprint(next_targets) != semantic_fingerprint(current)
            current = next_targets
            emit(event_payload("transition", non_final_events, current))
            non_final_events += 1
          else
            current = next_targets
          end

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

      def initial_snapshot!
        fetch_snapshot!
      rescue StandardError => error
        raise StatusUnavailableError,
              "initial status source unavailable: #{error.class}: #{error.message}"
      end

      def fetch_snapshot!
        snapshot = @source.fetch
        unless snapshot.is_a?(SourceSnapshot) && snapshot.operational.is_a?(Hash) &&
               snapshot.full_graph.is_a?(Hash)
          raise TypeError, "watch source returned an invalid snapshot"
        end
        unless snapshot.operational["ok"] == true && snapshot.full_graph["ok"] == true
          raise TypeError, "watch source returned an unsuccessful status payload"
        end

        snapshot
      end

      def resolve_selection(snapshot)
        candidates = candidate_index(snapshot)
        selected = if @targets.empty?
          candidates.values
                    .select { |entry| entry.fetch(:project) == @project && !entry.fetch(:archived) }
                    .sort_by { |entry| entry.fetch(:target) }
                    .map { |entry| Selection.new(project: entry.fetch(:project), slug: entry.fetch(:slug)) }
        else
          @targets.map { |target| resolve_target(target, candidates, snapshot) }
        end
        selected = selected.uniq { |entry| entry.target }

        if selected.empty?
          if @targets.empty? && !known_project?(snapshot, @project)
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
          entry = candidates[target]
          return Selection.new(project: project, slug: slug) if entry

          return missing_target!(target, snapshot)
        end

        matches = candidates.values.select do |entry|
          entry.fetch(:slug) == target && (@project.nil? || entry.fetch(:project) == @project)
        end
        if matches.size > 1
          alternatives = matches.map { |entry| entry.fetch(:target) }.sort
          raise UsageError,
                "ambiguous target #{target.inspect}; use one of: #{alternatives.join(', ')}"
        end
        return Selection.new(project: matches[0].fetch(:project), slug: target) if matches.one?

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
        index = {}
        Array(snapshot.full_graph["projects"]).each do |project|
          Array(project["tasks"]).each do |row|
            project_name = row["project"] || project["name"]
            slug = row["slug"]
            next if project_name.to_s.empty? || slug.to_s.empty?

            target = "#{project_name}:#{slug}"
            index[target] = {
              target: target, project: project_name, slug: slug,
              archived: row["action"] == "archived"
            }
          end
        end
        Array(snapshot.operational["tasks"]).each do |row|
          project_name = row.dig("identity", "project")
          slug = row.dig("identity", "slug")
          next if project_name.to_s.empty? || slug.to_s.empty?

          target = "#{project_name}:#{slug}"
          index[target] = { target: target, project: project_name, slug: slug, archived: false }
        end
        index
      end

      def known_project?(snapshot, project_name)
        Array(snapshot.full_graph["projects"]).any? { |project| project["name"] == project_name } ||
          candidate_index(snapshot).values.any? { |entry| entry.fetch(:project) == project_name }
      end

      def materialize(snapshot)
        active = Array(snapshot.operational["tasks"]).to_h do |row|
          [ [ row.dig("identity", "project"), row.dig("identity", "slug") ], row ]
        end
        archived = {}
        Array(snapshot.full_graph["projects"]).each do |project|
          Array(project["tasks"]).each do |row|
            next unless row["action"] == "archived"

            project_name = row["project"] || project["name"]
            archived[[ project_name, row["slug"] ]] = row
          end
        end

        @selection.map do |selection|
          key = [ selection.project, selection.slug ]
          if active[key]
            active_target(selection, active.fetch(key))
          elsif archived[key]
            archived_target(selection, archived.fetch(key))
          else
            absent_target(selection)
          end
        end
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
        Digest::SHA256.hexdigest(JSON.generate(targets))
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
