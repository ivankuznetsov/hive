module Hive
  module Digest
    # Single source of truth for the digest's category set. Both the
    # categorizer (which validates the model's chosen category) and the
    # renderer (which orders sections) derive from this one ordered list,
    # so the two can never silently diverge and drop accepted items.
    module Categories
      # [category_key, section_label], in render order.
      ORDERED = [
        [ "feature", "New features" ],
        [ "fix", "Fixes" ],
        [ "patrol", "Patrol tasks" ]
      ].freeze

      # Accepted category keys, in the same order.
      VALID = ORDERED.map(&:first).freeze

      # The category assigned when the model omits a row or returns an
      # unknown value.
      DEFAULT = VALID.first.freeze
    end
  end
end
