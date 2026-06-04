require "test_helper"
require "hive/web/agents_auth"

# U3 relay: the PTY login state machine must spawn the agent CLI, surface the
# provider authorize URL it prints, relay a pasted code back into the waiting
# CLI, and clean up (mark done, close fds) when the CLI exits. Driven against
# a fake `claude` on PATH so no real provider handshake is needed.
class AgentsAuthLoginTest < Minitest::Test
  include HiveTestHelper

  AUTH_URL = "https://login.example/oauth?challenge=abc123".freeze

  def install_fake_claude(bin_dir)
    path = File.join(bin_dir, "claude")
    File.write(path, <<~SH)
      #!/usr/bin/env bash
      # Mimic `claude setup-token`: print an authorize URL, wait for a code,
      # succeed only if a non-empty code is pasted.
      echo "Open #{AUTH_URL} to authenticate"
      read -r code
      if [ -n "$code" ]; then
        echo "token stored"
        exit 0
      fi
      exit 1
    SH
    FileUtils.chmod(0o755, path)
  end

  # Explicit wait (no fixed sleep): poll until the block is truthy or raise.
  def wait_until(timeout: 5.0)
    deadline = monotonic + timeout
    loop do
      value = yield
      return value if value
      raise "condition not met within #{timeout}s" if monotonic > deadline

      sleep 0.02
    end
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def with_fake_claude
    with_tmp_dir do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      install_fake_claude(bin_dir)
      with_env("PATH" => [ bin_dir, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)) do
        yield
      end
    end
  end

  def test_start_surfaces_authorize_url_then_complete_relays_code
    with_fake_claude do
      auth = Hive::Web::AgentsAuth.new
      session = auth.start("claude")

      found = wait_until { auth.session(session.id).url }
      assert_equal AUTH_URL, found, "the authorize URL the CLI printed must be surfaced"

      auth.complete(session.id, "pasted-code")

      wait_until { auth.session(session.id).done }
      assert_nil auth.session(session.id).error, "a relayed valid code must finish without error"
    end
  end

  def test_complete_rejects_empty_code
    with_fake_claude do
      auth = Hive::Web::AgentsAuth.new
      session = auth.start("claude")
      wait_until { auth.session(session.id).url }

      assert_raises(Hive::Error) { auth.complete(session.id, "   ") }
    ensure
      # Drive the spawned CLI to a clean exit so a child blocked on `read`
      # doesn't wedge VM shutdown.
      auth.complete(session.id, "cleanup") rescue nil
      wait_until { auth.session(session.id).nil? || auth.session(session.id).done } rescue nil
    end
  end

  def test_unknown_agent_raises
    auth = Hive::Web::AgentsAuth.new
    assert_raises(Hive::InvalidTaskPath) { auth.start("nope") }
  end
end
