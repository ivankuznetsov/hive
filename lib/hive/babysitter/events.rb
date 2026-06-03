require "json"
require "time"
require "fileutils"

module Hive
  module Babysitter
    module Events
      ACTIONS = %w[
        list-prs
        noop
        skipped
        agent-fix
        force-push
        pr-comment
        label-apply
        give-up
        dry_run
      ].freeze

      OUTCOMES = %w[
        success
        failure
        timeout
        budget_exhausted
        gh-error
        already-green
        label_ignored
        fork_pr
        dry_run
      ].freeze

      module_function

      def emit(project:, pr: nil, action:, outcome:, duration_ms: nil, **attrs)
        action = action.to_s
        outcome = outcome.to_s
        raise ArgumentError, "unknown babysitter action #{action.inspect}" unless ACTIONS.include?(action)
        raise ArgumentError, "unknown babysitter outcome #{outcome.inspect}" unless OUTCOMES.include?(outcome)

        record = {
          "ts" => Time.now.utc.iso8601,
          "stage" => "babysitter",
          "project" => project.fetch("name"),
          "pr" => pr,
          "action" => action,
          "outcome" => outcome,
          "duration_ms" => duration_ms
        }.merge(attrs.transform_keys(&:to_s)).compact

        path = File.join(project.fetch("hive_state_path"), "babysitter", "events.jsonl")
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o644, encoding: "UTF-8") do |file|
          file.syswrite("#{JSON.generate(record)}\n")
        end
        record
      end
    end
  end
end
