require "securerandom"
require "time"
require "hive/bot/notification_builders"
require "hive/bot/handlers/recovery_sequence"

module Hive
  module Bot
    module Handlers
      class SlashHandlers
        def initialize(projects_provider:, pending_ideas:, last_project:, result_class:,
                       now: -> { Time.now },
                       status_snapshot_provider: -> { [] })
          @projects_provider = projects_provider
          @pending_ideas = pending_ideas
          @last_project = last_project
          @result_class = result_class
          @now = now
          @status_snapshot_provider = status_snapshot_provider
        end

        def status(update)
          rest = update.text.to_s.split(/\s+/, 2)[1].to_s.strip
          tokens = rest.split(/\s+/)
          json = !tokens.delete("--json").nil?
          project = tokens.join(" ").strip
          # The supervisor's in-process status intercept filters via
          # Result.project; `hive status --json` itself does not honour a
          # snapshot-level --project, so the argv stays flag-free to avoid
          # claiming a filter the subprocess fallback would not enforce.
          @result_class.new(action: :dispatch_then_reply,
                            command_argv: [ "hive", "status", "--json" ],
                            project: project.empty? ? nil : project,
                            format: json ? :json : nil)
        end

        def queue(_update)
          @result_class.new(action: :dispatch_then_reply,
                            command_argv: [ "hive", "status", "--json" ])
        end

        def idea(update)
          text = update.text.to_s.sub(%r{\A/idea\b}, "").strip
          return @result_class.new(action: :reply, text: "Use /idea <text> to capture a new idea.") if text.empty?

          projects = @projects_provider.call
          return @result_class.new(action: :reply, text: "No Hive projects are registered yet.") if projects.empty?

          token = SecureRandom.hex(4)
          @pending_ideas[token] = { text: text, created_at: @now.call }
          @result_class.new(
            action: :reply,
            text: "Pick a project for the idea.",
            reply_markup: project_keyboard(projects, token)
          )
        end

        def answer(update, _conversation_store)
          slug = update.text.to_s.split(/\s+/, 2)[1].to_s.strip
          return @result_class.new(action: :reply, text: "Use /answer <slug>.") if slug.empty?

          @result_class.new(action: :start_answer, slug: slug, mode: :path_b)
        end

        def approve(update)
          slug = update.text.to_s.split(/\s+/, 2)[1].to_s.strip
          return @result_class.new(action: :reply, text: "Use /approve <slug>.") if slug.empty?

          @result_class.new(action: :dispatch_then_reply,
                            command_argv: [ "hive", "approve", slug, "--json" ],
                            slug: slug)
        end

        def done(update, conversation_store)
          pending = conversation_store.pending_confirm_count(chat_id: update.chat_id)
          if pending.positive?
            return @result_class.new(action: :reply,
                                     text: "You still have #{pending} draft answers awaiting confirm.")
          end

          state = conversation_store.get(chat_id: update.chat_id)
          return @result_class.new(action: :reply, text: "No active brainstorm conversation.") unless state

          conversation_store.clear(chat_id: update.chat_id, slug: state.slug)
          @result_class.new(action: :dispatch_then_reply,
                            command_argv: [ "hive", "run", state.slug, "--json" ],
                            project: state.respond_to?(:project) ? state.project : nil,
                            slug: state.slug)
        end

        def help(_update)
          @result_class.new(
            action: :reply,
            text: "Commands: /status [project], /queue, /idea <text>, /answer <slug>, " \
                  "/approve <slug>, /autofix <slug>, /details <slug>, /done, /help"
          )
        end

        def autofix(update)
          slug = update.text.to_s.split(/\s+/, 2)[1].to_s.strip
          return @result_class.new(action: :reply, text: "Use /autofix <slug>.") if slug.empty?

          row, error = resolve_status_row(slug)
          return @result_class.new(action: :reply, text: error) if error

          # Gate on retryable_recovery? exactly as the inline 🔧 Autofix button
          # and the /status /autofix link do. The slash path has the full row
          # (including the diagnostic), so a directly-typed /autofix on a row
          # that isn't auto-retryable — a manual-only state, or a recovery row
          # whose diagnostic carries no suggested_next_action.retry — must
          # refuse here rather than dispatch markers-clear + a retry verb.
          # Without this, manually typing /autofix bypassed the retryability
          # gate that both other surfaces enforce.
          unless Hive::Bot::NotificationBuilders.retryable_recovery?(row)
            return @result_class.new(action: :reply, text: not_retryable_hint(row))
          end

          match_attr = Hive::Bot::NotificationBuilders.recovery_match_attr(row)
          # clear_keyboard is false for the slash path — no inline button was
          # tapped, so there's no keyboard to clear on the originating
          # message. The inline-button path (CallbackHandlers#autofix) sets
          # it to true. This is the only legitimate divergence between the
          # two surfaces. We forward row.attrs (which the slash path has but
          # the callback_data does not carry) so attrs-gated manual-only
          # states refuse here instead of dispatching a retry.
          RecoverySequence.build(
            project: row.project, slug: row.slug, stage: row.stage,
            marker: row.marker, match_attr: match_attr, attrs: row.attrs,
            result_class: @result_class, clear_keyboard: false
          )
        end

        def details(update)
          slug = update.text.to_s.split(/\s+/, 2)[1].to_s.strip
          return @result_class.new(action: :reply, text: "Use /details <slug>.") if slug.empty?

          row, error = resolve_status_row(slug)
          return @result_class.new(action: :reply, text: error) if error

          stage_argv = row.stage ? [ "--stage", row.stage ] : []
          @result_class.new(
            action: :dispatch_then_reply,
            project: row.project,
            slug: row.slug,
            command_argv: [ "hive", "status", "--diagnose", row.slug,
                            "--project", row.project, *stage_argv, "--json" ]
          )
        end

        private

        # Operator-facing refusal for a /autofix on a non-retryable row.
        # Manual-only states (execute_stale, fix_tampered) point at a laptop;
        # other non-retryable recovery rows (and any non-recovery row) point
        # at /details so the operator can see what the task actually needs.
        def not_retryable_hint(row)
          if Hive::Bot::NotificationBuilders.manual_only_recovery?(row)
            "Hive has no automatic recovery for this state - open it on a laptop."
          else
            "#{row.slug} has no automatic retry available. Use /details #{row.slug} to see what it needs."
          end
        end

        # Resolves a slug against the latest status snapshot. Returns
        # [row, nil] on a unique match, or [nil, error_text] otherwise:
        #   - snapshot nil        → status not loaded yet (bot just started);
        #                           we never sync-fetch here (see
        #                           Supervisor#latest_status_rows for why)
        #   - zero matches        → slug not found / archived
        #   - more than one match → ambiguous across projects. A slash
        #                           command carries no project, so we refuse
        #                           rather than dispatch against a guessed
        #                           project (slugs are date+hex so this is
        #                           rare, but a silent wrong-project dispatch
        #                           would be worse than asking the operator).
        def resolve_status_row(slug)
          snapshot = @status_snapshot_provider.call
          return [ nil, "Status is still loading — try again in a moment." ] if snapshot.nil?

          matches = Array(snapshot).select { |row| row.respond_to?(:slug) && row.slug == slug }
          case matches.length
          when 0 then [ nil, "Slug not found, was it archived?" ]
          when 1 then [ matches.first, nil ]
          else [ nil, "Multiple active tasks match #{slug}; open on a laptop to pick the right project." ]
          end
        rescue StandardError
          # The production provider just reads a cached ivar and cannot raise,
          # but a future provider that does I/O must never crash the poll loop
          # (an escape here would skip write_last_seen and let Telegram
          # redeliver the update). Degrade to a soft retry hint instead.
          [ nil, "Status lookup failed — try again in a moment." ]
        end

        def project_keyboard(projects, token)
          sorted = projects.sort_by { |project| project["name"] == @last_project.call ? 0 : 1 }
          rows = sorted.map do |project|
            label = project["name"] == @last_project.call ? "★ #{project['name']}" : project["name"]
            [ { text: label, callback_data: "idea_project:#{project['name']}:#{token}" } ]
          end
          rows << [ { text: "+ new project", callback_data: "idea_project_new:#{token}" } ]
          rows
        end
      end
    end
  end
end
