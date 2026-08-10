module AgentCliRuntime
  class Error < StandardError
    attr_reader :evidence

    def initialize(message, evidence: nil)
      super(message)
      @evidence = evidence
    end
  end

  class BinaryUnavailable < Error; end
  class VersionError < Error; end
  class UnsupportedCapability < Error; end
  class ProbeError < Error; end
  class CompilationError < Error; end
  class UnknownProvider < Error; end
end
