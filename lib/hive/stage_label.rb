module Hive
  module StageLabel
    # coding-scoped (block): canonical display labels for the built-in coding workflow stage dirs
    KNOWN = {
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
    ACRONYMS = %w[PR CI CD DB UI UX API URL HTTP].freeze
    ACRONYM_PATTERNS = ACRONYMS.map { |acronym| [ /\b#{Regexp.escape(acronym)}\b/i, acronym ] }.freeze

    module_function

    def format(stage)
      key = stage.to_s
      return KNOWN.fetch(key) if KNOWN.key?(key)

      words = key.sub(/\A\d+-/, "").tr("-_", " ").strip
      return "Stage" if words.empty?

      preserve_acronyms(words.split(/\s+/).map(&:capitalize).join(" "))
    end

    def preserve_acronyms(label)
      ACRONYM_PATTERNS.reduce(label) do |formatted, (pattern, acronym)|
        formatted.gsub(pattern, acronym)
      end
    end
  end
end
