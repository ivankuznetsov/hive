require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "digest"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "agent_cli_runtime"

module AgentCliRuntimeTestHelpers
  def write_executable(path, body)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end
end

class Minitest::Test
  include AgentCliRuntimeTestHelpers
end
