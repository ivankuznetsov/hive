root = ENV["HIVE_COVERAGE_ROOT"] || File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require_relative "support/coverage"
HiveTestCoverage.start!(root: root)
at_exit { HiveTestCoverage.dump_process_result! }
