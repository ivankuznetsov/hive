require "test_helper"
require "hive/commands/web"

# Security gates for `hive web` bind handling (R6/R7/AE4): the loopback
# classifier and the non-loopback refuse / owner-bypass / --unsafe policy.
class WebBindPolicyTest < Minitest::Test
  include HiveTestHelper

  def web(unsafe: false)
    Hive::Commands::Web.new(unsafe: unsafe)
  end

  def cfg(owner: nil, origin: "http://127.0.0.1:4567")
    { "origin" => origin, "github" => { "owner" => owner } }
  end

  def test_loopback_bind_classification
    command = web
    %w[127.0.0.1 127.5.5.5 localhost ::1].each do |bind|
      assert command.send(:loopback_bind?, bind), "#{bind} should be loopback"
    end
    %w[0.0.0.0 192.168.1.10 10.0.0.1 example.com].each do |bind|
      refute command.send(:loopback_bind?, bind), "#{bind} should not be loopback"
    end
  end

  def test_loopback_bind_is_always_allowed
    out, err = capture_io do
      assert_nil web.send(:enforce_bind_policy!, "127.0.0.1", cfg)
    end
    assert_equal "", out
    assert_equal "", err
  end

  def test_non_loopback_without_owner_is_refused
    error = assert_raises(Hive::InvalidTaskPath) do
      web.send(:enforce_bind_policy!, "0.0.0.0", cfg(owner: nil))
    end
    assert_match(/refusing to bind/, error.message)
  end

  def test_non_loopback_with_owner_is_allowed_but_warns_without_https
    _out, err = capture_io do
      assert_nil web.send(:enforce_bind_policy!, "0.0.0.0", cfg(owner: "alice"))
    end
    assert_match(/WARNING binding 0\.0\.0\.0 without an https origin/, err)
  end

  def test_non_loopback_with_unsafe_bypasses_owner_gate_and_warns
    _out, err = capture_io do
      assert_nil web(unsafe: true).send(:enforce_bind_policy!, "0.0.0.0", cfg(owner: nil))
    end
    assert_match(/WARNING binding 0\.0\.0\.0/, err)
  end

  def test_https_origin_suppresses_public_bind_warning
    _out, err = capture_io do
      web.send(:enforce_bind_policy!, "0.0.0.0", cfg(owner: "alice", origin: "https://hive.example"))
    end
    refute_match(/WARNING/, err)
  end
end
