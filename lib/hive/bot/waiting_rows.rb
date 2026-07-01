# frozen_string_literal: true

require "psych"
require "hive/bot/notification_builders"
require "hive/bot/row_actions"
require "hive/config"

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
      # Single source for every surface that renders a primary button — /status,
      # /waiting, and the answer-digest all reach it through #button_for. A
      # previous byte-identical second copy meant a new role added to one map
      # raised a Hash#fetch KeyError only on whichever surface rendered it first.
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

      # The RowActions kinds the /waiting + digest selector deliberately does
      # NOT treat as human-input gates: the inert none/suppressed cases and the
      # stage_approval/recovery surfaces. Declared so the drift guard below can
      # be bidirectional — every RowActions::KINDS kind must be classified as
      # either a needs-input kind or an explicitly-excluded one.
      NON_NEEDS_INPUT_KINDS = %i[none suppressed stage_approval recovery].freeze

      # Fail loud at load if the hand-maintained tables ever drift from the
      # closed RowActions vocabularies they sample. Without these guards a new
      # urgency-less kind would sort by a stale default and a new primary-capable
      # role would render no emoji — each a quiet correctness bug that only
      # surfaces at the consuming call site, far from the cause. The needs-input
      # guard is a partition-EQUALITY check, not a one-directional subset: a kind
      # ADDED to RowActions::KINDS but mirrored into NEITHER list fails here, so a
      # newly-added upstream needs-input kind can't be silently excluded from
      # /waiting and the digest — precisely the "never silently forget a waiting
      # task" failure this feature exists to prevent. A removed/renamed kind
      # fails it too (the lists would no longer cover KINDS exactly).
      # (Single-line modifier form so each guard line stays covered when it
      # passes — a block-body `raise` would be an uncovered line until drift.)
      raise "WaitingRows NEEDS_INPUT_KINDS + NON_NEEDS_INPUT_KINDS must partition RowActions::KINDS exactly" unless (NEEDS_INPUT_KINDS + NON_NEEDS_INPUT_KINDS).sort == Hive::Bot::RowActions::KINDS.sort
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
        # Hoist the log identifiers BEFORE the fallible call, matching
        # #button_for: reading them inside the rescue (where a row with a
        # malformed reader could re-raise) would defeat the per-row isolation.
        project = row.project if row.respond_to?(:project)
        slug = row.slug if row.respond_to?(:slug)
        Hive::Bot::RowActions.resolve(row)
      rescue StandardError => e
        # A row that genuinely needs input must not vanish from /waiting and the
        # digest without a trace — for a feature whose whole job is reminding
        # about human-blocking tasks, log the drop, then keep the rescue. Every
        # selection surface (/waiting and the digest) now injects a logger
        # before selection, so the drop is observable on all of them.
        logger&.event(:poll_failure, source: "waiting_row_resolve",
                                      project: project, slug: slug,
                                      error_class: e.class.name, message: e.message)
        nil
      end

      def daemon_plan_pause?(row, resolution, daemon_enabled, logger: nil)
        project = row.project if row.respond_to?(:project)
        slug = row.slug if row.respond_to?(:slug)
        resolution.kind == :plan_waiting && daemon_enabled.call(row)
      rescue StandardError => e
        # Fail-open (over-remind) so this stays low severity, but log the drop
        # when a logger is present — which every selection surface now injects
        # before selection — so a real bug in the daemon-enabled check is not
        # invisible.
        logger&.event(:poll_failure, source: "waiting_daemon_pause",
                                      project: project, slug: slug,
                                      error_class: e.class.name, message: e.message)
        false
      end

      # The load-time URGENCY_RANK/NEEDS_INPUT_KINDS drift guard above makes a
      # missing key provably impossible, so this is an honest `.fetch` — a
      # default would silently down-rank a future-drifted kind.
      def urgency_rank(kind)
        URGENCY_RANK.fetch(kind)
      end

      # Resolve a status row's project path for the surfaces that suppress
      # daemon-managed plan pauses (/waiting and the answer-digest, both via
      # #daemon_enabled_resolver — its only caller): prefer the row's own
      # `project_path`, then fall back to the registered project's configured
      # path when the snapshot row lacks one. Without the fallback a
      # project_path-less plan_waiting row the bot would hide could leak into the
      # digest.
      def row_project_path(row)
        path = row.project_path if row.respond_to?(:project_path)
        path = path.to_s
        return path unless path.empty?

        entry = Hive::Config.find_project(row.project) if row.respond_to?(:project)
        entry && entry["path"]
      end

      # Build the resolver `select` uses to suppress daemon-managed plan_waiting
      # rows. Memoizes per resolved project path so a broken config loads (and
      # logs) once per project, not once per waiting row, and fails open
      # (returns false → the plan row still surfaces) while logging the drop
      # under `source`. The rescue catches not just Hive::ConfigError but the
      # raw Psych::Exception / SystemCallError that `Hive::Config.load`'s bare
      # `YAML.safe_load(File.read(...))` raises on a malformed/unreadable
      # project config — otherwise those escaped the rescue, defeated the
      # per-project memoization (re-loading and re-logging per plan_waiting row),
      # and relied on daemon_plan_pause?'s broad rescue as the only backstop.
      # Shared by /waiting (supervisor) and the answer-digest, which differ only
      # in the log `source:` string.
      def daemon_enabled_resolver(source:, logger: nil)
        cache = {}
        lambda do |row|
          path = row_project_path(row)
          next false if path.to_s.empty?

          cache.fetch(path) do
            cache[path] = begin
              Hive::Config.load(path).dig("daemon", "enabled") == true
            rescue Hive::ConfigError, Psych::Exception, SystemCallError => e
              logger&.event(:poll_failure, source: source,
                                           project: (row.project if row.respond_to?(:project)),
                                           error_class: e.class.name, message: e.message)
              false
            end
          end
        end
      end
    end
  end
end
