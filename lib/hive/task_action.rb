require "shellwords"
require "digest"
require "time"
require "yaml"
require "hive/execute_waiting_action"
require "hive/agent_profiles"
require "hive/secret_patterns"
require "hive/stages"
require "hive/workflows"

module Hive
  # Classifier that turns a (Task, Marker) pair into a user-facing
  # action: a stable key (matching `Hive::Schemas::TaskActionKind`),
  # a human label for `hive status` output, and a copy-paste-executable
  # `command` string for the next step.
  #
  # Used by `hive status` (per-row action grouping) and by
  # `hive run` / `hive approve` / `hive accept-finding` JSON
  # `next_action` emission.
  class TaskAction
    DIAGNOSTIC_SUMMARY_MAX = 120
    DIAGNOSTIC_DETAIL_MAX = 4_000
    DIAGNOSTIC_TAIL_BYTES = 8_192
    # Cap on artifact_paths reported in the diagnostic payload. The schema
    # pins maxItems=20; this constant is the producer-side enforcement so
    # a marker with hundreds of matching artifacts (legacy reviews/ dirs)
    # cannot blow past the contract.
    ARTIFACT_PATHS_MAX = 20
    # Cap on .log files probed per task per status invocation. Bounds the
    # File.mtime cost when a task accumulated many agent-run logs over a
    # long-lived branch (saw 50+ on auto-rebase test fixtures).
    LOG_GLOB_CAP = 20
    # Cap on diagnostic_frontmatter scan window. Real frontmatter is < 1KB;
    # 16KB is generous for human-written artifacts and tight enough to
    # reject a runaway file masquerading as frontmatter.
    FRONTMATTER_SCAN_BYTES = 16_384

    ACTIONS = {
      inbox: {
        key: Hive::Schemas::TaskActionKind::READY_TO_BRAINSTORM,
        label: "Ready to brainstorm",
        command: "brainstorm"
      },
      brainstorm_waiting: {
        key: Hive::Schemas::TaskActionKind::NEEDS_INPUT,
        label: "Needs your input",
        command: "brainstorm"
      },
      brainstorm_complete: {
        key: Hive::Schemas::TaskActionKind::READY_TO_PLAN,
        label: "Ready to plan",
        command: "plan"
      },
      plan_waiting: {
        key: Hive::Schemas::TaskActionKind::NEEDS_INPUT,
        label: "Needs your input",
        command: "plan"
      },
      plan_complete: {
        key: Hive::Schemas::TaskActionKind::READY_TO_DEVELOP,
        label: "Ready to develop",
        command: "develop"
      },
      execute_findings: {
        key: Hive::Schemas::TaskActionKind::REVIEW_FINDINGS,
        label: "Review findings",
        command: "findings"
      },
      execute_waiting: {
        key: Hive::Schemas::TaskActionKind::NEEDS_INPUT,
        label: "Needs your input",
        command: "develop"
      },
      execute_complete: {
        key: Hive::Schemas::TaskActionKind::READY_TO_OPEN_PR,
        label: "Ready to open PR",
        command: "open-pr"
      },
      open_pr_ready: {
        key: Hive::Schemas::TaskActionKind::READY_TO_OPEN_PR,
        label: "Ready to open PR",
        command: "open-pr"
      },
      open_pr_complete: {
        key: Hive::Schemas::TaskActionKind::READY_FOR_REVIEW,
        label: "Ready for review",
        command: "review"
      },
      execute_stale: {
        # Recovery path: the user must edit reviews/, lower task.md
        # frontmatter `pass:`, remove the EXECUTE_STALE marker, then
        # re-run. There is no single command that recovers; the closest
        # agent-callable step is reviewing the findings and toggling
        # accept-finding so the next run sees a smaller accepted set.
        key: Hive::Schemas::TaskActionKind::RECOVER_EXECUTE,
        label: "Needs recovery",
        command: "findings"
      },
      review_waiting: {
        key: Hive::Schemas::TaskActionKind::NEEDS_INPUT,
        label: "Needs your input",
        command: "review"
      },
      review_ready: {
        key: Hive::Schemas::TaskActionKind::READY_FOR_REVIEW,
        label: "Ready for review",
        command: "review"
      },
      review_complete: {
        key: Hive::Schemas::TaskActionKind::READY_TO_FINALIZE,
        label: "Ready to finalize",
        command: "finalize"
      },
      review_stale: {
        key: Hive::Schemas::TaskActionKind::RECOVER_REVIEW,
        label: "Needs recovery",
        command: nil
      },
      finalize_waiting: {
        key: Hive::Schemas::TaskActionKind::NEEDS_INPUT,
        label: "Needs your input",
        command: "finalize"
      },
      finalize_complete: {
        key: Hive::Schemas::TaskActionKind::READY_TO_ARCHIVE,
        label: "Ready to archive",
        command: "archive"
      },
      done: {
        key: Hive::Schemas::TaskActionKind::ARCHIVED,
        label: "Archived",
        command: nil
      },
      agent_running: {
        # Marker is `:agent_working` — a `hive run` is in flight. Surfacing
        # a workflow command here would send the user (or an agent loop)
        # straight into ConcurrentRunError on every retry. The right
        # action is wait-and-watch.
        key: Hive::Schemas::TaskActionKind::AGENT_RUNNING,
        label: "Agent running",
        command: nil
      },
      error: {
        key: Hive::Schemas::TaskActionKind::ERROR,
        label: "Error",
        command: nil
      }
    }.freeze

    attr_reader :task, :marker, :project_name

    def initialize(task, marker, project_name: nil, project_count: 1, stage_collision: false)
      @task = task
      @marker = marker
      @project_name = project_name
      @project_count = project_count
      @stage_collision = stage_collision
    end

    def self.for(task, marker, **)
      new(task, marker, **)
    end

    def key
      action[:key]
    end

    def label
      action[:label]
    end

    # Returns a copy-paste-executable shell command, or nil for actions
    # whose state requires manual recovery (agent_running, archived, error).
    #
    # Workflow-verb commands ALWAYS include `--from <stage>`: that's the
    # idempotency lever — a retry after a successful advance fails with
    # WRONG_STAGE (4) instead of silently advancing twice. Generic verbs
    # (findings/accept-finding/reject-finding) only include `--stage`
    # when slug-stage ambiguity actually exists.
    def command
      verb = action[:command]
      return nil unless verb

      parts = [ "hive", verb, task.slug ]
      parts.concat([ "--project", project_name ]) if project_name && @project_count > 1
      parts.concat([ from_or_stage_option(verb), stage_dir ]) if include_stage_filter?(verb)
      parts.shelljoin
    end

    def payload
      {
        "key" => key,
        "label" => label,
        "command" => command,
        "next_action" => next_action
      }
    end

    private

    def action
      # `:agent_working` overrides every (stage, marker) pair — a live
      # agent run on the task pre-empts whatever workflow advice the
      # state-machine would otherwise produce.
      return ACTIONS.fetch(:agent_running) if marker.name == :agent_working
      return ACTIONS.fetch(:error) if marker.name == :error

      case task.stage_name
      when "inbox"
        ACTIONS.fetch(:inbox)
      when "brainstorm"
        marker.name == :complete ? ACTIONS.fetch(:brainstorm_complete) : ACTIONS.fetch(:brainstorm_waiting)
      when "plan"
        marker.name == :complete ? ACTIONS.fetch(:plan_complete) : ACTIONS.fetch(:plan_waiting)
      when "execute"
        execute_action
      when "open-pr"
        marker.name == :complete ? ACTIONS.fetch(:open_pr_complete) : ACTIONS.fetch(:open_pr_ready)
      when "review"
        review_action
      when "finalize"
        marker.name == :complete ? ACTIONS.fetch(:finalize_complete) : ACTIONS.fetch(:finalize_waiting)
      when "done"
        ACTIONS.fetch(:done)
      else
        ACTIONS.fetch(:error)
      end
    end

    def review_action
      case marker.name
      when :review_complete
        ACTIONS.fetch(:review_complete)
      when :review_stale, :review_ci_stale, :review_error
        ACTIONS.fetch(:review_stale)
      when :review_working
        # The review stage's own in-flight marker. Without this branch
        # the row falls through to :review_waiting and emits a
        # runnable `hive review … --from 6-review` command while review
        # is already active — running it would acquire-then-fail the
        # per-task lock with ConcurrentRunError. Treat it as in-flight
        # via the same :agent_running surface other stages use for
        # `:agent_working`. The TUI's verb-refusal flash + log-tail-on-
        # Enter path then kicks in for review-stage rows too.
        ACTIONS.fetch(:agent_running)
      when :review_waiting
        ACTIONS.fetch(:review_waiting)
      else
        ACTIONS.fetch(:review_ready)
      end
    end

    def execute_action
      case marker.name
      when :execute_complete
        ACTIONS.fetch(:execute_complete)
      when :execute_stale
        ACTIONS.fetch(:execute_stale)
      when :execute_waiting
        if marker.attrs["findings_count"].to_i.positive?
          ACTIONS.fetch(:execute_findings)
        else
          ACTIONS.fetch(:execute_waiting)
        end
      else
        ACTIONS.fetch(:execute_waiting)
      end
    end

    public

    def diagnostic
      return nil unless diagnostic_action?

      artifacts = diagnostic_artifacts.select { |path| path && File.exist?(path) }
      primary = artifacts.first
      updated_at = diagnostic_updated_at(primary)
      detail = primary ? artifact_detail(primary) : marker_detail
      generator = diagnostic_generated_by(primary)

      {
        "summary" => redact(truncate(marker_summary, DIAGNOSTIC_SUMMARY_MAX)),
        "detail" => redact(truncate(detail, DIAGNOSTIC_DETAIL_MAX)),
        "source" => primary ? "artifact" : "marker",
        "source_path" => primary,
        "artifact_paths" => artifacts.uniq.first(ARTIFACT_PATHS_MAX),
        "generated_by" => generator,
        "marker_signature" => marker_signature,
        "suggested_next_action" => suggested_next_action_payload,
        "updated_at" => updated_at.utc.iso8601
      }
    end

    def next_action
      return nil unless execute_waiting_input?

      Hive::ExecuteWaitingAction.build(task, marker, rerun_with: command)
    end

    private

    # recover_execute rows are deliberately excluded: TUI red_detail_row?
    # has no rendering branch for them (no "what next?" answer text, no
    # autofix wiring), so emitting a diagnostic for every execute_stale
    # row on every poll would pay the file-I/O cost with no consumer.
    # Re-add to this list when (and only when) the TUI gating predicates
    # in lib/hive/tui/key_map.rb#red_detail_row? + Update#red_status_row?
    # gain matching branches.
    def diagnostic_action?
      %w[recover_review error].include?(key.to_s)
    end

    def diagnostic_artifacts
      case marker.name
      when :review_error
        fresh_diagnosis_artifact + review_error_artifacts
      when :review_ci_stale
        fresh_diagnosis_artifact + review_ci_artifacts
      when :review_stale
        fresh_diagnosis_artifact + review_stale_artifacts
      when :error
        fresh_diagnosis_artifact + generic_error_artifacts
      else
        []
      end
    end

    def fresh_diagnosis_artifact
      path = task_artifact("diagnostics", "red-status.md")
      return [] unless File.exist?(path)

      metadata = diagnostic_frontmatter(path)
      return [] unless trusted_diagnostic_generator?(metadata["generated_by"])
      return [] unless metadata["marker_signature"].to_s == marker_signature

      [ path ]
    end

    def review_error_artifacts
      pass = pass_suffix
      phase = marker.attrs["phase"].to_s
      reason = marker.attrs["reason"].to_s
      paths = []
      paths << task_artifact("reviews", "errors-#{pass}.md") if pass
      paths << task_artifact("reviews", "fix-guardrail-#{pass}.md") if pass && reason == "fix_guardrail"
      paths << task_artifact("reviews", "escalations-#{pass}.md") if pass
      paths.concat(paths_from_marker_files)
      paths.concat(review_phase_logs(phase, pass))
      paths.concat(latest_log_artifacts)
      paths
    end

    def review_ci_artifacts
      [
        task_artifact("reviews", "ci-blocked.md"),
        *glob_task_artifacts("logs", "review-ci-fix-attempt*.log"),
        *latest_log_artifacts
      ]
    end

    def review_stale_artifacts
      pass = pass_suffix
      paths = []
      paths << task_artifact("reviews", "escalations-#{pass}.md") if pass
      paths.concat(glob_task_artifacts("reviews", "*-#{pass}.md")) if pass
      paths.concat(latest_log_artifacts)
      paths
    end

    def generic_error_artifacts
      [
        *latest_log_artifacts,
        task.state_file
      ]
    end

    def review_phase_logs(phase, pass)
      return [] unless pass

      case phase
      when "fix"
        glob_task_artifacts("logs", "review-fix-pass#{pass}*.log")
      when "triage"
        glob_task_artifacts("logs", "review-triage-pass#{pass}*.log")
      when "browser"
        glob_task_artifacts("logs", "review-browser-pass#{pass}*.log")
      when "reviewers"
        glob_task_artifacts("logs", "review-*-pass#{pass}*.log")
      else
        []
      end
    end

    def paths_from_marker_files
      marker.attrs.fetch("files", "").to_s.split(/[,\s]+/).filter_map do |relative|
        next if relative.empty? || relative.include?("..") || relative.start_with?("/")

        File.join(task.folder, relative)
      end
    end

    # Cap the candidate set (LOG_GLOB_CAP) before sorting by mtime so a
    # long-lived task with 100+ retained logs doesn't pay an O(N) stat
    # sweep on every status poll. The cap is the most recent N by
    # filename-suffix timestamp (hive's log filenames embed an ISO
    # timestamp), which is a good proxy for mtime ordering and avoids
    # the stat. Final sort-by-mtime over the capped set still produces
    # the freshest 3.
    def latest_log_artifacts
      candidates = log_dirs.flat_map { |dir| Dir[File.join(dir, "*.log")] }
      return [] if candidates.empty?

      head = candidates.sort.last(LOG_GLOB_CAP)
      head.sort_by { |path| safe_mtime(path) || Time.at(0) }.last(3).reverse
    end

    def log_dirs
      [
        (task.log_dir if task.respond_to?(:log_dir)),
        File.join(task.folder, "logs")
      ].compact.uniq
    end

    def glob_task_artifacts(*parts)
      Dir[task_artifact(*parts)]
    end

    def task_artifact(*parts)
      File.join(task.folder, *parts)
    end

    def pass_suffix
      raw = marker.attrs["pass"].to_s
      return nil unless raw.match?(/\A[1-9]\d*\z/)

      format("%02d", raw.to_i)
    end

    def marker_summary
      attrs = marker.attrs.map { |key, value| "#{key}=#{value}" }.join(" ")
      marker_name = marker.name.to_s.upcase
      attrs.empty? ? marker_name : "#{marker_name} #{attrs}"
    end

    def marker_detail
      lines = [ marker_summary ]
      lines << "No diagnostic artifact was found under #{task.folder}."
      lines.join("\n")
    end

    def artifact_detail(path)
      body = tail_file(path)
      "#{path}:\n#{body}"
    rescue SystemCallError => e
      "#{path}: #{e.class}: #{e.message}"
    end

    def tail_file(path)
      File.open(path, "rb") do |file|
        begin
          file.seek(-DIAGNOSTIC_TAIL_BYTES, IO::SEEK_END)
        rescue Errno::EINVAL
          file.rewind
        end
        file.read.to_s
      end
    end

    def diagnostic_updated_at(primary)
      safe_mtime(primary) || safe_mtime(task.state_file) || Time.now
    end

    def diagnostic_generated_by(primary)
      return "local" unless primary && File.basename(primary) == "red-status.md"

      diagnostic_frontmatter(primary)["generated_by"].to_s.tap do |value|
        return value unless value.empty?
      end
      "local"
    end

    # Scan up to FRONTMATTER_SCAN_BYTES of the artifact head looking for
    # the closing `---` boundary. A fixed 4KB head used to silently parse
    # frontmatter blocks larger than 4KB as empty (no closing match) —
    # widening the window to 16KB keeps the cost bounded while accepting
    # real-world artifact frontmatter.
    def diagnostic_frontmatter(path)
      body = File.read(path, FRONTMATTER_SCAN_BYTES)
      match = body.match(/\A---\n(.*?)\n---\n/m)
      return {} unless match

      parsed = YAML.safe_load(match[1], permitted_classes: [ Time ]) || {}
      parsed.is_a?(Hash) ? parsed.transform_keys(&:to_s) : {}
    rescue Psych::Exception, SystemCallError
      {}
    end

    def trusted_diagnostic_generator?(name)
      allowed = [ "local", *Hive::AgentProfiles.registered_names.map(&:to_s) ]
      allowed.include?(name.to_s)
    end

    public

    # Canonical freshness key for the (marker, attrs) pair. Re-used by:
    #   - this class's fresh_diagnosis_artifact (consumer side: validates
    #     diagnostics/red-status.md's frontmatter against the current
    #     marker before trusting the artifact body)
    #   - Hive::DiagnosisAgent#artifact_body (producer side: writes the
    #     signature into the artifact frontmatter at spawn time)
    #   - Hive::Tui::Update.apply_red_status_detail_snapshot (TUI live-
    #     update gate: detects marker rotation while the operator is in
    #     the red-status detail view)
    #
    # All three call this single implementation so the producer, the
    # local consumer, and the TUI freshness check can never disagree.
    # Marker attrs are coerced to String so a future non-string value
    # (Integer pass attr, Time stamp) cannot silently change the digest
    # via Hash#to_s formatting.
    def marker_signature
      attrs = marker.attrs.sort_by { |key, _value| key.to_s }
                     .map { |key, value| "#{key}=#{value}" }
      Digest::SHA256.hexdigest(([ marker.name.to_s ] + attrs).join("\n"))
    end

    private

    # Recovery hint surfaced inside the diagnostic JSON so agents and
    # external consumers don't have to re-derive the next move from
    # marker shape alone. `kind` mirrors the operator gesture:
    #   - "retry" — Enter-in-detail-view runs the existing recover_review
    #     / recover_error path (clear marker + re-run); `command` is the
    #     copy-paste shell form.
    #   - "manual_fix" — max_passes-hit REVIEW_STALE; the operator must
    #     edit `reviews/escalations-NN.md` before retry. command stays
    #     null because there's nothing safe to dispatch.
    #   - "clear_marker" — kept reserved for future expansion; not yet
    #     emitted because the in-tree heuristics route everything else
    #     through retry or manual_fix.
    def suggested_next_action_payload
      return nil unless diagnostic_action?

      if max_passes_review_stale_with_escalations?
        return { "kind" => "manual_fix", "command" => nil }
      end

      cmd = retry_command_string
      return nil if cmd.nil?

      { "kind" => "retry", "command" => cmd }
    end

    def max_passes_review_stale_with_escalations?
      return false unless marker.name == :review_stale

      pass = marker.attrs["pass"].to_s
      return false unless pass.match?(/\A[1-9]\d*\z/)

      File.exist?(File.join(task.folder, "reviews", "escalations-#{format('%02d', pass.to_i)}.md"))
    end

    # `hive markers clear` accepts a single --match-attr KEY=VALUE; pick
    # the most-identifying attr per marker shape. The recipe stays a
    # copy-pasteable one-liner so external agents (and humans) can run
    # it from a shell unchanged.
    def retry_command_string
      attrs = marker.attrs || {}
      case marker.name
      when :review_error, :review_ci_stale
        attr_pair = priority_match_attr(attrs, %w[pass phase reason])
        clear_argv = [ "hive", "markers", "clear", task.folder,
                       "--name", marker.name.to_s.upcase, *attr_pair ]
        "#{clear_argv.shelljoin} && #{[ 'hive', 'run', task.folder ].shelljoin}"
      when :review_stale
        attr_pair = priority_match_attr(attrs, %w[pass reason])
        clear_argv = [ "hive", "markers", "clear", task.folder,
                       "--name", "REVIEW_STALE", *attr_pair ]
        "#{clear_argv.shelljoin} && #{[ 'hive', 'run', task.folder ].shelljoin}"
      when :error
        attr_pair = priority_match_attr(attrs, %w[exit_code])
        clear_argv = [ "hive", "markers", "clear", task.folder,
                       "--name", "ERROR", *attr_pair ]
        "#{clear_argv.shelljoin} && #{[ 'hive', 'run', task.folder ].shelljoin}"
      end
    end

    def priority_match_attr(attrs, keys)
      keys.each do |key|
        value = attrs[key]
        return [ "--match-attr", "#{key}=#{value}" ] if value && !value.to_s.empty?
      end
      []
    end

    def safe_mtime(path)
      return nil if path.nil? || path.to_s.empty?

      File.mtime(path)
    rescue SystemCallError
      nil
    end

    def redact(text)
      output = text.to_s.dup
      Hive::SecretPatterns::PATTERNS.each do |name, regex|
        output.gsub!(regex, "[REDACTED:#{name}]")
      end
      output
    end

    def truncate(text, max)
      return text if text.length <= max

      "#{text[0, max - 1]}…"
    end

    def execute_waiting_input?
      task.stage_name == "execute" &&
        marker.name == :execute_waiting &&
        marker.attrs["findings_count"].to_i <= 0
    end

    # Workflow verbs (brainstorm/plan/develop/pr/archive) use --from for
    # the source-stage assertion; generic verbs (findings/accept-finding/
    # reject-finding) use --stage for ambiguity disambiguation.
    def from_or_stage_option(verb)
      Hive::Workflows.workflow_verb?(verb) ? "--from" : "--stage"
    end

    # Workflow verbs always carry --from for retry idempotency.
    # Generic verbs only when ambiguity demands disambiguation.
    def include_stage_filter?(verb)
      Hive::Workflows.workflow_verb?(verb) || @stage_collision
    end

    def stage_dir
      "#{task.stage_index}-#{task.stage_name}"
    end
  end
end
