module Hive
  module DisplayName
    module Sanitizer
      module_function

      MAX_LENGTH = 60

      def sanitize(value)
        text = value.to_s
        text = text.gsub(/```.*?```/m, " ")
        text = text.gsub(/[`*_#>\[\]]/, " ")
        text = text.tr("\r\n", " ")
        text = text.gsub(/\s+/, " ").strip
        text = text.gsub(/\A["'“”‘’]+|["'“”‘’]+\z/, "")
        text = text.gsub(/[[:punct:]]+\z/, "")
        text = text.strip
        text = text.gsub(/[[:punct:]]+\z/, "").strip
        return nil if text.empty?

        truncate(text)
      end

      def truncate(text)
        return text if text.length <= MAX_LENGTH

        truncated = text[0, MAX_LENGTH].sub(/\s+\S*\z/, "").strip
        truncated.empty? ? text[0, MAX_LENGTH].strip : truncated
      end
    end
  end
end
