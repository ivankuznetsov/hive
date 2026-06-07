module Hive
  module Bot
    # Single canonical ISO-639-1 code → English display-name map for the voice
    # transcription feature. Two call sites need opposite directions:
    #   - Transcriber's language gate maps Whisper's full-name `language`
    #     ("english") back to an ISO code to compare against configured
    #     supported_languages.
    #   - Supervisor's unsupported-language hint maps an ISO code to a human
    #     name for the operator reply.
    # Deriving NAME_TO_ISO from ISO_TO_NAME via .invert keeps the two
    # directions from drifting: add a language here and both surfaces get it.
    module Languages
      ISO_TO_NAME = {
        "en" => "English", "ru" => "Russian", "es" => "Spanish", "fr" => "French",
        "de" => "German", "it" => "Italian", "pt" => "Portuguese", "nl" => "Dutch",
        "pl" => "Polish", "uk" => "Ukrainian", "tr" => "Turkish", "ar" => "Arabic",
        "zh" => "Chinese", "ja" => "Japanese", "ko" => "Korean", "hi" => "Hindi"
      }.freeze

      # Whisper reports `language` as a lowercased full English name; operators
      # configure ISO codes. The gate normalizes both sides through this map,
      # so its keys are the lowercased display names.
      NAME_TO_ISO = ISO_TO_NAME.each_with_object({}) do |(iso, name), acc|
        acc[name.downcase] = iso
      end.freeze
    end
  end
end
