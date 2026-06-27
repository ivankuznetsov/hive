require "hive/bot/notification_builders"
require "hive/bot/row_actions"

module Hive
  module Bot
    module WaitingRows
      module_function

      NEEDS_INPUT_KINDS = %i[
        brainstorm_waiting
        plan_waiting
        review_waiting
        execute_waiting
        finalize_waiting
        generic_needs_input
      ].freeze

      URGENCY_RANK = {
        review_waiting: 0,
        brainstorm_waiting: 1,
        plan_waiting: 2,
        execute_waiting: 3,
        finalize_waiting: 3,
        generic_needs_input: 4
      }.freeze

      # The push-notification button emoji per primary-capable RowActions role.
      # Single source for both this module and Supervisor#status_action_emoji,
      # which delegates here — a previous byte-identical second copy meant a new
      # role added to one map raised a Hash#fetch KeyError only on whichever
      # surface (/status, /waiting, or the digest) rendered it first.
      ROLE_EMOJI = {
        answer: "✏️",
        approve: "✅",
        approve_plan: "✅",
        findings_accept: "✅",
        findings_reject: "🚫",
        autofix: "🔧",
        details: "🔍",
        rerun: "▶️"
      }.freeze

      # Fail loud at load if the hand-maintained tables ever drift from the
      # closed RowActions vocabularies they sample. Without these guards, a new
      # upstream needs-input kind is silently excluded from /waiting and the
      # digest, a new urgency-less kind sorts by a stale default, and a new
      # primary-capable role renders no emoji — each a quiet correctness bug
      # that only surfaces at the consuming call site, far from the cause.
      # (Single-line modifier form so the guard line stays covered when it
      # passes — a block-body `raise` would be an uncovered line until drift.)
      raise "WaitingRows::NEEDS_INPUT_KINDS must be a subset of RowActions::KINDS" unless (NEEDS_INPUT_KINDS - Hive::Bot::RowActions::KINDS).empty?
      raise "WaitingRows::URGENCY_RANK keys must equal NEEDS_INPUT_KINDS" unless URGENCY_RANK.keys.sort == NEEDS_INPUT_KINDS.sort
      raise "WaitingRows::ROLE_EMOJI keys must equal RowActions::ROLES" unless ROLE_EMOJI.keys.sort == Hive::Bot::RowActions::ROLES.sort

      def select(rows, daemon_enabled:, logger: nil)
        indexed = Array(rows).each_with_index.filter_map do |row, index|
          resolution = resolve(row, logger: logger)
          next unless resolution
          next unless NEEDS_INPUT_KINDS.include?(resolution.kind)
          next if daemon_plan_pause?(row, resolution, daemon_enabled, logger: logger)

          [ row, resolution, index ]
        end

        indexed.sort_by { |_row, resolution, index| [ urgency_rank(resolution.kind), index ] }
               .map(&:first)
      end

      # Build the one primary keyboard button for a row, or nil when the row is
      # suppressed / has no Telegram-side action. The whole build is wrapped in
      # a per-row rescue so a single malformed row (a typo'd/unmapped role at
      # the RowActions boundary, an unmapped ROLE_EMOJI key, or a bad
      # attrs/workflow value) drops only its own button instead of aborting the
      # caller's filter_map — parity with the resolve-discipline in `select`
      # and with Supervisor#status_action_button, which delegates here.
      def button_for(row, logger: nil)
        project = row.project if row.respond_to?(:project)
        slug = row.slug if row.respond_to?(:slug)
        marker = row.marker if row.respond_to?(:marker)
        row_action = row.action if row.respond_to?(:action)

        resolution = Hive::Bot::RowActions.resolve(row)
        return nil if resolution.suppress || resolution.actions.empty?

        action = resolution.primary
        nb = Hive::Bot::NotificationBuilders
        nb.button("#{ROLE_EMOJI.fetch(action.role)} #{nb.display_title(row)}", action.callback)
      rescue StandardError => e
        logger&.event(:status_button_failed, project: project, slug: slug,
                                              marker: marker, action: row_action,
                                              error_class: e.class.name, message: e.message)
        nil
      end

      def resolve(row, logger: nil)
        Hive::Bot::RowActions.resolve(row)
      rescue StandardError => e
        # A row that genuinely needs input must not vanish from /waiting and the
        # digest without a trace — for a feature whose whole job is reminding
        # about human-blocking tasks, log the drop, then keep the rescue.
        logger&.event(:poll_failure, source: "waiting_row_resolve",
                                      project: (row.project if row.respond_to?(:project)),
                                      slug: (row.slug if row.respond_to?(:slug)),
                                      error_class: e.class.name, message: e.message)
        nil
      end

      def daemon_plan_pause?(row, resolution, daemon_enabled, logger: nil)
        resolution.kind == :plan_waiting && daemon_enabled.call(row)
      rescue StandardError => e
        # Fail-open (over-remind) so this stays low severity, but log once so a
        # real bug in the daemon-enabled check isn't invisible.
        logger&.event(:poll_failure, source: "waiting_daemon_pause",
                                      project: (row.project if row.respond_to?(:project)),
                                      slug: (row.slug if row.respond_to?(:slug)),
                                      error_class: e.class.name, message: e.message)
        false
      end

      # The load-time URGENCY_RANK/NEEDS_INPUT_KINDS drift guard above makes a
      # missing key provably impossible, so this is an honest `.fetch` — a
      # default would silently down-rank a future-drifted kind.
      def urgency_rank(kind)
        URGENCY_RANK.fetch(kind)
      end
    end
  end
end
