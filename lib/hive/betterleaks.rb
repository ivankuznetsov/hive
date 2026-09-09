require "rbconfig"

module Hive
  # Release builds carry these upstream binaries inside the gem. Source
  # checkouts may use an explicitly installed Betterleaks while developing.
  module Betterleaks
    VERSION = "1.8.1".freeze
    ASSETS = {
      "linux_x64" => "efa407244e1ea8e35f582b8a42becdeac08bdead04f68eb752adda722d583c2a",
      "linux_arm64" => "bbb578b12a2f65d7082ab436abf37724232bc71d8a078e3c41336574420f1b48",
      "darwin_x64" => "6abc37df76f881cffae406aa2cec72bea6e6ae64b4e771b3ed21b4aac472ed10",
      "darwin_arm64" => "8e80f33b5f2a7426b390347b9fd466033723cb94b6bdffa7572632e2eaec964e"
    }.freeze
    ROOT = File.expand_path("assets/betterleaks", __dir__).freeze

    module_function

    def executable
      os = RbConfig::CONFIG.fetch("host_os").include?("darwin") ? "darwin" : "linux"
      cpu = RbConfig::CONFIG.fetch("host_cpu")
      arch = %w[arm64 aarch64].include?(cpu) ? "arm64" : "x64"
      bundled = File.join(ROOT, "#{os}_#{arch}", "betterleaks")
      File.executable?(bundled) ? bundled : "betterleaks"
    end
  end
end
