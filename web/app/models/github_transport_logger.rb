# Builds an untagged, message-only warning sink sharing the configured Rails
# log destination so structured JSON diagnostics emit a single parseable line
# without mutating the active request logger's formatter or tag stack.
class GithubTransportLogger
  def self.build(logger = Rails.logger)
    sink = logger.dup
    sink.formatter = ActiveSupport::Logger::SimpleFormatter.new
    sink
  end
end
