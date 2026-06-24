require "monitor"

module Hive
  module Bot
    module TitleFormatter
      # coding-scoped (block): bespoke human labels for the coding stage dirs;
      # every other workflow titleizes its stage name instead of looking up
      # this coding-only map (see stage_label's fallback).
      STAGE_LABELS = {
        "1-inbox" => "Inbox",
        "2-brainstorm" => "Brainstorm",
        "3-plan" => "Plan",
        "4-execute" => "Execute",
        "5-open-pr" => "Open PR",
        "6-review" => "Review",
        "7-artifacts" => "Artifacts",
        "8-finalize" => "Finalize",
        "9-done" => "Done"
      }.freeze

      SLUG_SUFFIX = /-\d{6}-[a-f0-9]{4,}\z/
      TITLE_LIMIT = 60
      ACRONYMS = %w[PR CI CD DB UI UX API URL HTTP].freeze
      ACRONYM_REGEXPS = ACRONYMS.map { |a| [ /\b#{Regexp.escape(a)}\b/i, a ] }.freeze
      UNKNOWN_STAGE_LABELS_LOCK = Monitor.new
      # Eager-initialize the unknown-label cache so the lookup at log time
      # is never racing with a lazy-init. Behaviour is unchanged from a
      # successfully-initialised state; only the construction race goes
      # away.
      @unknown_stage_labels = {}

      module_function

      def title_from_slug(slug)
        words = slug.to_s.sub(SLUG_SUFFIX, "").tr("-", " ").strip
        sentence = words.empty? ? "Task" : words.downcase
        sentence = sentence[0].upcase + sentence[1..].to_s
        sentence = sentence[0, TITLE_LIMIT] if sentence.length > TITLE_LIMIT
        sentence = preserve_acronyms(sentence)
        "#{sentence}…"
      end

      def stage_label(stage_dir, logger: nil)
        key = stage_dir.to_s
        label = STAGE_LABELS[key]
        return label if label

        log_unknown_stage_once(key, logger)
        fallback = key.sub(/\A\d+-/, "").tr("-", " ").strip
        fallback = "stage" if fallback.empty?
        fallback.split(/\s+/).map(&:capitalize).join(" ")
      end

      def log_unknown_stage_once(key, logger)
        return unless logger

        UNKNOWN_STAGE_LABELS_LOCK.synchronize do
          return if unknown_stage_labels.key?(key)

          unknown_stage_labels[key] = true
          logger.event(:unknown_stage_label, stage: key)
        end
      end

      # Clear the once-per-process log cache so SIGHUP / config reload can
      # surface new stage_dir values that previously logged. Without this
      # the cache lives for the bot's lifetime and silently masks stage
      # additions across `hive bot reload`. Callers MUST hold no other
      # locks; the synchronize here is the same Monitor protecting the
      # cache mutation in log_unknown_stage_once.
      def reset_unknown_stage_log_cache!
        UNKNOWN_STAGE_LABELS_LOCK.synchronize { unknown_stage_labels.clear }
      end

      def preserve_acronyms(sentence)
        ACRONYM_REGEXPS.each do |pattern, replacement|
          sentence = sentence.gsub(pattern, replacement)
        end
        sentence
      end

      def unknown_stage_labels
        @unknown_stage_labels
      end
    end
  end
end
