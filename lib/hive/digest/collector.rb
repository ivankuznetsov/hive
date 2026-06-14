require "date"
require "hive/config"
require "hive/digest/window"
require "hive/digest/shipped_item"
require "hive/digest/ship_times"
require "hive/gh"
require "hive/task_meta"

module Hive
  module Digest
    class Collector
      DONE_STAGE = "9-done".freeze

      def initialize(registry: -> { Hive::Config.registered_projects },
                     ship_times: ShipTimes.new,
                     clock: -> { Time.now })
        @registry = registry
        @ship_times = ship_times
        @clock = clock
      end

      def for_date(date)
        local_date = Window.parse_date(date)
        @registry.call.each_with_object({}) do |entry, grouped|
          items = collect_project(entry, local_date)
          grouped[entry.fetch("name")] = items unless items.empty?
        end
      end

      private

      def collect_project(entry, date)
        done_glob = File.join(entry.fetch("hive_state_path"), "stages", DONE_STAGE, "*")
        Dir[done_glob].select { |path| File.directory?(path) }.filter_map do |folder|
          build_item(entry, folder, date)
        end.sort_by(&:shipped_at)
      end

      def build_item(entry, folder, date)
        meta = Hive::TaskMeta.read(folder)
        slug = meta[:slug] || File.basename(folder)
        shipped_at = @ship_times.shipped_at(hive_state_path: entry.fetch("hive_state_path"), slug: slug)
        return nil unless shipped_at && Window.on_local_date?(shipped_at, date)

        pr_path = File.join(folder, "pr.md")
        frontmatter = Hive::Gh.pr_frontmatter(pr_path)
        body = pr_body(pr_path)
        ShippedItem.new(
          project_name: entry.fetch("name"),
          slug: slug,
          display_name: meta[:display_name] || slug,
          pr_url: frontmatter["pr_url"].to_s,
          pr_number: frontmatter["pr_number"],
          pr_title: pr_title(body, meta[:display_name] || slug),
          pr_body: body,
          shipped_at: shipped_at
        )
      rescue Hive::GitError
        nil
      end

      def pr_body(path)
        return "" unless File.exist?(path)

        content = File.read(path)
        if content =~ /\A---\s*\n.*?\n---\s*\n/m
          content.sub(/\A---\s*\n.*?\n---\s*\n/m, "").strip
        else
          content.strip
        end
      rescue SystemCallError, IOError
        ""
      end

      def pr_title(body, fallback)
        heading = body.each_line.find { |line| line.match?(/\A\s{0,3}\#{1,6}\s+\S/) }
        return fallback.to_s if heading.nil?

        heading.sub(/\A\s{0,3}\#{1,6}\s+/, "").strip
      end
    end
  end
end
