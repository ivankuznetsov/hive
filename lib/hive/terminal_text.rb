module Hive
  # Escapes terminal control bytes in human-readable output while preserving
  # valid UTF-8 text. Agent-controlled task names, provider messages, and
  # status reasons must never be able to move the cursor or rewrite output.
  module TerminalText
    module_function

    def escape(value)
      value.to_s
           .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
           .gsub(/[\u0000-\u001f\u007f-\u009f]/) do |character|
             character.codepoints.map { |codepoint| format("\\x%02X", codepoint) }.join
           end
    end
  end
end
