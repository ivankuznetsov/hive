# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "yaml"
require_relative "../paths"

module HiveReleaseCandidate
  class UpgradeSurvivor
    class StateSnapshotter
      def initialize(process_teardown:)
        @process_teardown = process_teardown
      end

      def call(target:, row:, project:, environment:)
        env = environment
        status = probe_json(target, [ "status", "--json" ], env, project)
        doctor = probe_json(target, [ "doctor", "--json" ], env, project)
        state = File.join(project, ".hive-state")
        config = safe_yaml(File.join(state, "config.yml"))
        tasks = task_snapshot(state)
        sections = {
          "global_registry" => tree(File.join(env.fetch("HIVE_HOME"), "config.yml")),
          "project_registry" => tree(File.join(env.fetch("HIVE_HOME"), "config.yml")),
          "configuration" => config,
          "default_workflow" => config["default_workflow"] || "coding",
          "tasks" => tasks,
          "dependencies" => tasks.transform_values { |task| task["dependencies"] },
          "markers" => tasks.transform_values { |task| task["markers"] },
          "durable_attempts" => tree(File.join(state, "attempts")),
          "dispatch_receipts" => tree(File.join(state, "dispatch-receipts")),
          "channel_sidecars" => tree(File.join(env.fetch("HIVE_HOME"), "install-channel")),
          "managed_web_data" => tree(File.join(env.fetch("XDG_DATA_HOME"), "hive", "web")),
          "service_definitions" => tree(File.join(env.fetch("XDG_CONFIG_HOME"), "systemd", "user")),
          "status_json" => status,
          "doctor_json" => doctor,
          "install_identity" => {
            "role" => target.role,
            "version" => target.manifest.fetch("version"),
            "gem_sha256" => target.manifest.fetch("gem_sha256")
          }
        }
        if row.id == "legacy-bench-v041"
          sections.merge!(
            "legacy_descriptor" => tree(File.join(state, "workflows", "bench.yml"),
                                        File.join(state, "workflows", "bench.legacy.yml.disabled")),
            "legacy_instructions" => tree(File.join(state, "workflows", "bench"),
                                          File.join(state, "workflows", "bench.legacy")),
            "builtin_runtime" => tree(File.join(state, "bench-runtime"))
          )
        end
        sections
      end

      def task_present?(project)
        Dir.glob(File.join(project, ".hive-state", "stages", "*", "*")).any? do |path|
          File.directory?(path) && !File.symlink?(path)
        end
      end

      private

      def probe_json(target, argv, environment, cwd)
        receipt = @process_teardown.capture(
          target: target, argv: argv, environment: environment,
          cwd: cwd, label: "snapshot:#{argv.first}"
        )
        JSON.parse(receipt.fetch("stdout"))
      rescue JSON::ParserError
        {
          "status" => receipt && receipt["status"],
          "exit_status" => receipt && receipt["exit_status"],
          "stdout_sha256" => Digest::SHA256.hexdigest(receipt.to_h["stdout"].to_s),
          "stderr_sha256" => Digest::SHA256.hexdigest(receipt.to_h["stderr"].to_s)
        }
      end

      def task_snapshot(state)
        Dir.glob(File.join(state, "stages", "*", "*")).sort.filter_map do |path|
          next unless File.directory?(path) && !File.symlink?(path)
          slug = File.basename(path)
          meta = safe_yaml(File.join(path, "meta.yml"))
          [
            slug,
            {
              "id" => meta["id"], "slug" => meta["slug"] || slug,
              "stage" => File.basename(File.dirname(path)),
              "contents" => tree(path),
              "dependencies" => meta["depends_on"] || [],
              "markers" => Dir.glob(File.join(path, "*")).sort.flat_map do |file|
                next [] unless File.file?(file) && !File.symlink?(file)
                File.binread(file).scan(/<!--\s*([A-Z_]+)(?:\s+[^>]*)?\s*-->/).flatten
              end.uniq.sort
            }
          ]
        end.to_h
      end

      def safe_yaml(path)
        return {} unless File.file?(path) && !File.symlink?(path)
        value = YAML.safe_load_file(path, aliases: false)
        value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
      rescue Psych::Exception, SystemCallError
        {}
      end

      def tree(*alternatives)
        path = alternatives.find { |candidate| File.exist?(candidate) || File.symlink?(candidate) }
        return { "status" => "absent" } unless path
        stat = File.lstat(path)
        raise Error, "upgrade snapshot refuses symlink #{path}" if stat.symlink?
        if stat.file?
          return {
            "status" => "file", "size" => stat.size,
            "sha256" => Digest::SHA256.file(path).hexdigest
          }
        end
        entries = Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |entry|
          next if [ ".", ".." ].include?(File.basename(entry))
          child = File.lstat(entry)
          raise Error, "upgrade snapshot refuses symlink #{entry}" if child.symlink?
          next if child.directory?
          relative = Pathname.new(entry).relative_path_from(Pathname.new(path)).to_s
          [ relative, { "size" => child.size, "sha256" => Digest::SHA256.file(entry).hexdigest } ]
        end
        { "status" => "directory", "files" => entries.to_h }
      end
    end
  end
end
