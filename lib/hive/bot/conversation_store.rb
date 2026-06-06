require "time"

module Hive
  module Bot
    class ConversationStore
      VALID_MODES = %i[path_b].freeze

      State = Struct.new(:chat_id, :project, :slug, :question_n, :history, :draft, :mode,
                         :awaiting_confirm, :updated_at, keyword_init: true)

      def initialize(ttl_sec: 3600, now: -> { Time.now })
        @ttl_sec = ttl_sec
        @now = now
        @states = {}
        # `@states` is now read from the status-poll thread
        # (`active_for_slug?`, which also prunes) while it is mutated from
        # the Telegram poll thread (`start`/`update`/`clear`). Guard every
        # access with a mutex, mirroring `AlertStore` / `ChildSupervisor`.
        # `prune_locked` is the lock-free body called from within an
        # already-held lock so the public methods don't re-enter the mutex.
        @mutex = Mutex.new
      end

      def update_ttl(seconds)
        synchronize { @ttl_sec = seconds }
      end

      def start(chat_id:, slug:, question_n:, mode: :path_b, project: nil)
        validate_mode!(mode)
        synchronize do
          @states[key(chat_id, slug)] = State.new(
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
        end
      end

      def get(chat_id:, slug: nil)
        synchronize do
          prune_locked
          if slug
            @states[key(chat_id, slug)]
          else
            @states.values.find { |state| state.chat_id == chat_id }
          end
        end
      end

      def update(chat_id:, slug:, **attrs)
        synchronize do
          prune_locked
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
      end

      def validate_mode!(mode)
        return if VALID_MODES.include?(mode)

        raise ArgumentError, "conversation mode must be one of #{VALID_MODES.inspect}; got #{mode.inspect}"
      end

      def clear(chat_id:, slug:)
        synchronize { @states.delete(key(chat_id, slug)) }
      end

      def pending_confirm_count(chat_id:)
        synchronize do
          prune_locked
          @states.values.count { |state| state.chat_id == chat_id && state.awaiting_confirm }
        end
      end

      # True when ANY chat has a non-expired answer conversation for `slug`
      # (optionally scoped to `project` so two projects sharing a slug
      # don't cross-suppress). The NotificationDispatcher uses this to
      # suppress the proactive "questions waiting" push while the operator
      # is actively answering — otherwise a brainstorm that briefly flaps
      # out of WAITING (e.g. a mid-answer daemon resume) re-fires the alert
      # and spams someone who is clearly already on it. Pruning drops
      # TTL-expired states first, so an abandoned conversation stops
      # suppressing the alert once it ages out (re-engaging the operator).
      def active_for_slug?(slug, project: nil)
        synchronize do
          prune_locked
          @states.values.any? do |state|
            next false unless state.slug == slug

            # Lenient project scoping: only refuse a match when BOTH sides
            # carry a project and they differ (the genuine two-projects-
            # same-slug case). When either is nil — the caller didn't scope,
            # or `start_answer` couldn't backfill the project — still
            # suppress, so the fix never silently regresses to spamming.
            project.nil? || state.project.nil? || state.project == project
          end
        end
      end

      private

      def synchronize(&block)
        @mutex.synchronize(&block)
      end

      def prune_locked
        cutoff = @now.call - @ttl_sec
        @states.delete_if { |_key, state| state.updated_at < cutoff }
      end

      def key(chat_id, slug)
        [ chat_id, slug ]
      end
    end
  end
end
