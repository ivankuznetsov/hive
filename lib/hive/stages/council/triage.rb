require "fileutils"
require "hive/workflow"

module Hive
  module Stages
    module Council
      class Triage
        # Tolerate an optional leading Markdown-heading prefix (`## Verdict: ready`)
        # so a reviewer that puts its verdict in a heading still matches — the
        # bare `#` would otherwise break the leading-whitespace anchor and the
        # passing reviewer would silently count as changes-requested.
        READY_RE = /^\s*(?:#+\s*)?(?:verdict|status)\s*:\s*(ready|approved|pass|passes)\b/i
        CHANGES_RE = /^\s*(?:#+\s*)?(?:verdict|status)\s*:\s*(changes_requested|needs_changes|blocked|fail|fails)\b/i

        Result = Data.define(:path, :ready_count, :reviewer_count, :ready) do
          def initialize(path:, ready_count:, reviewer_count:, ready:)
            super
          end
        end

        def self.run!(stage:, review_paths:, round:, target_path:, task_folder:)
          new(stage: stage, review_paths: review_paths, round: round, target_path: target_path, task_folder: task_folder).run!
        end

        def initialize(stage:, review_paths:, round:, target_path:, task_folder:)
          @stage = stage
          @review_paths = review_paths
          @round = round
          @target_path = target_path
          @task_folder = task_folder
        end

        def run!
          entries = @review_paths.map { |path| entry_for(path) }
          ready_count = entries.count { |entry| entry.fetch(:ready) }
          path = triage_path
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, render(entries, ready_count))
          copy_latest(path)
          Result.new(
            path: path,
            ready_count: ready_count,
            reviewer_count: entries.length,
            ready: ready_count >= @stage.council.quorum
          )
        end

        private

        def entry_for(path)
          body = File.exist?(path) ? File.read(path) : ""
          {
            path: path,
            name: File.basename(path, ".md"),
            body: body,
            ready: ready?(body),
            findings: extract_section(body, "findings"),
            required_edits: extract_section(body, "required edits")
          }
        end

        def ready?(body)
          return true if body.match?(READY_RE)
          return false if body.match?(CHANGES_RE)

          # No structured `Verdict:`/`Status:` line. Free-text prose is too
          # ambiguous to trust — "not yet ready", "nearly ready", and
          # "almost ready to merge" all contain `ready` without the exact
          # `not ready` phrase, so guessing from prose can drive a false
          # :complete and advance a document the reviewer rejected. Default
          # to not-ready; a reviewer that wants to pass must emit the
          # templated verdict line.
          false
        end

        def extract_section(body, heading)
          lines = body.lines
          start = lines.index { |line| line.match?(/^\s*##+\s+#{Regexp.escape(heading)}\s*$/i) }
          return "- None declared.\n" unless start

          collected = []
          lines[(start + 1)..].to_a.each do |line|
            break if line.match?(/^\s*##+\s+/)

            collected << line
          end
          text = collected.join.strip
          text.empty? ? "- None declared.\n" : "#{text}\n"
        end

        def render(entries, ready_count)
          required = @stage.council.quorum
          <<~MD
            # Council triage round #{format('%02d', @round)}

            Target document: #{@target_path}
            Readiness: #{ready_count}/#{entries.length} ready (quorum #{required}) #{ready_count >= required ? "ready" : "not ready"}

            ## Verdicts
            #{entries.map { |entry| "- #{entry.fetch(:name)}: #{entry.fetch(:ready) ? 'ready' : 'changes requested'}" }.join("\n")}

            ## Accepted findings
            #{entries.map { |entry| "### #{entry.fetch(:name)}\n#{entry.fetch(:findings)}" }.join("\n")}

            ## Rejected findings
            - Not derivable by deterministic triage (no reviewer adjudication step).

            ## Required edits
            #{entries.map { |entry| "### #{entry.fetch(:name)}\n#{entry.fetch(:required_edits)}" }.join("\n")}

            ## Open disagreements
            #{open_disagreements(entries)}

            ## Readiness
            #{ready_count >= required ? 'Ready to advance.' : 'Not ready; revision or human input required.'}
          MD
        end

        def open_disagreements(entries)
          verdicts = entries.map { |entry| entry.fetch(:ready) }.uniq
          return "- None.\n" if verdicts.length <= 1

          "- Reviewers disagree on readiness.\n"
        end

        def triage_path
          base = @stage.council.triage_output || Hive::Workflow::DEFAULT_TRIAGE_OUTPUT
          dir = File.dirname(base)
          basename = File.basename(base, ".md")
          File.join(@task_folder, dir, "#{basename}-#{format('%02d', @round)}.md")
        end

        def copy_latest(path)
          latest = File.join(@task_folder, @stage.council.triage_output || Hive::Workflow::DEFAULT_TRIAGE_OUTPUT)
          return if latest == path

          FileUtils.mkdir_p(File.dirname(latest))
          File.write(latest, File.read(path))
        end
      end
    end
  end
end
