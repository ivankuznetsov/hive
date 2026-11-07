# frozen_string_literal: true

require "digest"

module Api
  module V1
    class ArtifactsController < BaseController
      def index
        project, task = read_target!(validate_state: false)
        source = read_service.artifacts(project: project, task: task)
        generation = resource_generation(task)
        records = Array(source["records"]).first(20).map do |record|
          reference = record.fetch("reference")
          record.slice("bytes", "truncated", "binary", "invalid_encoding").merge(
            "name" => File.basename(reference),
            "id" => handles.artifact(project: project, task: task, generation: generation, reference: reference)
          )
        end
        render_bounded({ "state" => source["state"], "records" => records,
          "truncated" => source["truncated"] || Array(source["records"]).length > 20,
          "observed_files" => source["observed_files"], "observed_bytes" => source["observed_bytes"], "continuation" => nil })
      end

      def show
        project, task = read_target!(validate_state: false)
        generation = resource_generation(task)
        reference = handles.resolve_artifact(handle: params[:id], project: project, task: task, generation: generation)
        cap = response_limit(512 * 1024)
        result = read_service.artifact(project: project, task: task, reference: reference, max_bytes: cap)
        render_bounded({ "state" => result.binary ? "unavailable" : "available",
          "content" => result.binary ? nil : result.content, "bytes" => result.bytes,
          "truncated" => result.truncated, "invalid_encoding" => result.invalid_encoding,
          "binary" => result.binary, "continuation" => nil }, limit: cap)
      rescue Hive::TaskWorkspace::SourceError
        render_bounded({ "state" => "unavailable", "content" => nil, "truncated" => false, "continuation" => nil }, limit: cap)
      end
      private

      # Read identities follow the task incarnation and current state-file
      # observation without hashing an unbounded or symlinked state artifact.
      def resource_generation(task)
        folder = File.stat(task.folder)
        state = begin
          stat = File.lstat(task.state_file)
          [stat.dev, stat.ino, stat.size, stat.mtime.to_r.to_s, stat.ctime.to_r.to_s, stat.symlink?]
        rescue Errno::ENOENT
          nil
        end
        Digest::SHA256.hexdigest(JSON.generate([task.id, task.slug, task.stage_index, task.stage_name,
          folder.dev, folder.ino, state]))
      end
    end
  end
end
