# frozen_string_literal: true

# OpenCode plugin inspection can exceed Agent CLI Runtime's production capture
# deadline during a parallel cold start. Scope the larger bound to benchmark
# containers; ordinary Hive keeps its normal timeout.
require "agent_cli_runtime"

timeout = Integer(ENV.fetch("HB_OPENCODE_PROBE_TIMEOUT_SEC", "10"), 10)
unless timeout.between?(10, 300)
  raise "HB_OPENCODE_PROBE_TIMEOUT_SEC must be between 10 and 300 seconds"
end

AgentCliRuntime::Profile.send(:remove_const, :CAPTURE_TIMEOUT_SECONDS)
AgentCliRuntime::Profile.const_set(:CAPTURE_TIMEOUT_SECONDS, timeout)
