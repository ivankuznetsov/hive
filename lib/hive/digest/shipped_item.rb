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
      def categorizer_id
        value = pr_number || slug
        value.to_s
      end

      def display_label
        display_name.to_s.empty? ? slug.to_s : display_name.to_s
      end
    end
  end
end
