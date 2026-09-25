require "test_helper"
require "open3"

class LaunchRegistrationGateIntegrationTest < Minitest::Test
  include HiveTestHelper

  def test_child_exits_before_loading_hive_when_registration_is_denied
    reader, writer = IO.pipe
    reader.close_on_exec = false
    env = { "HIVE_LAUNCH_GATE_FD" => reader.fileno.to_s }
    pid = Process.spawn(
      env, RbConfig.ruby, File.expand_path("../../bin/hive", __dir__), "--version",
      reader.fileno => reader.fileno, out: File::NULL, err: File::NULL, close_others: true
    )
    reader.close
    writer.write("0")
    writer.close

    _, status = Process.wait2(pid)
    assert_equal Hive::ExitCodes::TEMPFAIL, status.exitstatus
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end

  def test_child_continues_only_after_registration_acknowledgement
    reader, writer = IO.pipe
    output_r, output_w = IO.pipe
    reader.close_on_exec = false
    env = { "HIVE_LAUNCH_GATE_FD" => reader.fileno.to_s }
    pid = Process.spawn(
      env, RbConfig.ruby, File.expand_path("../../bin/hive", __dir__), "--version",
      reader.fileno => reader.fileno, out: output_w, err: File::NULL, close_others: true
    )
    reader.close
    output_w.close
    writer.write("1")
    writer.close

    output = output_r.read
    _, status = Process.wait2(pid)
    assert status.success?
    assert_match(/\A\d+\.\d+\.\d+/, output)
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
    output_r&.close unless output_r&.closed?
    output_w&.close unless output_w&.closed?
  end
end
