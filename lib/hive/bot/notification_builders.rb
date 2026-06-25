require "digest"
require "json"
require "shellwords"
require "hive"
require "hive/bot/format"
require "hive/bot/row_actions"
require "hive/bot/title_formatter"
require "hive/markers"
require "hive/workflows"

module Hive
  module Bot
    module NotificationBuilders
      module_function

      READY_ACTIONS = %w[
        ready_to_brainstorm
        ready_to_plan
        ready_to_develop
        ready_to_open_pr
        ready_for_review
        ready_to_artifacts
        ready_to_finalize
        ready_to_archive
        ready_to_advance
        ready_to_run
      ].freeze

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

      def build(row, logger: nil)
        return legacy_stage_dirs(row) if legacy_stage_dirs?(row)

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

        normalized_attrs = row.attrs.to_h.transform_keys(&:to_s).to_a.sort_by(&:first)
        ::Digest::SHA256.hexdigest(JSON.generate([ row.project, row.slug, row.stage, row.marker, normalized_attrs ]))
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
        normalized_attrs = row.attrs.to_h.transform_keys(&:to_s)
        if normalized_attrs["reason"] == "fix_guardrail"
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
      ERROR_MANUAL_ONLY_REASONS = %w[dirty_worktree ensure_clean_on_exit_failed].freeze

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
        normalized = row.attrs.to_h.transform_keys(&:to_s)
        attrs = normalized.to_a.sort_by(&:first).map { |key, value| "#{key}=#{value}" }.join(" ")
        attrs.empty? ? row.marker : "#{row.marker} #{attrs}"
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
        {
          "ready_to_brainstorm" => "brainstorm",
          "ready_to_plan" => "plan",
          "ready_to_develop" => "develop",
          "ready_to_open_pr" => "open-pr",
          "ready_for_review" => "review",
          "ready_to_artifacts" => "artifacts",
          "ready_to_finalize" => "finalize",
          "ready_to_archive" => "archive",
          # Generic-workflow ready rows: advance promotes the task to the
          # next stage (`hive approve`), run dispatches the generic stage
          # agent (`hive run`). Without these a generic row gets no Telegram
          # button and a daemon-disabled project can't drive it from chat.
          "ready_to_advance" => "approve",
          "ready_to_run" => "run"
        }[action]
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
