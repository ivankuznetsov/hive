require "hive/output_reference"

module Hive
  module Attempts
    # Compatibility names for callers that still address output references
    # through the Attempts namespace. The implementation is a lower-level
    # custody primitive so provider domains do not depend upward on Attempts.
    InvalidOutputReference = Hive::InvalidOutputReference
    OutputReference = Hive::OutputReference
  end
end
