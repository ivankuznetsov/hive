require "json"

class TransitionMetrics
  @mutex = Mutex.new
  @denials = Hash.new(0)

  class << self
    def denied!(reason:, **context)
      @mutex.synchronize { @denials[reason.to_s] += 1 }
      Rails.logger.warn(JSON.generate({ event: "board_transition_denied", reason: reason }.merge(context)))
    end

    def snapshot
      @mutex.synchronize { @denials.dup }
    end

    def reset!
      @mutex.synchronize { @denials.clear }
    end
  end
end
