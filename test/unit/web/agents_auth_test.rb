require "test_helper"
require "json"
require "hive/web/agents_auth"
require "hive/agent_profiles"

class AgentsAuthTest < Minitest::Test
  include HiveTestHelper

  def test_pi_token_writer_rejects_empty_json
    with_tmp_dir do |home|
      with_env("HOME" => home) do
        auth = Hive::Web::AgentsAuth.new

        assert_raises(Hive::Error) { auth.write_pi_token("{}") }
      end
    end
  end

  def test_pi_token_writer_persists_valid_json
    with_tmp_dir do |home|
      with_env("HOME" => home) do
        auth = Hive::Web::AgentsAuth.new
        path = auth.write_pi_token(JSON.generate("provider" => "x"))

        assert_equal File.join(home, ".pi", "agent", "auth.json"), path
        assert Hive::AgentProfiles.logged_in?(:pi, home: home)
      end
    end
  end

  def test_pi_token_writer_rejects_malformed_json
    auth = Hive::Web::AgentsAuth.new
    error = assert_raises(Hive::Error) { auth.write_pi_token("{not json") }

    assert_match(/pi token JSON is invalid/, error.message,
                 "malformed JSON must become a friendly Hive::Error, not an opaque parse crash")
  end

  def test_statuses_reports_each_agents_login_state
    with_tmp_dir do |home|
      with_env("HOME" => home) do
        statuses = Hive::Web::AgentsAuth.new.statuses

        assert_equal %w[claude codex gh pi].sort, statuses.keys.sort,
                     "statuses must cover every supported agent"
        statuses.each_value do |s|
          assert_includes [ true, false ], s["logged_in"], "each status carries a boolean logged_in"
        end
      end
    end
  end

  def test_output_for_returns_a_copy_of_the_session_buffer
    auth = Hive::Web::AgentsAuth.new
    session = Hive::Web::AgentsAuth::Session.new(id: "s", agent: "claude", output: +"hello", done: false)
    auth.instance_variable_get(:@sessions)["s"] = session

    copy = auth.output_for("s")

    assert_equal "hello", copy, "output_for must surface the buffered relay output"
    refute_same session.output, copy, "output_for must hand back a copy, not the live buffer"
    assert_nil auth.output_for("missing"), "an unknown session id yields nil"
  end

  def test_output_for_returns_render_safe_utf8_for_binary_pty_output
    auth = Hive::Web::AgentsAuth.new
    # Raw PTY bytes (readpartial returns ASCII-8BIT): an ANSI clear-line
    # sequence, a box-drawing glyph, and a lone UTF-8 continuation byte left
    # when a 4096-byte read splits a multibyte char. The trailing \xE2 makes
    # the buffer invalid UTF-8 — exactly what raised Encoding::CompatibilityError
    # when the <pre> view interpolated it (the login-status 500).
    binary = +"".b
    binary << "\e[2K".b << "█".b << " login".b << "\xE2".b
    refute binary.dup.force_encoding(Encoding::UTF_8).valid_encoding?,
           "fixture must be invalid UTF-8 so the test actually exercises the scrub"
    session = Hive::Web::AgentsAuth::Session.new(id: "s", agent: "claude", output: binary, done: false)
    auth.instance_variable_get(:@sessions)["s"] = session

    out = auth.output_for("s")

    assert_equal Encoding::UTF_8, out.encoding, "output_for must hand the view a UTF-8 string"
    assert out.valid_encoding?, "invalid bytes must be scrubbed so the <pre> view can't raise"
    # Faithful reproduction of the failing render: a UTF-8 buffer absorbing
    # the value. With a binary buffer this raised Encoding::CompatibilityError.
    rendered = (+"<pre>").force_encoding(Encoding::UTF_8) << out
    assert_includes rendered, "login", "scrubbing must preserve the legible CLI text"
  end

  def test_start_rejects_when_too_many_logins_are_in_flight
    auth = Hive::Web::AgentsAuth.new
    sessions = auth.instance_variable_get(:@sessions)
    Hive::Web::AgentsAuth::MAX_CONCURRENT_LOGINS.times do |i|
      sessions["s#{i}"] = Hive::Web::AgentsAuth::Session.new(
        id: "s#{i}", agent: "claude", output: +"", done: false
      )
    end

    error = assert_raises(Hive::Error) { auth.start("claude") }
    assert_match(/too many login attempts/, error.message,
                 "the concurrency cap must reject a new login once the in-flight ceiling is hit")
  end

  def test_close_io_swallows_an_ioerror
    auth = Hive::Web::AgentsAuth.new
    raising = Object.new
    def raising.closed? = false
    def raising.close = raise(IOError, "already closing")

    # Must not propagate the IOError — fd cleanup is best-effort.
    assert_nil auth.send(:close_io, raising), "close_io must swallow an IOError on close"
  end
end
