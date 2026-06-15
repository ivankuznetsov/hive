module Hive
  module Digest
    ShippedItem = Data.define(
      :project_name,
      :slug,
      :display_name,
      :pr_url,
      :pr_number,
      :pr_title,
      :pr_body,
      :shipped_at
    ) do
      # Project-scoped so the categorizer's id→row map can't collide when
      # two registered projects ship a PR with the same number (or the
      # same slug) on the same day — without the project prefix the later
      # item would overwrite the earlier one's model summary.
      def categorizer_id
        "#{project_name}/#{pr_number || slug}"
      end

      def display_label
        display_name.to_s.empty? ? slug.to_s : display_name.to_s
      end
    end
  end
end
