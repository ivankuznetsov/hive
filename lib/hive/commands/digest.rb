require "json"
require "hive/prdigest"

module Hive
  module Commands
    class Digest
      def initialize(date: nil, dry_run: false, json: false, runner: Hive::Prdigest,
                     output: $stdout, repos: [])
        @date = date
        @dry_run = dry_run
        @json = json
        @runner = runner
        @output = output
        @repos = Array(repos)
        @emitted = false
      end

      def call
        result = @runner.run(date: @date, dry_run: @dry_run, repos: @repos)
        emit(result.payload)
        result
      rescue Hive::Prdigest::InvocationError => e
        emit(e.payload)
        raise
      rescue Hive::Error => e
        emit(adapter_failure(e)) if @json && !@emitted
        raise
      rescue StandardError => e
        error = Hive::InternalError.new("hive digest: internal adapter error: #{e.class}: #{e.message}")
        emit(adapter_failure(error)) if @json && !@emitted
        raise error
      end

      private

      def emit(payload)
        if @json
          @output.puts JSON.generate(payload)
        elsif @dry_run && payload["status"] == "dry_run"
          @output.puts Array(payload["chunks"]).join("\n\n")
        elsif payload["status"] == "success"
          @output.puts "hive digest: prdigest success; settled=#{Array(payload['settled_days']).length}"
        end
        @emitted = true
      rescue Errno::EPIPE
        @emitted = true
      end

      def adapter_failure(error)
        Hive::Prdigest.failure_payload(
          kind: error.is_a?(Hive::ConfigError) ? "config" : "internal",
          message: error.message,
          mode: @date.to_s.empty? ? "scheduled" : "explicit_date_replay"
        )
      end
    end
  end
end
