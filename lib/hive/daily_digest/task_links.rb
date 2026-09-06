require "cgi"
require "hive/config"
require "hive/task_resolver"

module Hive
  module DailyDigest
    # Resolves persisted task identities against the exact current registration.
    # Historical rows remain readable but lose actionable task links.
    class TaskLinks
      def initialize(current_projects: Hive::Config.registered_projects, resolver: nil)
        @current_projects = Array(current_projects)
        @resolver = resolver || method(:resolve_task)
      end

      def destination(project, row)
        current = current_project(project)
        return unless current && !row["task_slug"].to_s.empty?

        @resolver.call(current, row)
      rescue Hive::Error, SystemCallError, IOError
        nil
      end

      def validate_rows!(record)
        projects = Array(record["projects"])
        rows = Array(record["items"]) + Array(record["attention"])
        Array(record["amendments"]).each do |amendment|
          rows.concat(Array(amendment["items"])).concat(Array(amendment["attention"]))
        end
        rows.each do |row|
          next if row["task_slug"].to_s.empty?

          project = projects.find { |entry| entry["project_id"] == row["project_id"] } || {
            "project_id" => row["project_id"], "name" => row["project"]
          }
          resolved = destination(project, row)
          if resolved
            row["task_url"] = task_url(resolved, row)
            next
          end

          row.delete("task_url")
          row["historical"] = true
        end
        record
      end

      private

      def current_project(project)
        @current_projects.find do |current|
          current["name"].to_s == project["name"].to_s &&
            (project["project_id"].to_s.empty? ||
              current["project_id"].to_s == project["project_id"].to_s) &&
            (project["registration_id"].to_s.empty? ||
              current["registration_id"].to_s == project["registration_id"].to_s)
        end
      end

      def resolve_task(project, row)
        task = Hive::TaskResolver.new(
          row.fetch("task_slug"), project_filter: project.fetch("name")
        ).resolve
        {
          project: project.fetch("name"), slug: task.slug,
          source: task.stage_index == 9 ? "archive" : nil
        }
      end

      def task_url(destination, row)
        path = "/tasks/#{url_component(destination.fetch(:project))}/" \
               "#{url_component(destination.fetch(:slug))}"
        path = "#{path}?source=archive" if destination[:source] == "archive"
        row["task_url"].to_s.end_with?("#task-questions") ? "#{path}#task-questions" : path
      end

      def url_component(value)
        CGI.escape(value.to_s).gsub("+", "%20")
      end
    end
  end
end
