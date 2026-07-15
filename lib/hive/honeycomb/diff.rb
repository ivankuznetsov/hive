require "open3"
require "pathname"
require "tempfile"
require "hive/honeycomb/lockfile"
require "hive/honeycomb/package"

module Hive
  module Honeycomb
    WorkflowDiff = Data.define(
      :permissions, :escalation, :instruction_diffs, :descriptor_changed,
      :asset_changes, :metadata_only
    )

    module Diff
      module_function

      def build(entry:, package:, installed_root:)
        old_summary = entry.security.fetch("summary", {})
        new_summary = package.security_report.summary
        permissions = permission_diff(old_summary, new_summary)
        old_instructions = instruction_inventory(installed_root, entry.name, entry.files.keys)
        new_instructions = SecurityReport.instruction_paths(package.descriptor).map do |path|
          Pathname.new(path).relative_path_from(Pathname.new(package.staging_dir)).to_s
        end
        instruction_paths = (old_instructions + new_instructions).uniq.sort
        instruction_diffs = instruction_paths.each_with_object({}) do |path, output|
          old_bytes = read_optional(File.join(installed_root, path))
          new_bytes = package.files[path]
          next if old_bytes == new_bytes
          output[path] = unified(path, old_bytes, new_bytes)
        end.freeze

        descriptor_changed = entry.files["workflow.yml"] != package.hashes["workflow.yml"]
        instruction_set = instruction_paths.to_h { |path| [ path, true ] }
        asset_paths = ((entry.files.keys | package.hashes.keys) - [ "workflow.yml" ]).reject do |path|
          instruction_set.key?(path)
        end
        assets = {
          "added" => asset_paths.select { |path| !entry.files.key?(path) && package.hashes.key?(path) }.sort.freeze,
          "removed" => asset_paths.select { |path| entry.files.key?(path) && !package.hashes.key?(path) }.sort.freeze,
          "changed" => asset_paths.select do |path|
            entry.files.key?(path) && package.hashes.key?(path) && entry.files[path] != package.hashes[path]
          end.sort.freeze
        }.freeze
        file_changed = descriptor_changed || instruction_diffs.any? || assets.values.any?(&:any?)
        permission_changed = permissions.any? do |_field, change|
          if change.key?("added")
            change.fetch("added").any? || change.fetch("removed").any?
          else
            change.fetch("before") != change.fetch("after")
          end
        end
        WorkflowDiff.new(
          permissions: permissions.freeze,
          escalation: escalation?(permissions, old_summary, new_summary),
          instruction_diffs: instruction_diffs,
          descriptor_changed: descriptor_changed,
          asset_changes: assets,
          metadata_only: !file_changed && !permission_changed
        )
      end

      def permission_diff(old_summary, new_summary)
        %w[presets tools dirs].to_h do |field|
          old_values = Array(old_summary[field])
          new_values = Array(new_summary[field])
          [ field, { "added" => (new_values - old_values).sort.freeze,
                     "removed" => (old_values - new_values).sort.freeze }.freeze ]
        end.merge(
          "bash" => { "before" => !!old_summary["bash"], "after" => !!new_summary["bash"] }.freeze,
          "yolo" => { "before" => !!old_summary["yolo"], "after" => !!new_summary["yolo"] }.freeze,
          "shell_capable" => {
            "before" => !!old_summary["shell_capable"], "after" => !!new_summary["shell_capable"]
          }.freeze
        )
      end

      def escalation?(permissions, old_summary, new_summary)
        permissions.fetch("tools").fetch("added").any? ||
          permissions.fetch("dirs").fetch("added").any? ||
          (!old_summary["bash"] && new_summary["bash"]) ||
          (!old_summary["yolo"] && new_summary["yolo"]) ||
          permissions.fetch("presets").fetch("added").include?("yolo")
      end

      def instruction_inventory(root, name, fallback_files)
        descriptor_path = File.join(root, "workflow.yml")
        workflow = Hive::Workflows::DescriptorParser.parse_file(descriptor_path, expected_id: name)
        SecurityReport.instruction_paths(workflow).map do |path|
          Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
        end
      rescue Hive::ConfigError, SystemCallError, IOError
        fallback_files.select { |path| path.end_with?(".md") }
      end

      def read_optional(path)
        File.binread(path)
      rescue Errno::ENOENT
        nil
      end

      def unified(path, old_bytes, new_bytes)
        Tempfile.create("honeycomb-old") do |old_file|
          Tempfile.create("honeycomb-new") do |new_file|
            old_file.binmode
            new_file.binmode
            old_file.write(old_bytes.to_s)
            new_file.write(new_bytes.to_s)
            old_file.flush
            new_file.flush
            out, err, status = Open3.capture3(
              "diff", "-u", "--label", "a/#{path}", "--label", "b/#{path}", old_file.path, new_file.path
            )
            return out if status.exitstatus == 1
            return "" if status.success?
            raise Hive::InternalError, "could not render instruction diff for #{path}: #{err}"
          end
        end
      rescue Errno::ENOENT
        # Minimal deterministic fallback for environments without POSIX diff;
        # content is still complete and untruncated.
        old_lines = old_bytes.to_s.lines.map { |line| "-#{line}" }.join
        new_lines = new_bytes.to_s.lines.map { |line| "+#{line}" }.join
        "--- a/#{path}\n+++ b/#{path}\n@@ -1 +1 @@\n#{old_lines}#{new_lines}"
      end
    end
  end
end
