require "hive/errors"

module Hive
  # Durable, host-global daily activity projection. Task journals and other
  # project-local stores remain authoritative; this namespace owns the compact
  # cross-project day record and its append-only history.
  module DailyDigest
    class Error < Hive::Error; end
    class InvalidRecord < Error; end
    class MissingRecord < Error; end
    class PrunedRecord < Error; end
  end
end
