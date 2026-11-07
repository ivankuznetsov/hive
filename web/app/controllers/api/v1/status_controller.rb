# frozen_string_literal: true

require "digest"

module Api
  module V1
    class StatusController < BaseController
      def index
        authority.scope!("read")
        projects = if params[:project]
          [authority.project!(params[:project])]
        else
          authority.projects.sort_by { |project| project.fetch("name") }
        end
        source = read_service.status(projects: projects)
        names = projects.map { |project| project.fetch("name") }
        rows = Array(source["projects"]).select { |project| names.include?(project["name"]) }.flat_map do |project|
          Array(project["tasks"]).map { |row| serializers.status_row(row, project: project.fetch("name")).merge("project" => project.fetch("name")) }
        end.sort_by { |row| [row.fetch("project"), row.fetch("slug"), row.fetch("stage")] }
        snapshot = Digest::SHA256.hexdigest(JSON.generate(rows.map { |row| row.reject { |key, _| key == "age_seconds" } }))
        project_binding = projects.map { |project| [project.fetch("name"), Hive::Remote::Authorization.fingerprint(project)] }
        offset = params[:cursor] ? handles.resolve_cursor(handle: params[:cursor], projects: project_binding, snapshot: snapshot) : 0
        limit = params[:limit] ? Integer(params[:limit].to_s, 10) : 100
        raise Hive::UsageError, "limit must be positive" unless limit.positive?
        count = [limit, 100].min
        data = serializers.provenance(source).merge(
          "projects" => names.map { |name| { "name" => name, "task_count" => rows.count { |row| row["project"] == name } } },
          "task_count" => rows.length, "tasks" => rows.slice(offset, count) || [], "truncated" => false, "continuation" => nil
        )
        cap = response_limit(Hive::Remote::Protocol::MAX_RESPONSE_BYTES)
        loop do
          next_offset = offset + data.fetch("tasks").length
          data["truncated"] = next_offset < rows.length
          data["continuation"] = data["truncated"] ? handles.cursor(projects: project_binding, snapshot: snapshot, offset: next_offset) : nil
          break if JSON.generate(Hive::Remote::Protocol.envelope(instance_id: instance_id, data: data)).bytesize <= cap
          raise Hive::Remote::Error.new(code: "too_large", status: 413, message: "requested limit cannot contain this response") if data.fetch("tasks").length <= 1
          data.fetch("tasks").pop
        end
        render_data(data)
      rescue ArgumentError, TypeError
        raise Hive::UsageError, "limit must be a positive integer"
      end
    end
  end
end
