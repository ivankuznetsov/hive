require "date"
require "json"
require "hive/digest"

module Hive
  module Commands
    class Digest
      def initialize(date: nil, dry_run: false, json: false, runner: Hive::Digest, output: $stdout)
        @date = date
        @dry_run = dry_run
        @json = json
        @runner = runner
        @output = output
      end

      def call
        local_date = parse_date
        result = @runner.run(date: local_date, dry_run: @dry_run)
        emit(result)
        result
      end

      private

      def parse_date
        return Hive::Digest::Window.local_today - 1 if @date.to_s.empty?

        unless @date.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          raise Hive::ConfigError, "hive digest: --date must be YYYY-MM-DD; got #{@date.inspect}"
        end

        Hive::Digest::Window.parse_date(@date)
      rescue ArgumentError
        raise Hive::ConfigError, "hive digest: --date must be YYYY-MM-DD; got #{@date.inspect}"
      end

      def emit(result)
        if @json
          @output.puts JSON.generate(json_payload(result))
        elsif @dry_run
          @output.puts result.message
        else
          @output.puts "hive digest: #{result.status} for #{result.date.iso8601}"
        end
      end

      def json_payload(result)
        {
          # Derive from status so a machine consumer can tell a delivered
          # digest from one that fell back to a failure notice.
          "ok" => result.status != :failed_notice,
          "schema" => "hive-digest",
          "date" => result.date.iso8601,
          "status" => result.status.to_s,
          "dry_run" => @dry_run,
          "message" => @dry_run ? result.message : nil
        }
      end
    end
  end
end
