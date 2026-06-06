require "time"
require "tmpdir"

require "hive/tui/composer_staging"

module Hive
  module Bot
    class IdeaDraftStore
      DEFAULT_TTL_SEC = 900

      # Shown when a voice note arrives while a non-voice draft is open. The
      # router short-circuits this case to a reply before any transcribe step
      # runs, but the supervisor keeps the same guard as defense-in-depth, so
      # both reference this single constant to avoid the copy drifting.
      VOICE_DURING_DRAFT_MESSAGE = "Finish or discard the current idea draft before sending a voice note."

      # The Draft is a mutable Struct handed live to callers, so the
      # phase/origin contract is enforced at the transition methods rather
      # than by the type. PHASES enumerates every legal phase; ORIGINS the
      # legal non-nil origins (nil = a plain typed/media draft). A typo'd
      # symbol raises at the transition rather than silently mis-routing.
      PHASES = %i[awaiting_text awaiting_project awaiting_transcript_confirm collecting_files].freeze
      ORIGINS = %i[voice].freeze

      Draft = Struct.new(:chat_id, :phase, :text, :project, :token, :attachments,
                         :counter, :staging_dir, :staging_tmp_root,
                         :origin, :created_at, :updated_at, keyword_init: true)

      def initialize(ttl_sec: DEFAULT_TTL_SEC, now: -> { Time.now }, logger: nil)
        @ttl_sec = ttl_sec
        @now = now
        @logger = logger
        @drafts = {}
      end

      def start(chat_id:, phase:, text: nil, token: nil, origin: nil)
        validate_phase!(phase)
        validate_origin!(origin)
        validate_phase_origin!(phase, origin)
        clear(chat_id: chat_id)
        now = @now.call
        draft = Draft.new(
          chat_id: chat_id,
          phase: phase,
          text: text,
          token: token,
          origin: origin,
          attachments: [],
          counter: 0,
          created_at: now,
          updated_at: now
        )
        @drafts[chat_id] = draft
      end

      def get(chat_id:)
        draft = @drafts[chat_id]
        return nil unless draft
        return draft unless expired?(draft)

        clear(chat_id: chat_id)
        nil
      end

      def find_by_token(token)
        @drafts.each_value.find { |draft| draft.token == token && !expired?(draft) }
      end

      def set_text(chat_id:, text:)
        update(chat_id: chat_id) do |draft|
          draft.text = text
          assign_phase!(draft, :awaiting_project)
        end
      end

      def set_transcript(chat_id:, text:)
        update(chat_id: chat_id) do |draft|
          # A successful transcript supersedes any audio a prior failed
          # transcription staged as a fallback (stage_voice_fallback leaves the
          # draft in :awaiting_text with voice-N.oga staged). Re-transcribing
          # the same draft must drop that staging, or the confirmed idea would
          # divert into the file-collection flow and link the leftover audio —
          # breaking the transcript-only guarantee (R6/AE1).
          discard_staging!(draft)
          draft.text = text
          assign_phase!(draft, :awaiting_transcript_confirm)
        end
      end

      def confirm_transcript(chat_id:)
        update(chat_id: chat_id) { |draft| assign_phase!(draft, :awaiting_project) }
      end

      def await_text(chat_id:)
        update(chat_id: chat_id) do |draft|
          draft.text = nil
          assign_phase!(draft, :awaiting_text)
        end
      end

      def set_project(chat_id:, project:)
        update(chat_id: chat_id) { |draft| draft.project = project }
      end

      def enter_collecting(chat_id:)
        update(chat_id: chat_id) { |draft| assign_phase!(draft, :collecting_files) }
      end

      def ensure_staging_dir(chat_id:)
        update(chat_id: chat_id) do |draft|
          next draft.staging_dir if draft.staging_dir

          tmp_root = File.expand_path(Dir.tmpdir)
          draft.staging_dir = Dir.mktmpdir("hive-bot-idea-#{Process.pid}-", tmp_root)
          draft.staging_tmp_root = tmp_root
          draft.staging_dir
        end
      end

      def next_attachment_number(chat_id:)
        draft = get(chat_id: chat_id)
        draft ? draft.counter + 1 : 1
      end

      def append_attachment(chat_id:, label:, dest_name:, staging_path:, ext:)
        update(chat_id: chat_id) do |draft|
          draft.counter += 1
          attachment = {
            label: label,
            dest_name: dest_name,
            staging_path: staging_path,
            ext: ext
          }
          draft.attachments << attachment
          attachment
        end
      end

      def clear(chat_id:)
        draft = @drafts.delete(chat_id)
        cleanup_draft(draft)
        draft
      end

      def prune!
        @drafts.dup.each do |chat_id, draft|
          clear(chat_id: chat_id) if expired?(draft)
        end
      end

      private

      def assign_phase!(draft, phase)
        validate_phase!(phase)
        # Enforce the phase/origin coupling at the transition too, not only at
        # start: driving a non-voice draft into :awaiting_transcript_confirm
        # (e.g. via set_transcript) would create a draft the router cannot
        # route, bypassing the invariant the type advertises.
        validate_phase_origin!(phase, draft.origin)
        draft.phase = phase
      end

      # Drop any staged fallback audio and reset the staging bookkeeping. Used
      # when a transcript replaces a prior failed-transcription fallback.
      def discard_staging!(draft)
        cleanup_draft(draft)
        draft.attachments = []
        draft.counter = 0
        draft.staging_dir = nil
        draft.staging_tmp_root = nil
      end

      def validate_phase!(phase)
        return if PHASES.include?(phase)

        raise ArgumentError, "unknown idea draft phase #{phase.inspect} (valid: #{PHASES.inspect})"
      end

      def validate_origin!(origin)
        return if origin.nil? || ORIGINS.include?(origin)

        raise ArgumentError, "unknown idea draft origin #{origin.inspect} (valid: nil, #{ORIGINS.inspect})"
      end

      # :awaiting_transcript_confirm only makes sense for a voice-origin draft:
      # router.rb treats that phase as voice-confirm only when origin == :voice,
      # so starting it with any other origin would create a draft the router
      # cannot route. Enforce the coupling here instead of leaving it implicit.
      def validate_phase_origin!(phase, origin)
        return unless phase == :awaiting_transcript_confirm && origin != :voice

        raise ArgumentError,
              "phase :awaiting_transcript_confirm requires origin :voice (got #{origin.inspect})"
      end

      def update(chat_id:)
        draft = get(chat_id: chat_id)
        return nil unless draft

        value = yield draft
        draft.updated_at = @now.call
        value || draft
      end

      def expired?(draft)
        draft.updated_at < (@now.call - @ttl_sec)
      end

      def cleanup_draft(draft)
        return unless draft&.staging_dir

        Hive::Tui::ComposerStaging.cleanup!(
          draft.staging_dir,
          tmproot: draft.staging_tmp_root || Dir.tmpdir
        )
      rescue StandardError => e
        # Never raise out of teardown (clear/prune must always complete), but
        # don't swallow silently either: a failed removal leaks a temp dir, so
        # log it for an operator tailing bot.log.
        @logger&.event(:send_failure, source: "idea_draft_cleanup",
                                      staging_dir: draft.staging_dir,
                                      error_class: e.class.name, message: e.message)
        nil
      end
    end
  end
end
