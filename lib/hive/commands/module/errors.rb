require "hive"

module Hive
  module Commands
    class Module
      class ConsentRequired < Hive::Error
        def exit_code = Hive::ExitCodes::USAGE
      end

      class OwnershipError < Hive::Error
        def exit_code = Hive::ExitCodes::USAGE
      end
    end
  end
end
