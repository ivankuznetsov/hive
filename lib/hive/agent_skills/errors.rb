require "hive/errors"

module Hive
  module AgentSkills
    class Error < Hive::ConfigError; end
    class ValidationError < Error; end
    class UnsafePath < Error; end
    class StalePlan < Error; end
    class ForeignContent < Error; end
  end
end
