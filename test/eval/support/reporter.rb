require "json"
require "fileutils"
require "time"

module Hive
  module Eval
    module ReportStore
      module_function

      def enabled?
        !ENV["HIVE_EVAL_REPORT"].to_s.empty?
      end

      def entries
        @entries ||= []
      end

      def record(test)
        return unless enabled?

        harness = test.instance_variable_get(:@harness)
        entries << {
          scenario_name: "#{test.class}##{test.name}",
          file: source_location_for(test),
          status: test.failures.empty? ? "pass" : "fail",
          failures: test.failures.map { |failure| failure.message.to_s },
          assertions: test.respond_to?(:eval_assertions) ? test.eval_assertions : [],
          captured_messages: captured_messages(harness),
          captured_log_events: captured_log_events(harness),
          duration_ms: duration_ms(test)
        }
      end

      def write!
        return unless enabled?

        path = ENV.fetch("HIVE_EVAL_REPORT")
        FileUtils.mkdir_p(File.dirname(path))
        write_fresh_report(path, JSON.pretty_generate({
          schema: "hive-eval-report",
          schema_version: 1,
          generated_at: Time.now.utc.iso8601,
          scenarios: entries
        }))
      end

      # Write the report to a fresh regular file at PATH. A bare File.write
      # follows a symlink or hard link at the report path and clobbers the
      # linked target — e.g. a caller passing --report pointing at a symlink to
      # an unrelated file. Unlink any existing entry first: rm_f drops the
      # symlink itself (never its target) or one hard-link reference, leaving
      # the linked file's data intact. Then open with O_CREAT|O_EXCL|O_NOFOLLOW
      # so a symlink recreated in the race window is refused rather than
      # followed, and the report always lands on a new regular file.
      def write_fresh_report(path, contents)
        FileUtils.rm_f(path)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o644) do |file|
          file.write(contents)
        end
      end

      def source_location_for(test)
        test.class.instance_method(test.name).source_location&.first
      rescue NameError
        nil
      end

      def duration_ms(test)
        started = test.instance_variable_get(:@hive_eval_started_at)
        return nil unless started

        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      end

      def captured_messages(harness)
        return [] unless harness

        classifications = Hive::Eval::ReasonClassifier.new(
          messages: harness.sent,
          log_events: harness.logger.respond_to?(:events) ? harness.logger.events : []
        ).classify_all
        classifications.map do |entry|
          message = entry.message
          {
            text: message.text,
            chat_id: message.chat_id,
            reason: entry.reason,
            proactive: entry.proactive,
            detail: entry.detail,
            fingerprint: message.fingerprint,
            reply_markup: Hive::Eval::FakeTelegram.canonical_reply_markup(message.reply_markup),
            t: message.t&.utc&.iso8601
          }
        end
      end

      def captured_log_events(harness)
        return [] unless harness&.logger&.respond_to?(:events)

        harness.logger.events.map do |event|
          {
            event: event.name.to_s,
            attrs: event.attrs,
            t: event.t&.utc&.iso8601
          }
        end
      end
    end
  end
end

Minitest.after_run { Hive::Eval::ReportStore.write! } if defined?(Minitest)
