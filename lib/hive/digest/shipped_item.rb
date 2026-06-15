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
      # Guard the de-facto primary key (categorizer_id) at the boundary: a
      # blank project_name AND a blank pr_number/slug would yield "/", which
      # collides every such item onto one key in map_document — the exact
      # collision the project_name prefix exists to prevent. Latent today
      # because the collector fills every field, but the type should not
      # depend on that to stay collision-safe.
      def initialize(project_name:, slug:, display_name:, pr_url:,
                     pr_number:, pr_title:, pr_body:, shipped_at:)
        if project_name.to_s.strip.empty?
          raise ArgumentError, "ShippedItem requires a non-blank project_name"
        end
        if (pr_number || slug).to_s.strip.empty?
          raise ArgumentError,
                "ShippedItem requires a pr_number or slug for a collision-safe categorizer_id"
        end

        super
      end

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
