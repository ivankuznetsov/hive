module Hive
  VERSION = "0.1.0".freeze
  MIN_CLAUDE_VERSION = "2.1.118".freeze

  class Error < StandardError
    def exit_code
      1
    end
  end

  class InvalidTaskPath < Error; end
  class ConcurrentRunError < Error; end
  class GitError < Error; end
  class WorktreeError < Error; end
  class AgentError < Error; end
  class ConfigError < Error; end
  class StageError < Error; end
end
