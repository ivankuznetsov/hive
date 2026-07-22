require "digest"
require "json"
require "shellwords"
require "hive"
require "hive/bot/format"
require "hive/bot/row_actions"
require "hive/bot/title_formatter"
require "hive/markers"
require "hive/task_action"
require "hive/workflows"

module Hive
  module Bot
    module NotificationBuilders
      module_function

      READY_ACTIONS = Hive::TaskAction::READY_COMMANDS.keys.freeze

      INPUT_ACTIONS = %w[
        needs_input
        recover_execute
        recover_review
        error
      ].freeze

      SKIP_ACTIONS = %w[
        agent_running
        archived
      ].freeze

      TELEGRAM_MESSAGE_MAX_CHARS = 4096
      DETAILS_TRUNCATION_MARKER = "\n... [truncated]".freeze

      # Soft-degrade replies shared across every Show-details surface (the
      # inline button, the /details and /autofix slash commands, and the
      # /status <slug> intercept). Promoted to shared frozen constants so a
      # future wording change stays in lockstep and can't drift between the
      # lookup-failed and still-loading paths across the handlers.
      STATUS_LOOKUP_FAILED_REPLY = "Status lookup failed — try again in a moment.".freeze
      STATUS_STILL_LOADING_REPLY = "Status is still loading — try again in a moment.".freeze

      def build(row, logger: nil)
        return legacy_stage_dirs(row) if legacy_stage_dirs?(row)

        # `action` is the live-state signal, so SKIP_ACTIONS rows stay silent:
        #   - agent_running: a live task lock can make status report
        #     agent_running while the state file still carries a stale recovery
        #     marker from the previous run — alerting would announce a failure
        #     a retry is already clearing.
        #   - archived: the task is terminal; there is nothing left to announce.
        if SKIP_ACTIONS.include?(row.action)
          # Only log the live-vs-stale-marker contradiction — a recovery/error
          # marker on a row whose live status reports as agent_running/archived.
          # That contradiction is what this suppression must keep diagnosable
          # (see wiki/log.d/20260624T184142Z-telegram-live-agent-suppression.md):
          # the alert is silenced, so the skip log is the only audit trail of a
          # stale marker hidden behind a live lock. A healthy `agent_working`
          # live agent or a normal terminal `archived` (9-done) row is NOT a
          # contradiction; logging those on every poll tick (default 30s,
          # operator-tunable down to a 5s floor) would flood the audit JSONL
          # with non-events and dilute the stale-marker signal. For these rows
          # `recovery?` reduces to the marker check: `row.action` is
          # agent_running/archived here, so recovery?'s action clause
          # (recover_execute/recover_review/error) can never match and only its
          # recovery/error marker test can be true.
          if recovery?(row)
            logger&.event(:notification_skipped_live_agent,
                          project: row.project, slug: row.slug, stage: row.stage,
                          marker: row.marker, action: row.action)
          end
          return nil
        end

        if READY_ACTIONS.include?(row.action)
          stage_approval(row)
        elsif row.action == Hive::Schemas::TaskActionKind::NEEDS_INPUT
          needs_input(row)
        elsif recovery?(row)
          recovery(row, logger: logger)
        else
          nil
        end
      end

      def legacy_stage_dirs?(row)
        row.respond_to?(:legacy_stage_dirs) && row.action.to_s == "legacy_stage_dirs"
      end

      def legacy_stage_dirs(row)
        command = legacy_migrate_command(row)
        total = row.total_task_count
        noun = total == 1 ? "task" : "tasks"
        dirs = row.stage_dir_names.join(", ")
        Notification.new(
          text: "Project #{row.project} has #{total} #{noun} hidden in legacy stage dirs (#{dirs}) - " \
                "run `#{command}`",
          keyboard: nil
        )
      end

      def legacy_migrate_command(row)
        command = row.legacy_migrate_command.to_s
        project_path = row.project_path.to_s
        argv = command.empty? ? %w[hive migrate] : Shellwords.split(command)
        argv << project_path unless project_path.empty?
        Shellwords.join(argv)
      rescue ArgumentError
        [ "hive migrate", Shellwords.escape(project_path) ].reject(&:empty?).join(" ")
      end

      def fingerprint(row)
        return legacy_stage_dirs_fingerprint(row) if legacy_stage_dirs?(row)

        ::Digest::SHA256.hexdigest(JSON.generate([ row.project, row.slug, row.stage, row.marker, sorted_attr_pairs(row) ]))
      end

      # Sorted [key, value] pairs of a row's attrs with stringified keys — the
      # single basis for both the fingerprint payload and the `key=value`
      # attr strings rendered in details/marker copy, so the three call sites
      # can't drift in ordering or key normalization.
      def sorted_attr_pairs(row)
        row.attrs.to_h.transform_keys(&:to_s).to_a.sort_by(&:first)
      end

      def legacy_stage_dirs_fingerprint(row)
        ::Digest::SHA256.hexdigest(JSON.generate([ row.project, row.slug, row.stage, row.marker ]))
      end

      def recovery?(row)
        %w[recover_execute recover_review error].include?(row.action) ||
          %w[review_error review_stale review_ci_stale execute_stale error].include?(row.marker)
      end

      def stage_approval(row)
        verb = verb_for_action(row.action)
        return nil unless verb

        text, parse_mode = approval_body(row, verb)
        Notification.new(
          text: text,
          keyboard: [
            [ button("Approve", "approve:#{verb}:#{row.project}:#{row.slug}:#{row.stage}") ],
            [ button("Reject", "reject:#{row.project}:#{row.slug}") ]
          ],
          parse_mode: parse_mode
        )
      end

      # Returns [text, parse_mode] for a stage-approval notification. A
      # `ready_for_review` row whose PR URL builds a valid link gets an HTML
      # body with a clickable PR link (parse_mode :html); every other row —
      # including a review row whose PR link can't be built — gets the plain
      # text body with no parse_mode.
      def approval_body(row, verb)
        header = header(row)
        if row.action.to_s == "ready_for_review"
          pr_link = Hive::Bot::Format.html_pr_link(row.pr_url)
          if pr_link
            html = "#{Hive::Bot::Format.html_escape(header)}\n" \
                   "Ready for #{Hive::Bot::Format.html_escape(verb)}.\n" \
                   "PR: #{pr_link}"
            return [ html, :html ]
          end
        end

        [ "#{header}\nReady for #{verb}.", nil ]
      end

      def needs_input(row)
        resolution = Hive::Bot::RowActions.resolve(row)
        return nil if resolution.suppress
        return nil if resolution.actions.empty?

        # Dispatch on the resolver's declared surface kind, not on the exact
        # role array. The role-array match silently fell through to the
        # neutral default whenever RowActions reordered or added an action;
        # the kind tag makes the intended surface explicit.
        case resolution.kind
        when :brainstorm_waiting
          brainstorm_waiting(row, actions: resolution.actions)
        when :plan_waiting
          plan_waiting(row, actions: resolution.actions)
        when :review_waiting
          review_waiting(row, actions: resolution.actions)
        when :execute_waiting
          execute_waiting(row, actions: resolution.actions)
        when :finalize_waiting
          finalize_waiting(row, actions: resolution.actions)
        when :generic_needs_input
          default_needs_input(row, actions: resolution.actions)
        else
          # A catch-all `else default_needs_input` would silently re-route a new
          # needs_input KIND to the generic copy — the exact misroute the kind
          # tag exists to prevent. Fail loud instead: every needs_input surface
          # must be wired explicitly here.
          raise ArgumentError,
                "needs_input received an unexpected resolution kind #{resolution.kind.inspect} " \
                "(RowActions.resolve must map every needs_input row to a known surface)"
        end
      end

      # Coding-workflow `waiting`/`review_waiting` classifications used by the
      # Show-details hint (details_hint), so tap-time copy mirrors the
      # push-notification surfaces and the two trees can't drift after a future
      # stage/marker change. Each predicate re-checks the marker itself (not
      # just the stage implied by the caller); keep that marker check when
      # editing so the two trees stay aligned across whatever rows a future
      # caller routes through here.
      def plan_pause?(row)
        Hive::Workflows.coding_row?(row) && row.stage.to_s == "3-plan" && row.marker.to_s == "waiting" # coding-scoped: plan approval pause only exists in coding workflow
      end

      def brainstorm_qna?(row)
        Hive::Workflows.coding_row?(row) && row.stage.to_s == "2-brainstorm" && row.marker.to_s == "waiting" # coding-scoped: brainstorm Q&A answer flow is coding-specific
      end

      def fix_guardrail_review?(row)
        row.marker.to_s == "review_waiting" &&
          row.attrs.to_h.transform_keys(&:to_s)["reason"].to_s == "fix_guardrail"
      end

      def default_needs_input(row, actions:)
        Notification.new(
          text: header(row) + "\nNeeds input: #{marker_with_attrs(row)}",
          keyboard: keyboard_for_actions(actions)
        )
      end

      def brainstorm_waiting(row, actions:)
        Notification.new(
          text: header(row) + "\n" \
                "Brainstorm questions are waiting. " \
                "Tap Answer in chat or reply with /answer #{row.slug} to provide input.",
          keyboard: keyboard_for_actions(actions)
        )
      end

      # A 3-plan `waiting` marker is a plan-draft/approval pause, not a
      # brainstorm Q&A round. When the daemon is enabled it auto-approves
      # this and the bot suppresses the push entirely
      # (`suppress_daemon_plan_pause?`); this notification is for the
      # daemon-OFF case. The operator can now tap Approve in chat (the
      # keyboard is Approve + Details, supplied by `RowActions`) or advance
      # the draft from the CLI — either way it points at the plan, not the
      # `/answer` flow.
      def plan_waiting(row, actions:)
        Notification.new(
          text: header(row) + "\nPlan draft is ready for your review.",
          keyboard: keyboard_for_actions(actions)
        )
      end

      def review_waiting(row, actions:)
        if fix_guardrail_review?(row)
          return Notification.new(
            text: header(row) + "\nReview fix guardrail tripped: #{marker_with_attrs(row)}",
            keyboard: keyboard_for_actions(actions)
          )
        end

        Notification.new(
          text: header(row) + "\nReview triage is waiting.",
          keyboard: keyboard_for_actions(actions)
        )
      end

      def execute_waiting(row, actions:)
        Notification.new(
          text: header(row) + "\nExecute paused — needs your input.",
          keyboard: keyboard_for_actions(actions)
        )
      end

      def finalize_waiting(row, actions:)
        Notification.new(
          text: header(row) + "\nFinalize paused — ready to run.",
          keyboard: keyboard_for_actions(actions)
        )
      end

      def recovery(row, logger: nil)
        retryable = retryable_recovery?(row)
        Notification.new(
          text: [
            "⚠ #{TitleFormatter.stage_label(row.stage, logger: logger)} stuck — \"#{display_title(row)}\"",
            cause_sentence_for(row),
            retryable ? "Tap Autofix to retry the stage cleanly." :
              "Tap Show details to see what needs manual intervention."
          ].join("\n"),
          keyboard: recovery_keyboard(row, retryable: retryable)
        )
      end

      def recovery_keyboard(row, retryable:)
        if retryable
          [ [ button("🔧 Autofix", autofix_callback(row)) ] ]
        else
          [
            [ button("Show details", details_callback(row)) ]
          ]
        end
      end

      def autofix_callback(row)
        parts = [ "autofix", row.project, row.slug, row.stage, row.marker ]
        match_attr = recovery_match_attr(row)
        parts << match_attr if match_attr
        # Thread the workflow id so RecoverySequence routes a generic row to the
        # universal `hive run` verb instead of the coding retry-verb table (slash
        # /autofix and web recover already thread it). Coding is the nil default
        # (coding_row? ⟹ true), so it's omitted to save callback bytes; a
        # non-coding id is appended as a trailing token. The recovery handler
        # disambiguates it from match_attr by content — match_attr always
        # contains `=`, a workflow id never does.
        parts << row.workflow if row.respond_to?(:workflow) && !Hive::Workflows.coding_row?(row)
        parts.join(":")
      end

      def retryable_recovery?(row)
        return false if manual_only_recovery?(row)

        suggested = suggested_next_action(row)
        suggested && suggested["kind"].to_s == "retry"
      end

      # Markers that are ALWAYS manual-only regardless of attrs. Adding a new
      # marker here automatically narrows both the in-row recovery check
      # (manual_only_recovery?) and the recover-sequence dispatch guard
      # (RecoverySequence.build, used by the inline Autofix button and the
      # /autofix slash command) — they share this constant through
      # manual_only? below.
      ALWAYS_MANUAL_MARKERS = %w[execute_stale].freeze

      # Review fix-phase reasons whose recovery requires a human. A retry
      # would only clear REVIEW_ERROR and re-enter the same unsafe state.
      REVIEW_ERROR_MANUAL_ONLY_REASONS = %w[fix_status_check_failed fix_tampered].freeze

      # Error-marker reasons whose recovery requires a human (the runner
      # can't auto-clear them via the standard markers-clear + retry-verb
      # loop). `dirty_worktree` is the legacy finalize reason — kept
      # listed so any in-flight error files still get the right routing.
      # `ensure_clean_on_exit_failed` is the new
      # `stages.ensure_clean_on_exit` plan reason: residue out of scope,
      # or the auto-commit itself failed (sign-policy / git error).
      #
      # NOTE: this is the OPERATOR-FACING (bot/TUI) classification, kept as
      # the post-exhaustion backstop. The daemon's StaleAgentHealer retries
      # `ensure_clean_on_exit_failed` automatically first (bounded, then
      # parks); only once those retries are spent does an operator see this
      # "inspect manually" routing — at which point human eyes are warranted.
      ERROR_MANUAL_ONLY_REASONS = %w[
        dirty_worktree ensure_clean_on_exit_failed
      ].concat(Hive::DraftPrReceipt::ERROR_REASONS).freeze

      # Single source of truth for "this state has no auto-recovery".
      # Pass attrs: nil from callers that only have the marker name
      # (e.g. callback handlers); pass row.attrs from in-process checks
      # where the full attrs hash is available.
      def manual_only?(marker:, attrs: nil)
        marker = marker.to_s.downcase
        return true if ALWAYS_MANUAL_MARKERS.include?(marker)
        return false if attrs.nil?

        attrs = attrs.to_h.transform_keys(&:to_s)
        return true if marker == "review_error" && attrs["phase"] == "fix" && REVIEW_ERROR_MANUAL_ONLY_REASONS.include?(attrs["reason"].to_s)
        return true if marker == "error" && ERROR_MANUAL_ONLY_REASONS.include?(attrs["reason"].to_s)

        false
      end

      # Returns the operator-facing reply text for a manual-only state.
      # The default ("open it on a laptop") covers `execute_stale` and
      # the rare attrs-gated review_error/fix_tampered case; dirty-
      # worktree variants get a more actionable hint that names the
      # right repair step.
      def manual_only_reply(marker:, attrs: nil)
        marker = marker.to_s.downcase
        attrs = attrs ? attrs.to_h.transform_keys(&:to_s) : {}
        if marker == "review_error" && attrs["reason"].to_s == "fix_status_check_failed"
          "Hive can't auto-recover a worktree whose Git status cannot be read. Open the worktree, repair Git state, then rerun review."
        elsif marker == "error" && attrs["reason"].to_s == Hive::DraftPrReceipt::RECOVERABLE_REASON
          "Hive preserved the validated branch. Run the task manually to reconcile the remote draft-PR handoff."
        elsif marker == "error" && attrs["reason"].to_s == Hive::DraftPrReceipt::QUARANTINE_REASON
          "Hive blocked publication after finding prohibited local content. Inspect and securely clean the preserved isolated worktree."
        elsif marker == "error" && attrs["reason"].to_s == Hive::DraftPrReceipt::IDENTITY_REASON
          "Hive blocked publication because repository, branch, or PR identity changed. Inspect the preserved local and remote state."
        elsif marker == "error" && attrs["reason"].to_s == Hive::DraftPrReceipt::AGENT_BLOCKED_REASON
          "The mapped repair agent reported a blocked outcome. Inspect its preserved report and isolated worktree."
        elsif marker == "error" && ERROR_MANUAL_ONLY_REASONS.include?(attrs["reason"].to_s)
          "Hive can't auto-recover a dirty worktree. Open the worktree and commit or discard the changes, then tap Autofix."
        else
          "Hive has no automatic recovery for this state - open it on a laptop."
        end
      end

      def manual_only_recovery?(row)
        manual_only?(marker: row.marker, attrs: row.attrs)
      end

      def suggested_next_action(row)
        diagnostic = row.respond_to?(:diagnostic) ? row.diagnostic : nil
        return nil unless diagnostic.is_a?(Hash)

        suggested = diagnostic["suggested_next_action"]
        suggested.is_a?(Hash) ? suggested : nil
      end

      def details_summary(row)
        attrs = sorted_attr_pairs(row).map { |key, value| "#{key}=#{value}" }
        # The renderer only ever receives a real StatusWatcher::Row (stale
        # buttons resolve against the live snapshot), so read the core members
        # (action/action_label/marker, plus stage/project/slug below) directly
        # here. This is NOT a license to strip the respond_to? guards in the
        # sibling hint helpers (next_step_hint/diagnostic_detail/present_value):
        # those guard genuinely optional, nil-by-default fields and normalize
        # their absence — keep them guarded.
        action = row.action_label.to_s.empty? ? row.action : row.action_label
        marker = row.marker.to_s.empty? ? "none" : row.marker
        [
          "#{display_title(row)} — #{row.project}/#{row.slug} (#{row.stage})",
          "Action: #{action}",
          "Marker: #{marker}",
          ("Attrs: #{attrs.join(' ')}" unless attrs.empty?)
        ].compact.join("\n")
      end

      def details_reply(row)
        # details_summary / details_hint always return non-nil strings, so the
        # array needs no compaction; diagnostic_detail may be nil, so only that
        # tail is compacted before joining.
        sections = [ details_summary(row), details_hint(row) ]
        diagnostic = diagnostic_detail(row)
        text = (sections + [ diagnostic&.text ].compact).join("\n\n")
        return text if text.length <= TELEGRAM_MESSAGE_MAX_CHARS
        return truncate_diagnostic_reply(sections, diagnostic, text) if diagnostic

        truncate_text(text)
      end

      def recovery_match_attr(row)
        attrs = row.attrs.to_h.transform_keys(&:to_s)
        keys = case row.marker.to_s.downcase
        when "review_error", "review_ci_stale"
                 %w[pass phase reason]
        when "review_stale"
                 %w[pass reason]
        when "error"
                 return Hive::Markers.error_recovery_match_attr(attrs)
        else
                 []
        end
        key = keys.find { |candidate| !attrs[candidate].to_s.empty? }
        key ? "#{key}=#{attrs[key]}" : nil
      end

      def cause_sentence_for(row)
        case row.marker.to_s.downcase
        when "review_error"
          if row.attrs.to_h.transform_keys(&:to_s)["reason"].to_s == "reviewer_partial_failure"
            "Some reviewers failed; the reviewers that ran found nothing, so review coverage is incomplete."
          else
            "The review agent crashed before it could finish."
          end
        when "execute_stale"
          "The execute agent stalled before it could finish."
        when "review_stale", "review_ci_stale"
          "The review run stalled before it could finish."
        else
          "The agent crashed before it could finish."
        end
      end

      def header(row)
        "#{display_title(row)} — #{TitleFormatter.stage_label(row.stage)}"
      end

      def display_title(row)
        name = row.respond_to?(:display_name) ? row.display_name.to_s.strip : ""
        id = row.respond_to?(:id) ? row.id : nil
        if !name.empty? && id
          "##{id} #{name}"
        elsif !name.empty?
          name
        else
          TitleFormatter.title_from_slug(row.slug)
        end
      end

      def marker_with_attrs(row)
        attrs = sorted_attr_pairs(row).map { |key, value| "#{key}=#{value}" }.join(" ")
        attrs.empty? ? row.marker : "#{row.marker} #{attrs}"
      end

      def details_hint(row)
        if plan_pause?(row)
          plan = present_value(row, :state_file)
          folder = present_value(row, :folder)
          plan ||= File.join(folder, "plan.md") if folder
          # Only name the draft when a path actually resolves. The File.join
          # above is guarded by `if folder`, so with neither a state_file nor a
          # folder `plan` simply stays nil — we drop the line rather than point
          # the operator at a path we couldn't build.
          return [ ("Plan draft: #{plan}" if plan), "Approve when ready with /approve #{row.slug}." ].compact.join("\n")
        end

        if recovery?(row) && manual_only_recovery?(row)
          folder = present_value(row, :folder)
          lines = [
            cause_sentence_for(row),
            manual_only_reply(marker: row.marker, attrs: row.attrs)
          ]
          lines << "Logs/artifacts: #{folder}" if folder
          return lines.join("\n")
        end

        return "Open on a laptop to inspect the fix before continuing." if fix_guardrail_review?(row)

        return "Reply /answer #{row.slug} to provide input." if brainstorm_qna?(row)

        next_step_hint(row) || "Open on a laptop to advance."
      end

      # Precedence: the structured next_action["command"] wins over the flat
      # suggested_command; the flat field is consulted only when the structured
      # command is blank. A "-" sentinel (or a blank) yields no hint.
      def next_step_hint(row)
        next_action = row.respond_to?(:next_action) ? row.next_action : nil
        command = next_action.is_a?(Hash) ? next_action["command"] : nil
        command = present_value(row, :suggested_command) if command.to_s.strip.empty?
        command = command.to_s.strip
        return nil if command.empty? || command == "-"

        "Next step: #{command}"
      end

      # A rendered diagnostic with its summary and detail kept structurally
      # separate, so the truncation path can keep the summary intact and trim
      # only the detail without a lossy join-then-resplit. `text` is the
      # untruncated rendering used on the happy path.
      Diagnostic = Data.define(:summary, :detail) do
        # Coerce members at the type boundary so `summary`/`detail` are always
        # strings and `#text`'s reject(&:empty?) can't NoMethodError on a nil
        # member. Sibling Notification also validates in initialize, but it
        # *raises* on a bad parse_mode; this type *coerces* instead — lenient on
        # purpose, since a render-path type must never crash a reply.
        def initialize(summary:, detail:)
          super(summary: summary.to_s, detail: detail.to_s)
        end

        def text
          [ summary, detail ].reject(&:empty?).join("\n")
        end
      end

      def diagnostic_detail(row)
        diagnostic = row.respond_to?(:diagnostic) ? row.diagnostic : nil
        return nil unless diagnostic.is_a?(Hash) && !diagnostic.empty?

        summary = diagnostic["summary"].to_s.strip
        detail = diagnostic["detail"].to_s.strip
        return nil if summary.empty? && detail.empty?

        Diagnostic.new(summary: summary, detail: detail)
      end

      # `full_text` is the untruncated reply details_reply already composed
      # ((sections + [diagnostic.text]).join); both whole-text fallbacks reuse
      # it instead of recomposing the join. `sections` (details_summary +
      # details_hint) are always non-empty, so the only blank reject(&:empty?)
      # can drop is a summary-less diagnostic — hence it guards only summary.
      def truncate_diagnostic_reply(sections, diagnostic, full_text)
        return truncate_text(full_text) if diagnostic.detail.empty?

        prefix = (sections + [ diagnostic.summary ].reject(&:empty?)).join("\n\n")
        available = TELEGRAM_MESSAGE_MAX_CHARS - prefix.length - 1 - DETAILS_TRUNCATION_MARKER.length
        return truncate_text(full_text) unless available.positive?

        truncated_detail = diagnostic.detail[0, available].to_s.rstrip + DETAILS_TRUNCATION_MARKER
        [ prefix, truncated_detail ].join("\n")
      end

      def truncate_text(text)
        limit = TELEGRAM_MESSAGE_MAX_CHARS - DETAILS_TRUNCATION_MARKER.length
        text[0, limit].to_s.rstrip + DETAILS_TRUNCATION_MARKER
      end

      def present_value(row, key)
        return nil unless row.respond_to?(key)

        value = row.public_send(key).to_s.strip
        value.empty? ? nil : value
      end

      def details_callback(row)
        callback_with_stage("details", row)
      end

      def keyboard_for_actions(actions)
        actions = Array(actions)
        buttons = actions.map { |action| button(label_for_action(action), action.callback) }
        if actions.first(2).map(&:role) == [ :findings_accept, :findings_reject ]
          # Review triage: Accept all / Reject all share the top row; any
          # trailing action (Show details) stacks one-per-row beneath them.
          return [ buttons.first(2), *buttons.drop(2).map { |btn| [ btn ] } ]
        end

        buttons.map { |btn| [ btn ] }
      end

      def label_for_action(action)
        return rerun_label(action.verb) if action.role == :rerun

        {
          answer: "Answer in chat",
          approve: "Approve",
          approve_plan: "Approve",
          findings_accept: "Accept all",
          findings_reject: "Reject all",
          autofix: "🔧 Autofix",
          details: "Show details"
        }.fetch(action.role)
      end

      # A paused-stage re-run button reuses the single `:rerun` role for every
      # verb. The label is chosen purely lexically: the "develop" verb renders
      # "Re-run", every other verb (finalize, generic run) renders "Run". The
      # rule is lexical, not an execution-history claim — a "finalize" rerun is
      # only produced for a finalize agent that already ran and paused.
      def rerun_label(verb)
        verb.to_s == "develop" ? "Re-run" : "Run"
      end

      def callback_with_stage(prefix, row)
        parts = [ prefix, row.project, row.slug ]
        stage = row.respond_to?(:stage) ? row.stage.to_s : ""
        parts << stage unless stage.empty?
        parts.join(":")
      end

      def verb_for_action(action)
        Hive::TaskAction::READY_COMMANDS[action]
      end

      CALLBACK_DATA_MAX = 64
      CALLBACK_REGISTRY_TTL_SEC = 3600
      CALLBACK_REGISTRY_MAX = 2048

      def button(text, callback_data)
        { text: text, callback_data: compact_callback(callback_data) }
      end

      def compact_callback(callback_data)
        return callback_data if callback_data.bytesize <= CALLBACK_DATA_MAX

        prefix, _ = callback_data.split(":", 2)
        digest = ::Digest::SHA256.hexdigest(callback_data)[0, 16]
        prune_registry!
        registry[digest] = [ callback_data, Time.now ]
        "##{prefix}:#{digest}"
      end

      def resolve_callback(token)
        return token unless token.start_with?("#")

        _, digest = token.split(":", 2)
        entry = registry[digest]
        entry.is_a?(Array) ? entry.first : token
      end

      def registry
        @registry ||= {}
      end

      def prune_registry!
        cutoff = Time.now - CALLBACK_REGISTRY_TTL_SEC
        registry.delete_if { |_digest, entry| entry.is_a?(Array) && entry.last < cutoff }
        registry.shift while registry.size > CALLBACK_REGISTRY_MAX
      end

      # The only valid `parse_mode` values: nil = plain text, :html =
      # Telegram HTML (the one mode in which `<a>` markup renders as a link
      # rather than literal text). Enforced at construction below, so a
      # future HTML message — e.g. an `:html` recovery/reminder rebuild —
      # can't accidentally ship raw `<a>` tags as plain text (nil) nor reach
      # the Telegram API with an unsupported mode like `:markdown` (a
      # runtime 400); the failure surfaces at the call site instead.
      PARSE_MODES = [ nil, :html ].freeze

      Notification = Data.define(:text, :keyboard, :parse_mode) do
        def initialize(text:, keyboard:, parse_mode: nil)
          unless PARSE_MODES.include?(parse_mode)
            raise ArgumentError,
                  "unsupported parse_mode #{parse_mode.inspect} (expected one of #{PARSE_MODES.inspect})"
          end

          super
        end
      end
    end
  end
end
