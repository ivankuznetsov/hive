module Hive
  module Bot
    module TitleFormatter
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

      module_function

      def title_from_slug(slug)
        words = slug.to_s.sub(SLUG_SUFFIX, "").tr("-", " ").strip
        sentence = words.empty? ? "Task" : words.downcase
        sentence = sentence[0].upcase + sentence[1..].to_s
        sentence = sentence[0, TITLE_LIMIT] if sentence.length > TITLE_LIMIT
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
        return unless logger && !unknown_stage_labels.key?(key)

        unknown_stage_labels[key] = true
        logger.event(:unknown_stage_label, stage: key)
      end

      def unknown_stage_labels
        @unknown_stage_labels ||= {}
      end
    end
  end
end
