root = ENV["HIVE_COVERAGE_ROOT"] || File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require_relative "support/coverage"
HiveTestCoverage.start!(root: root)
at_exit { HiveTestCoverage.dump_process_result! }

# Production process supervisors use `exit!` so forked children cannot run
# inherited application/test at-exit hooks. Coverage still needs each child's
# hits, so flush a sparse result and then retain the same immediate-exit path.
module HiveCoverageExitFlush
  private

  def exit!(status = false)
    HiveTestCoverage.dump_process_result!(sparse: true)
    super
  end
end

Kernel.prepend(HiveCoverageExitFlush)
