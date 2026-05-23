module Hive
  module Tui
    # Shared key list for the red-status detail screen — referenced by
    # the view (footer) and KeyMap (refusal-flash hint). Single source
    # so a key rename in one surface cannot drift away from the other.
    # Lives outside the view module so KeyMap (an input-layer concern)
    # doesn't have to require a view (an output-layer concern) just to
    # read shared key-binding data.
    module RedStatusDetailKeys
      ACTION_KEYS = [
        { footer: "[Enter] Recover",   hint: "press Enter to recover" },
        { footer: "[o] Open in agent", hint: "o to open in agent" },
        { footer: "[Esc] back",        hint: "Esc or q to close" }
      ].each(&:freeze).freeze

      FOOTER = ACTION_KEYS.map { |k| k[:footer] }.join("   ").freeze
    end
  end
end
