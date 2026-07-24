module Hive
  module Digest
    class ModelError < Hive::AgentError; end
    class GenerationError < Hive::AgentError; end
    class PermanentDeliveryError < Hive::InternalError; end
    class AmbiguousDeliveryError < PermanentDeliveryError; end
    class PermanentDeliveryCheckpointError < PermanentDeliveryError; end
    class DeliveryCheckpointError < Hive::InternalError; end
  end
end
