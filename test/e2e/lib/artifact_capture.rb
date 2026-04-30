require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "time"
require_relative "paths"

module Hive
  module E2E
    class ArtifactCapture
      LOG_TAIL_LINES = 200

      def initialize(scenario_dir:, sandbox_dir:, run_home:)
        @scenario_dir = scenario_dir
        @sandbox_dir = sandbox_dir
        @run_home = run_home
        @capture_errors = []
      end

      # Each individual capture call is isolated: a failure in any single artifact
      # writer is recorded in @capture_errors and surfaced through manifest.json
      # but does NOT propagate, so the original step failure remains the
      # canonical scenario error.
      def collect(error:, failed_step:, step_results:, tmux_driver: nil, schema_diff: nil, pane_before: nil)
        FileUtils.mkdir_p(@scenario_dir)
        guard("exception.txt") { write("exception.txt", exception_text(error, failed_step)) }
        guard("env-snapshot.json") { write("env-snapshot.json", JSON.pretty_generate(env_snapshot)) }
        guard("sandbox-git-status.txt") { write("sandbox-git-status.txt", capture("git", "-C", @sandbox_dir, "status", "--short", "--branch")) }
        guard("sandbox-tree.txt") { write("sandbox-tree.txt", sandbox_tree) }
        guard("schema-diff.txt") { write("schema-diff.txt", schema_diff) } if schema_diff && !schema_diff.empty?
        if tmux_driver
          guard("keystrokes.log") { write("keystrokes.log", JSON.pretty_generate(tmux_driver.keystrokes)) }
          guard("pane-after.txt") { write("pane-after.txt", safe_pane_capture(tmux_driver)) }
          guard("pane-before.txt") { write("pane-before.txt", pane_before) } if pane_before
        end
        guard("state") { copy_tree(File.join(@sandbox_dir, ".hive-state", "stages"), File.join(@scenario_dir, "state")) }
        guard("logs") { copy_logs_with_tails }
        guard("step-results.json") { write("step-results.json", JSON.pretty_generate(step_results)) }
        write_manifest
      end

      private

      def exception_text(error, failed_step)
        lines = []
        lines << "step_index: #{failed_step&.position}"
        lines << "step_kind: #{failed_step&.kind}"
        lines << "#{error.class}: #{error.message}"
        lines.concat(Array(error.backtrace).first(30))
        "#{lines.join("\n")}\n"
      end

      def env_snapshot
        {
          "schema" => "hive-e2e-env-snapshot",
          "schema_version" => 1,
          "hive_version" => first_line(RbConfig.ruby, "-I#{Paths.lib_dir}", Paths.hive_bin, "version"),
          "ruby" => RUBY_DESCRIPTION,
          "platform" => RUBY_PLATFORM,
          "tmux_version" => first_line("tmux", "-V"),
          "asciinema_version" => first_line("asciinema", "--version"),
          "term" => ENV.fetch("TERM", ""),
          "hive_home" => @run_home,
          "bundle_gemfile" => ENV.fetch("BUNDLE_GEMFILE", ""),
          "path" => ENV.fetch("PATH", ""),
          "sandbox" => @sandbox_dir
        }
      end

      # capture-pane requires a live session. If the pane already collapsed,
      # we shouldn't crash the artifact pass; record a placeholder.
      def safe_pane_capture(tmux_driver)
        tmux_driver.capture_pane
      rescue StandardError => e
        "(capture-pane failed: #{e.class}: #{e.message})\n"
      end

      # Replace the broad copy_tree of .hive-state/logs with a per-file copy
      # that ALSO writes a `<basename>.tail` containing the last N lines, so
      # agents reading artifacts can scan the recent activity quickly without
      # rg'ing through a multi-MB log.
      def copy_logs_with_tails
        source = File.join(@sandbox_dir, ".hive-state", "logs")
        return unless File.directory?(source)

        Dir.glob(File.join(source, "**", "*.log")).each do |full_path|
          relative = full_path.sub("#{source}/", "")
          dest = File.join(@scenario_dir, "logs", relative)
          FileUtils.mkdir_p(File.dirname(dest))
          FileUtils.cp(full_path, dest)
          tail_path = "#{dest}.tail"
          File.write(tail_path, tail_lines(full_path, LOG_TAIL_LINES))
        end
      end

      def tail_lines(path, count)
        lines = File.foreach(path).each_with_object([]) do |line, acc|
          acc << line
          acc.shift if acc.size > count
        end
        lines.join
      end

      def first_line(*cmd)
        out, err, status = Open3.capture3(*cmd)
        return "(unavailable)" unless status.success?

        (out.empty? ? err : out).lines.first.to_s.strip
      rescue Errno::ENOENT
        "(missing)"
      end

      def capture(*cmd)
        out, err, status = Open3.capture3(*cmd)
        text = out.empty? ? err : out
        text += "\n(exit #{status.exitstatus})" unless status.success?
        text
      end

      def sandbox_tree
        return "" unless File.directory?(@sandbox_dir)

        Dir.chdir(@sandbox_dir) do
          Dir.glob("**/*", File::FNM_DOTMATCH)
            .reject { |path| path == "." || path == ".." || path.include?("/.git/") }
            .sort
            .join("\n") + "\n"
        end
      end

      def copy_tree(source, dest)
        return unless File.directory?(source)

        FileUtils.rm_rf(dest)
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp_r(source, dest)
      end

      def write(relative, content)
        path = File.join(@scenario_dir, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content.to_s)
      end

      def guard(label)
        yield
      rescue StandardError => e
        @capture_errors << { "label" => label, "error" => "#{e.class}: #{e.message}" }
      end

      def write_manifest
        files = Dir[File.join(@scenario_dir, "**", "*")].select { |path| File.file?(path) }.sort
        manifest = {
          "schema" => "hive-e2e-manifest",
          "schema_version" => 1,
          "generated_at" => Time.now.utc.iso8601,
          "files" => files.map do |path|
            {
              "path" => path.sub("#{@scenario_dir}/", ""),
              "size" => File.size(path),
              "sha256" => Digest::SHA256.file(path).hexdigest
            }
          end,
          "capture_errors" => @capture_errors
        }
        path = File.join(@scenario_dir, "manifest.json")
        tmp = "#{path}.tmp.#{Process.pid}"
        File.write(tmp, JSON.pretty_generate(manifest))
        File.rename(tmp, path)
      end
    end
  end
end
