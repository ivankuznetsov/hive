require_relative "coverage"

# `HiveTestCoverage.configure!` repoints module-level state that the running
# process's own coverage dump depends on (@root, @lib_dir, @resultset_dir).
# A test that configures a temporary root and never restores it redirects the
# shard's final at_exit dump into a scratch directory nobody collects, so the
# whole process's hits vanish while the shard still exits zero. Every test that
# needs a temporary coverage root goes through this sandbox so the leak cannot
# happen. See wiki/testing.md.
module HiveCoverageConfigSandbox
  STATE_IVARS = %i[
    @root
    @lib_dir
    @coverage_dir
    @resultset_dir
    @result_errors
    @startup_errors
    @verified_marshal_paths
  ].freeze

  ABSENT = Object.new
  private_constant :ABSENT

  module_function

  def capture
    STATE_IVARS.to_h do |ivar|
      value = if HiveTestCoverage.instance_variable_defined?(ivar)
        HiveTestCoverage.instance_variable_get(ivar)
      else
        ABSENT
      end
      [ ivar, value ]
    end
  end

  def restore(captured)
    captured&.each do |ivar, value|
      if value.equal?(ABSENT)
        HiveTestCoverage.remove_instance_variable(ivar) if HiveTestCoverage.instance_variable_defined?(ivar)
      else
        HiveTestCoverage.instance_variable_set(ivar, value)
      end
    end
  end

  # Mixin for Minitest classes. Use the block form for a single assertion, or
  # the setup/teardown pair when every test in the class needs the temp root.
  module TestHelpers
    def with_coverage_config(root:)
      captured = HiveCoverageConfigSandbox.capture
      HiveTestCoverage.configure!(root: root)
      yield
    ensure
      HiveCoverageConfigSandbox.restore(captured)
    end

    # Idempotent: repeated calls keep the first (pristine) snapshot, so a test
    # may re-point the root mid-run and teardown still restores the real one.
    def configure_coverage_root!(root)
      @hive_coverage_config_snapshot ||= HiveCoverageConfigSandbox.capture
      HiveTestCoverage.configure!(root: root)
    end

    def restore_coverage_config!
      HiveCoverageConfigSandbox.restore(@hive_coverage_config_snapshot)
      @hive_coverage_config_snapshot = nil
    end
  end
end
