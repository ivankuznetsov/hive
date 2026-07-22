require "open3"
require "time"
require "hive/git_ops"

module Hive
  # Resolves the immutable first-completion clock used by archive visibility.
  # A durable metadata value is authoritative; legacy discovery prefers the
  # first Git event that made the resolved terminal stage archived, then falls
  # back to the task state-file and folder mtimes.
  module CompletionTime
    TERMINAL_MARKER = /<!--\s*(?:COMPLETE|EXECUTE_COMPLETE|REVIEW_COMPLETE)\b/.freeze

    class History
      def commits(hive_state_path:, slug:)
        out, err, status = Open3.capture3(
          "git", "-C", hive_state_path, "log", Hive::GitOps::HIVE_BRANCH,
          "--format=%H%x00%cI%x00%s", "-F", "--grep", slug
        )
        unless status.success?
          detail = err.strip.empty? ? out : err
          raise Hive::GitError,
                "git log #{Hive::GitOps::HIVE_BRANCH} failed for #{slug}: #{detail}"
        end

        out.each_line.filter_map do |line|
          sha, committed_at, subject = line.chomp.split("\0", 3)
          next if sha.to_s.empty? || committed_at.to_s.empty? || subject.to_s.empty?
          next unless subject.include?("/#{slug} ")

          { sha: sha, committed_at: committed_at, subject: subject }
        end
      end

      def file_at(hive_state_path:, sha:, relative_path:)
        out, _err, status = Open3.capture3(
          "git", "-C", hive_state_path, "show", "#{sha}:#{relative_path}"
        )
        status.success? ? out : nil
      end
    end

    module_function

    def parse(value, warn_context: nil)
      return nil if value.nil?
      return value.utc if value.is_a?(Time)
      unless value.is_a?(String) && value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
        warn "hive: completion_time: invalid completed_at for #{warn_context}; keeping task visible" if warn_context
        return nil
      end

      Time.iso8601(value).utc
    rescue ArgumentError
      warn "hive: completion_time: invalid completed_at for #{warn_context}; keeping task visible" if warn_context
      nil
    end

    def discover(task, history: History.new)
      from_history(task, history: history) || discover_from_mtimes(task)
    rescue Hive::GitError => e
      warn "hive: completion_time: #{e.message}; falling back to filesystem mtimes"
      discover_from_mtimes(task)
    end

    def discover_from_mtimes(task)
      readable_mtime(task.state_file) || readable_mtime(task.folder)
    end

    def from_history(task, history: History.new)
      terminal = task.workflow.stages.last
      entries = history.commits(hive_state_path: task.hive_state_path, slug: task.slug)
      credible = entries.filter_map do |entry|
        next unless completion_entry?(task, terminal, entry, history: history)

        parse(entry.fetch(:committed_at))
      end
      credible.min
    end

    def completion_entry?(task, terminal, entry, history:)
      subject = entry.fetch(:subject)
      arrival = subject.include?("/#{task.slug} ") &&
                subject.include?("approve") && subject.include?("-> #{terminal.dir}")
      return true if terminal.kind == :inert && arrival
      return false unless [ :agent, :council ].include?(terminal.kind)
      return false unless subject.start_with?("hive: #{terminal.dir}/#{task.slug} ")

      state_rel = File.join("stages", terminal.dir, task.slug, terminal.state_file)
      state = history.file_at(
        hive_state_path: task.hive_state_path, sha: entry.fetch(:sha), relative_path: state_rel
      )
      return false unless state&.match?(TERMINAL_MARKER)

      deliverable = terminal.deliverable || terminal.state_file
      deliverable_rel = File.join("stages", terminal.dir, task.slug, deliverable)
      contents = history.file_at(
        hive_state_path: task.hive_state_path, sha: entry.fetch(:sha), relative_path: deliverable_rel
      )
      !contents.to_s.empty?
    end

    def readable_mtime(path)
      File.mtime(path).utc
    rescue SystemCallError, IOError
      nil
    end
  end
end
