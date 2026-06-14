require "date"
require "hive/config"
require "hive/digest/window"
require "hive/digest/shipped_item"
require "hive/digest/ship_times"
require "hive/digest/collector"

module Hive
  module Digest
    class ModelError < Hive::AgentError; end
  end
end
