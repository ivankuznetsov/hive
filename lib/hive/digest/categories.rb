module Hive
  module Digest
    # Single source of truth for the digest's category set. Both the
    # categorizer (which validates the model's chosen category) and the
    # renderer (which orders sections) derive from this one ordered list,
    # so the two can never silently diverge and drop accepted items.
    module Categories
      # [category_key, section_label], in render order.
      ORDERED = [
        [ "feature", "Features" ],
        [ "fix", "Fixes" ],
        [ "patrol", "Patrol" ]
      ].freeze

      # Accepted category keys, in the same order.
      VALID = ORDERED.map(&:first).freeze

      # The category assigned when the model omits a row or returns an
      # unknown value.
      DEFAULT = VALID.first.freeze

      # Single validity predicate shared by the CategorizedItem boundary
      # guard and the categorizer's default-and-warn path, so the two can't
      # drift on what counts as an accepted category.
      def self.valid?(category)
        VALID.include?(category)
      end
    end
  end
end
