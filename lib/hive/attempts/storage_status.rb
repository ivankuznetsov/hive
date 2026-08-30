module Hive
  module Attempts
    module StorageStatus
      module_function

      def unknown
        {
          "status" => "unknown", "layout" => { "generation" => 4 },
          "hot" => { "records" => nil, "invalid" => nil },
          "maintenance" => { "last_started_at" => nil, "last_completed_at" => nil, "last_result" => nil },
          "last_error" => nil, "degraded_reason" => nil
        }
      end
    end
  end
end
