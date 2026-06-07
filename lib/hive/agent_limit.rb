module Hive
  module AgentLimit
    LIMIT_PATTERNS = [
      /stop and wait for limit to reset/i,
      /add funds to continue with usage credits/i,
      /switch to team plan/i,
      /usage credits/i,
      /insufficient[_\s-]*quota/i,
      /quota (?:exhausted|exceeded|reached)/i,
      /rate limit (?:reached|exceeded|reset|hit)/i,
      /rate limited/i,
      /too many requests/i,
      /\b(?:http|status|response)[:=\s-]*429\b/i,
      /\b429\b[^\n]{0,40}(?:too many|rate limit|quota|requests)/i,
      /resource[_\s-]*exhausted/i,
      /limit (?:reached|exceeded|reset)/i,
      /(?:daily|monthly|usage|spend|spending) limit/i,
      /billing[^\n]{0,80}(?:credit|quota|limit)/i
    ].freeze

    module_function

    def limit_reached?(text)
      normalized = normalize(text)
      return false if normalized.empty?

      LIMIT_PATTERNS.any? { |pattern| normalized.match?(pattern) }
    end

    def error_message(text, agent: nil)
      prefix = "limits reached"
      prefix = "#{prefix} for #{agent}" if agent && !agent.to_s.empty?
      detail = first_useful_line(text)
      detail.empty? ? prefix : "#{prefix}: #{detail}"
    end

    def first_useful_line(text)
      normalize(text).each_line.map(&:strip).find { |line| !line.empty? }.to_s
    end

    def normalize(text)
      text.to_s
          .scrub
          .gsub(/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
          .gsub(/[[:cntrl:]&&[^\n\t]]/, "")
    end
  end
end
