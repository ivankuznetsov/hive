require "securerandom"
require "time"
require "hive/bot/notification_builders"
require "hive/bot/idea_keyboards"
require "hive/bot/handlers/recovery_sequence"

module Hive
  module Bot
    module Handlers
      class SlashHandlers
        def initialize(projects_provider:, pending_ideas:, last_project:, result_class:,
                       idea_draft_store: nil, idea_attachment_policy: nil,
                       max_attachment_bytes: nil, max_attachment_count: nil,
                       now: -> { Time.now },
                       status_snapshot_provider: -> { [] },
                       logger: nil)
          @projects_provider = projects_provider
          @pending_ideas = pending_ideas
          @last_project = last_project
          @result_class = result_class
          @idea_draft_store = idea_draft_store
          @idea_attachment_policy = idea_attachment_policy
          @max_attachment_bytes = max_attachment_bytes
          @max_attachment_count = max_attachment_count
          @now = now
          @status_snapshot_provider = status_snapshot_provider
          @logger = logger
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
          text = effective_text(update).to_s.sub(%r{\A/idea\b}, "").strip
          if text.empty?
            return start_text_capture(update) if @idea_draft_store

            return @result_class.new(action: :reply, text: "Use /idea <text> to capture a new idea.")
          end

          start_idea(update, text: text, stage_media: update.respond_to?(:media?) && update.media?)
        end

        def capture_idea_text(update)
          text = update.text.to_s.strip
          return @result_class.new(action: :reply, text: "Send the idea text in your next message.") if text.empty?

          draft = @idea_draft_store.get(chat_id: update.chat_id)
          return @result_class.new(action: :reply, text: "That idea draft expired. Send /idea again.") unless draft

          @idea_draft_store.set_text(chat_id: update.chat_id, text: text)
          project_picker_result(token: draft.token)
        end

        def voice(update)
          voice = update.voice || {}
          file_id = voice[:file_id]
          # A voice payload with no file_id can't be fetched. This runs inside
          # the router, before execute_transcribe_voice's rescue, so a raised
          # KeyError would escape to the poll loop and leave the operator with
          # no reply at all. Reply gracefully instead of a silent no-reply.
          if file_id.to_s.empty?
            return @result_class.new(action: :reply,
                                     text: "Couldn't read that voice note - please send it again.")
          end

          @result_class.new(
            action: :transcribe_voice,
            attachment: {
              chat_id: update.chat_id,
              file_id: file_id,
              file_size: voice[:file_size]
            }
          )
        end

        def edit_transcript_text(update)
          text = update.text.to_s.strip
          return @result_class.new(action: :reply, text: "Send corrected transcript text, or a new voice note.") if text.empty?

          draft = @idea_draft_store.get(chat_id: update.chat_id)
          return @result_class.new(action: :reply, text: "That voice idea draft expired. Send the voice note again.") unless draft

          @idea_draft_store.set_transcript(chat_id: update.chat_id, text: text)
          @result_class.new(
            action: :reply,
            text: Hive::Bot::IdeaKeyboards.transcript_preview_text(text),
            reply_markup: Hive::Bot::IdeaKeyboards.voice_confirm_keyboard(draft.token)
          )
        end

        def media(update)
          draft = @idea_draft_store.get(chat_id: update.chat_id)
          started_here = draft.nil?
          caption = effective_text(update).to_s.strip
          if draft.nil?
            text = caption.empty? || caption.start_with?("/") ? nil : caption
            draft = @idea_draft_store.start(
              chat_id: update.chat_id,
              phase: text ? :awaiting_project : :awaiting_text,
              text: text,
              token: SecureRandom.hex(4)
            )
          end

          result = stage_media_result(update, draft: draft, after_stage: media_after_stage_reply(draft))
          # A bare media message (no existing draft, no /idea) that the policy
          # rejects must not leave the draft we just opened behind: an
          # :awaiting_text phantom would hijack the operator's next unrelated
          # text into idea capture. Clear it when nothing actually staged.
          @idea_draft_store.clear(chat_id: update.chat_id) if started_here && result.action != :stage_attachment
          result
        end

        private

        # Mirrors Router#effective_text exactly; FreeTextHandler#effective_text
        # coerces the same read with `.to_s` (returns "", not nil), so the
        # three are not interchangeable — consolidate with care. A media
        # message carries its text in the caption (update.text is nil), so
        # prefer #effective_text. The respond_to? guard is load-bearing for
        # the LegacyMessageUpdate path, which exposes only #text.
        def effective_text(update)
          update.respond_to?(:effective_text) ? update.effective_text : update.text
        end

        def start_text_capture(update)
          draft = @idea_draft_store.start(chat_id: update.chat_id, phase: :awaiting_text,
                                          token: SecureRandom.hex(4))
          has_media = update.respond_to?(:media?) && update.media?
          return @result_class.new(action: :reply, text: "Send the idea text in your next message.") unless has_media

          # `/idea` sent with a photo/document but no caption text lands here.
          # Stage the file now (parity with start_idea) instead of dropping it
          # while the draft waits for the idea text.
          stage_media_result(update, draft: draft, after_stage: media_after_stage_reply(draft))
        end

        def start_idea(update, text:, stage_media: false)
          projects = @projects_provider.call
          return @result_class.new(action: :reply, text: "No Hive projects are registered yet.") if projects.empty?

          token = SecureRandom.hex(4)
          @pending_ideas[token] = { text: text, created_at: @now.call } unless @idea_draft_store
          draft = @idea_draft_store&.start(chat_id: update.chat_id, phase: :awaiting_project,
                                           text: text, token: token)
          result = project_picker_result(token: token)
          return result unless stage_media

          stage_media_result(update, draft: draft, after_stage: result)
        end

        def project_picker_result(token:)
          projects = @projects_provider.call
          return @result_class.new(action: :reply, text: "No Hive projects are registered yet.") if projects.empty?

          @result_class.new(
            action: :reply,
            text: "Pick a project for the idea.",
            reply_markup: Hive::Bot::IdeaKeyboards.project_keyboard(projects, token, last_project: @last_project.call)
          )
        end

        def media_after_stage_reply(draft)
          case draft.phase
          when :awaiting_text
            @result_class.new(action: :reply, text: "What's the idea for this file?")
          when :awaiting_project
            project_picker_result(token: draft.token)
          when :collecting_files
            @result_class.new(action: :reply, text: "Attached. Send more files, or press Done.")
          else
            @result_class.new(action: :reply, text: "Attached.")
          end
        end

        # Both limits are config-driven (idea_attachment_max_bytes /
        # idea_attachment_max_count); interpolate them into operator copy so
        # the wording can't drift from an operator override. Fall back to the
        # documented 20 MB default when the byte limit is unset.
        def max_attachment_mb
          bytes = @max_attachment_bytes.to_i
          bytes = 20 * 1024 * 1024 if bytes <= 0
          (bytes.to_f / (1024 * 1024)).round
        end

        def max_attachment_count
          count = @max_attachment_count.to_i
          count.positive? ? count : 10
        end

        def stage_media_result(update, draft:, after_stage:)
          policy = @idea_attachment_policy.classify(
            update,
            draft,
            max_bytes: @max_attachment_bytes,
            max_count: @max_attachment_count
          )
          case policy.status
          when :ok
            @result_class.new(
              action: :stage_attachment,
              text: after_stage.text,
              reply_markup: after_stage.reply_markup,
              attachment: {
                chat_id: update.chat_id,
                file_id: policy.file_id,
                file_size: policy.file_size,
                ext: policy.ext
              }
            )
          when :too_large
            @result_class.new(action: :reply, text: "That attachment is too large. Send a file under #{max_attachment_mb} MB.")
          when :disallowed_type
            @result_class.new(action: :reply,
                              text: "Unsupported attachment type. Send jpg, png, webp, gif, pdf, txt, md, or docx.")
          when :cap_reached
            @result_class.new(action: :reply,
                              text: "This idea already has #{max_attachment_count} attachments. Press Done to capture it.")
          else
            @result_class.new(action: :reply, text: "I could not attach that file.")
          end
        end

        public

        def answer(update, _conversation_store)
          target = update.text.to_s.split(/\s+/, 2)[1].to_s.strip
          return @result_class.new(action: :reply, text: "Use /answer <id|slug>.") if target.empty?

          slug, error = resolve_numeric_target_slug(target)
          return @result_class.new(action: :reply, text: error) if error

          @result_class.new(action: :start_answer, slug: slug, mode: :path_b)
        end

        def approve(update)
          target = update.text.to_s.split(/\s+/, 2)[1].to_s.strip
          return @result_class.new(action: :reply, text: "Use /approve <id|slug>.") if target.empty?

          slug, error = resolve_numeric_target_slug(target)
          return @result_class.new(action: :reply, text: error) if error

          @result_class.new(action: :dispatch_then_reply,
                            command_argv: [ "hive", "approve", slug, "--json" ],
                            slug: slug)
        end

        def done(update, conversation_store)
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
            text: "Send any message to capture an idea. Commands: /status [project], /queue, " \
                  "/idea [text], /answer <id|slug>, /approve <id|slug>, /autofix <id|slug>, " \
                  "/details <id|slug>, /done, /help"
          )
        end

        # Telegram's automatic first-contact command. A welcome with the
        # next concrete step beats the bare command list: the operator just
        # connected the bot from hivebox and wants proof it works.
        def start(_update)
          @result_class.new(
            action: :reply,
            text: "Connected. This bot drives your hive pipeline: it notifies you when " \
                  "tasks need answers or approvals, and you can reply right here.\n\n" \
                  "Try /status to see your tasks, send any message to capture a new idea, " \
                  "or /help for every command."
          )
        end

        def autofix(update)
          target = update.text.to_s.split(/\s+/, 2)[1].to_s.strip
          return @result_class.new(action: :reply, text: "Use /autofix <id|slug>.") if target.empty?

          row, error = resolve_status_row(target)
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
            workflow: row.respond_to?(:workflow) ? row.workflow : nil,
            result_class: @result_class, clear_keyboard: false
          )
        end

        def details(update)
          target = update.text.to_s.split(/\s+/, 2)[1].to_s.strip
          return @result_class.new(action: :reply, text: "Use /details <id|slug>.") if target.empty?

          row, error = resolve_status_row(target)
          return @result_class.new(action: :reply, text: error) if error

          @result_class.new(action: :reply, text: render_details_reply(row))
        end

        private

        # details_reply renders from a live Row and never raises today, but it
        # runs OUTSIDE resolve_status_row's degrade rescue. A render-time fault
        # (e.g. a row whose attrs aren't a Hash) would escape to the poll loop
        # and leave the operator with no reply — and skip write_last_seen, so
        # Telegram redelivers the update. Degrade to the soft retry hint and log
        # (with a backtrace) so the fault stays diagnosable.
        def render_details_reply(row)
          Hive::Bot::NotificationBuilders.details_reply(row)
        rescue StandardError => e
          # resolve_status_row matches on :slug alone, so a slug-only provider
          # row need not respond to :project (or even :slug). Guard both reads
          # here — an unguarded row.project would re-raise and defeat this very
          # soft-degrade path.
          @logger&.event(:details_render_failed,
                         project: (row.project if row.respond_to?(:project)),
                         slug: (row.slug if row.respond_to?(:slug)),
                         error_class: e.class.name, message: e.message,
                         backtrace: Array(e.backtrace).first(3))
          Hive::Bot::NotificationBuilders::STATUS_LOOKUP_FAILED_REPLY
        end

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

        def numeric_id(target)
          match = /\A#?(\d+)\z/.match(target.to_s)
          match ? Integer(match[1], 10) : nil
        end

        def resolve_numeric_target_slug(target)
          id = numeric_id(target)
          return [ target, nil ] unless id

          row, error = resolve_status_row(target, id: id)
          return [ nil, error ] if error

          [ row.slug, nil ]
        end

        # Resolves an id or slug against the latest status snapshot. Returns
        # [row, nil] on a unique match, or [nil, error_text] otherwise:
        #   - snapshot nil        → status not loaded yet (bot just started);
        #                           we never sync-fetch here (see
        #                           Supervisor#latest_status_rows for why)
        #   - id zero matches     → id not found / archived
        #   - id multi-match      → ids are globally unique, so we take the
        #                           head row with no ambiguity guard (unlike
        #                           the slug arm below); a duplicate id would
        #                           mean a corrupt snapshot, not a real choice
        #   - slug zero matches   → slug not found / archived
        #   - slug multi-match    → ambiguous across projects. A slash
        #                           command carries no project, so we refuse
        #                           rather than dispatch against a guessed
        #                           project (slugs are date+hex so this is
        #                           rare, but a silent wrong-project dispatch
        #                           would be worse than asking the operator).
        def resolve_status_row(target, id: numeric_id(target))
          snapshot = @status_snapshot_provider.call
          return [ nil, Hive::Bot::NotificationBuilders::STATUS_STILL_LOADING_REPLY ] if snapshot.nil?

          if id
            matches = Array(snapshot).select { |row| row.respond_to?(:id) && row.id == id }
            return [ nil, "No active task ##{id} — was it archived?" ] if matches.empty?

            return [ matches.first, nil ]
          end

          matches = Array(snapshot).select { |row| row.respond_to?(:slug) && row.slug == target }
          case matches.length
          when 0 then [ nil, "Slug not found, was it archived?" ]
          when 1 then [ matches.first, nil ]
          else [ nil, "Multiple active tasks match #{target}; open on a laptop to pick the right project." ]
          end
        rescue StandardError => e
          # The production provider just reads a cached ivar and cannot raise,
          # but a future provider that does I/O must never crash the poll loop
          # (an escape here would skip write_last_seen_update_id and let
          # Telegram redeliver the update). Log before degrading — otherwise a
          # recurring fault stays invisible in bot.log — then return a soft retry hint.
          @logger&.event(:status_lookup_failed, slug: target,
                                                 error_class: e.class.name, message: e.message,
                                                 backtrace: Array(e.backtrace).first(3))
          [ nil, Hive::Bot::NotificationBuilders::STATUS_LOOKUP_FAILED_REPLY ]
        end
      end
    end
  end
end
