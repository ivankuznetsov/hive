require "json"
require "hive/daily_digest/coordinator"

module Hive
  module Commands
    # Explicit mutation boundary for operators and the daemon. Ordinary
    # `hive digest` reads never instantiate this class.
    class DigestRefresh
      def initialize(date: nil, json: false, coordinator: DailyDigest::Coordinator.new,
                     stdout: $stdout)
        @date = date
        @json = json
        @coordinator = coordinator
        @stdout = stdout
      end

      def call!
        results = @coordinator.refresh(date: @date)
        envelope = {
          "schema" => "hive-digest-refresh", "schema_version" => 1,
          "ok" => true, "results" => results
        }
        if @json
          @stdout.puts(JSON.generate(envelope))
        else
          results.each do |result|
            @stdout.puts("#{result.fetch('local_date')} #{result.fetch('status')}")
          end
        end
        envelope
      end
    end
  end
end
