require "time"

module Hive
  module Bot
    class ConversationStore
      VALID_MODES = %i[path_a path_b].freeze

      State = Struct.new(:chat_id, :project, :slug, :question_n, :history, :draft, :mode,
                         :awaiting_confirm, :updated_at, keyword_init: true)

      def initialize(ttl_sec: 3600, now: -> { Time.now })
        @ttl_sec = ttl_sec
        @now = now
        @states = {}
      end

      def update_ttl(seconds)
        @ttl_sec = seconds
      end

      def start(chat_id:, slug:, question_n:, mode: :path_b, project: nil)
        validate_mode!(mode)
        state = State.new(
          chat_id: chat_id,
          project: project,
          slug: slug,
          question_n: question_n,
          history: [],
          draft: nil,
          mode: mode,
          awaiting_confirm: false,
          updated_at: @now.call
        )
        @states[key(chat_id, slug)] = state
      end

      def get(chat_id:, slug: nil)
        prune!
        if slug
          @states[key(chat_id, slug)]
        else
          @states.values.find { |state| state.chat_id == chat_id }
        end
      end

      def update(chat_id:, slug:, **attrs)
        prune!
        state = @states.fetch(key(chat_id, slug))
        attrs.each do |name, value|
          setter = "#{name}="
          raise ArgumentError, "unknown conversation state attr: #{name}" unless state.respond_to?(setter)

          validate_mode!(value) if name == :mode
          state.public_send(setter, value)
        end
        state.updated_at = @now.call
        state
      end

      def validate_mode!(mode)
        return if VALID_MODES.include?(mode)

        raise ArgumentError, "conversation mode must be one of #{VALID_MODES.inspect}; got #{mode.inspect}"
      end

      def clear(chat_id:, slug:)
        @states.delete(key(chat_id, slug))
      end

      def pending_confirm_count(chat_id:)
        prune!
        @states.values.count { |state| state.chat_id == chat_id && state.awaiting_confirm }
      end

      # True when ANY chat has a non-expired answer conversation for
      # `slug`. The NotificationDispatcher uses this to suppress the
      # proactive "questions waiting" push while the operator is actively
      # answering — otherwise a brainstorm that briefly flaps out of
      # WAITING (e.g. a mid-answer daemon resume) re-fires the alert and
      # spams someone who is clearly already on it. `prune!` drops
      # TTL-expired states first, so an abandoned conversation stops
      # suppressing the alert once it ages out (re-engaging the operator).
      def active_for_slug?(slug)
        prune!
        @states.values.any? { |state| state.slug == slug }
      end

      def prune!
        cutoff = @now.call - @ttl_sec
        @states.delete_if { |_key, state| state.updated_at < cutoff }
      end

      private

      def key(chat_id, slug)
        [ chat_id, slug ]
      end
    end
  end
end
