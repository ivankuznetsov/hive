module Hive
  # Process exit-code contract shared by clean-loadable component errors and
  # the root CLI aggregate.
  module ExitCodes
    SUCCESS = 0
    GENERIC = 1
    ALREADY_INITIALIZED = 2
    TASK_IN_ERROR = 3
    WRONG_STAGE = 4
    USAGE = 64
    UNAVAILABLE = 69
    SOFTWARE = 70
    TEMPFAIL = 75
    CONFIG = 78
  end

  class Error < StandardError
    def exit_code
      ExitCodes::GENERIC
    end
  end

  class ConfigError < Error
    def exit_code
      ExitCodes::CONFIG
    end
  end
end
