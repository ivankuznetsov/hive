require "test_helper"
require "hive/daemon/digest_scheduler_base"

class HiveDaemonDigestSchedulerBaseTest < Minitest::Test
  def test_subclasses_must_define_an_explicit_scheduler_contract
    scheduler = Hive::Daemon::DigestSchedulerBase.new(
      state_path: "/tmp/unused",
      clock: -> { Time.utc(2026, 6, 14, 9, 0, 0) },
      enabled: true,
      logger: nil
    )

    error = assert_raises(NotImplementedError) { scheduler.send(:scheduler_contract) }

    assert_match(/must define its digest scheduler contract/, error.message)
  end
end
