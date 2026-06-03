require "time"
require "tmpdir"

require "hive/tui/composer_staging"

module Hive
  module Bot
    class IdeaDraftStore
      DEFAULT_TTL_SEC = 900

      Draft = Struct.new(:chat_id, :phase, :text, :project, :token, :attachments,
                         :counter, :staging_dir, :staging_tmp_root,
                         :created_at, :updated_at, keyword_init: true)

      def initialize(ttl_sec: DEFAULT_TTL_SEC, now: -> { Time.now })
        @ttl_sec = ttl_sec
        @now = now
        @drafts = {}
      end

      def start(chat_id:, phase:, text: nil, token: nil)
        clear(chat_id: chat_id)
        now = @now.call
        draft = Draft.new(
          chat_id: chat_id,
          phase: phase,
          text: text,
          token: token,
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
          draft.phase = :awaiting_project
        end
      end

      def set_project(chat_id:, project:)
        update(chat_id: chat_id) { |draft| draft.project = project }
      end

      def enter_collecting(chat_id:)
        update(chat_id: chat_id) { |draft| draft.phase = :collecting_files }
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
      rescue StandardError
        nil
      end
    end
  end
end
