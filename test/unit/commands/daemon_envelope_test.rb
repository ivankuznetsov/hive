require "test_helper"
require "hive/commands/daemon"

# EnvelopeEmitter contract for `hive daemon enable/disable --json`.
# Integration tests cover every USAGE-class kind (missing_project,
# unknown_project, project_and_all, not_initialised, no_projects) and
# the CONFIG kind (malformed YAML). The INTERNAL kind is harder to
# trigger from a subprocess because it requires a genuinely unexpected
# exception in production code — exactly what should never happen via
# normal CLI input. This unit test proves the envelope contract still
# holds when the failure path IS reached, by stubbing one collaborator
# to raise StandardError.
class HiveCommandsDaemonEnvelopeTest < Minitest::Test
  include HiveTestHelper

  # Verifies the StandardError → InternalError → envelope chain the
  # EnvelopeEmitter mixin promises in lib/hive.rb. Without this test,
  # a refactor of call_with_envelope could silently lose the envelope
  # on uncategorised crashes; agent retry wrappers branching on
  # `error_kind` would see plain stderr and fall through to their
  # generic-failure branch.
  def test_unexpected_standard_error_emits_internal_envelope_and_raises
    Dir.mktmpdir("hive-envelope-test") do |home|
      daemon = Hive::Commands::Daemon.new("enable", "proj", json: true, hive_home: home)
      # Stub the very first collaborator the JSON path hits so the
      # exception fires inside call_with_envelope's StandardError
      # rescue but BEFORE any successful stdout write — exactly the
      # window EnvelopeEmitter exists to protect.
      daemon.define_singleton_method(:resolve_enable_targets) do
        raise "synthesised collaborator failure"
      end

      out, _err = capture_io do
        err = assert_raises(Hive::InternalError) { daemon.call }
        assert_match(/synthesised collaborator failure/, err.message,
                     "InternalError must wrap and preserve the original message")
        assert_equal Hive::ExitCodes::SOFTWARE, err.exit_code,
                     "InternalError must map to exit code 70 (SOFTWARE)"
      end

      doc = JSON.parse(out)
      assert_equal "hive-daemon-enroll", doc["schema"]
      assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-daemon-enroll"),
                   doc["schema_version"]
      assert_equal false, doc["ok"]
      assert_equal "InternalError", doc["error_class"]
      assert_equal Hive::Schemas::EnrollErrorKind::INTERNAL, doc["error_kind"]
      assert_equal Hive::ExitCodes::SOFTWARE, doc["exit_code"]
      assert_match(/synthesised collaborator failure/, doc["message"])
    end
  end

  # Symmetric coverage for the disable path so a future divergence in
  # subcommand routing can't break one verb's envelope contract while
  # leaving the other intact.
  def test_unexpected_standard_error_during_disable_emits_internal_envelope
    Dir.mktmpdir("hive-envelope-test") do |home|
      daemon = Hive::Commands::Daemon.new("disable", "proj", json: true, hive_home: home)
      daemon.define_singleton_method(:resolve_enable_targets) do
        raise StandardError, "disable-side collaborator failure"
      end

      out, _err = capture_io do
        assert_raises(Hive::InternalError) { daemon.call }
      end

      doc = JSON.parse(out)
      assert_equal "hive-daemon-enroll", doc["schema"]
      assert_equal Hive::Schemas::EnrollErrorKind::INTERNAL, doc["error_kind"]
    end
  end

  # Without --json, the same internal failure must still raise
  # InternalError but emit NO JSON to stdout (the bare-text path goes
  # to stderr via the CLI's top-level rescue). Pins that EnvelopeEmitter
  # only writes to stdout when @json is set.
  def test_unexpected_standard_error_without_json_does_not_write_envelope_to_stdout
    Dir.mktmpdir("hive-envelope-test") do |home|
      daemon = Hive::Commands::Daemon.new("enable", "proj", json: false, hive_home: home)
      daemon.define_singleton_method(:resolve_enable_targets) do
        raise "collaborator boom"
      end

      out, _err = capture_io do
        assert_raises(Hive::InternalError) { daemon.call }
      end

      assert_empty out.strip,
                   "non-JSON path must not write a JSON envelope to stdout " \
                   "(envelope is only emitted when --json is passed)"
    end
  end

  # Internal-envelope coverage for failure modes AFTER preflight — the
  # earlier three stubs only fire `resolve_enable_targets` to raise,
  # which is BEFORE write_daemon_block. A real ENOSPC / EXDEV from
  # File.rename would surface from inside the per-project map loop, so
  # this test stubs `write_daemon_block` to confirm the envelope still
  # fires for the deeper failure surface. Without it, the rescue chain
  # below `call_with_envelope { do_call }` is dead code per tests.
  def test_unexpected_error_after_preflight_emits_internal_envelope
    Dir.mktmpdir("hive-envelope-test") do |home|
      project_root = File.join(home, "proj")
      hive_state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(hive_state)
      File.write(File.join(hive_state, "config.yml"), "default_branch: main\n")
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [
          { "name" => "proj", "path" => project_root, "hive_state_path" => hive_state }
        ]
      }.to_yaml)
      original_home = ENV.fetch("HIVE_HOME", nil)
      begin
        ENV["HIVE_HOME"] = home
        daemon = Hive::Commands::Daemon.new("enable", "proj", json: true, hive_home: home)
        # Stub with a non-Errno error so it bypasses the Errno::* →
        # ConfigError rescue (#12 fix) and tests the GENERIC StandardError
        # path that EnvelopeEmitter's call_with_envelope must catch.
        daemon.define_singleton_method(:write_daemon_block) do |_path, _enabled|
          raise "synthesised opaque write failure"
        end

        out, _err = capture_io do
          assert_raises(Hive::InternalError) { daemon.call }
        end

        doc = JSON.parse(out)
        assert_equal "hive-daemon-enroll", doc["schema"]
        assert_equal Hive::Schemas::EnrollErrorKind::INTERNAL, doc["error_kind"]
        assert_match(/opaque write failure/i, doc["message"],
                     "InternalError must preserve the cause's class name + message")
      ensure
        if original_home.nil?
          ENV.delete("HIVE_HOME")
        else
          ENV["HIVE_HOME"] = original_home
        end
      end
    end
  end


  def test_emit_envelope_marks_stdout_written_when_pipe_is_closed
    emitter = Class.new do
      include Hive::Schemas::EnvelopeEmitter

      def envelope_schema
        "hive-daemon-enroll"
      end

      def envelope_error_kind(_error)
        Hive::Schemas::EnrollErrorKind::INTERNAL
      end

      def puts(_payload)
        raise Errno::EPIPE
      end

      def stdout_written?
        @stdout_written
      end
    end.new

    emitter.send(:emit_envelope, Hive::Error.new("broken pipe"))

    assert emitter.stdout_written?, "closed stdout must still mark the envelope as written"
  end

  def test_emit_envelope_warns_when_payload_is_not_serialisable
    # A non-serialisable payload is a bug, not a closed pipe — the mixin must
    # warn (not silently swallow) while still marking stdout written so the
    # re-raise carries the real failure to bin/hive.
    emitter = Class.new do
      include Hive::Schemas::EnvelopeEmitter

      def envelope_schema
        "hive-daemon-enroll"
      end

      def envelope_error_kind(_error)
        Hive::Schemas::EnrollErrorKind::INTERNAL
      end

      def stdout_written?
        @stdout_written
      end
    end.new

    err = nil
    with_replaced_singleton_method(JSON, :generate, ->(*_args) { raise JSON::GeneratorError, "bad json" }) do
      _out, err = capture_io { emitter.send(:emit_envelope, Hive::Error.new("boom")) }
    end

    assert emitter.stdout_written?, "a non-serialisable payload must still mark the envelope as written"
    assert_match(/error envelope was not serialisable/, err)
  end


  # Disk-class errors during the atomic rewrite (ENOSPC / EROFS / EACCES /
  # EXDEV / EDQUOT / EIO) must surface as Hive::ConfigError (exit 78),
  # mirroring Hive::Config.write_global_config!. Otherwise an agent retry
  # wrapper that branches on `error_kind: config` (exit 78) would treat
  # disk-full as transient and may retry indefinitely. Pre-fix this raised
  # raw Errno::ENOSPC → InternalError (exit 70).
  #
  # We can't stub write_daemon_block to raise Errno::* (the stub
  # override would bypass the very rescue we're testing). So inject a
  # real EACCES via a read-only project directory: File.open(tmp, ...)
  # fails inside the production code path, the production rescue fires.
  def test_eacces_during_write_routes_to_config_error_kind
    skip "running as root, EACCES not enforced" if Process.uid.zero?

    Dir.mktmpdir("hive-envelope-test") do |home|
      project_root = File.join(home, "proj")
      hive_state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(hive_state)
      cfg_path = File.join(hive_state, "config.yml")
      File.write(cfg_path, "default_branch: main\n")
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [
          { "name" => "proj", "path" => project_root, "hive_state_path" => hive_state }
        ]
      }.to_yaml)
      original_home = ENV.fetch("HIVE_HOME", nil)
      original_dir_mode = File.stat(hive_state).mode
      begin
        ENV["HIVE_HOME"] = home
        # Drop write permission on the directory so File.open(tmp, ...)
        # inside write_daemon_block raises Errno::EACCES (production
        # rescue catches and re-raises as ConfigError).
        File.chmod(0o500, hive_state)

        daemon = Hive::Commands::Daemon.new("enable", "proj", json: true, hive_home: home)
        out, _err = capture_io do
          err = assert_raises(Hive::ConfigError) { daemon.call }
          assert_equal Hive::ExitCodes::CONFIG, err.exit_code,
                       "EACCES on parent dir must map to exit 78 (CONFIG), got #{err.exit_code}"
        end

        doc = JSON.parse(out)
        assert_equal "hive-daemon-enroll", doc["schema"]
        assert_equal false, doc["ok"]
        assert_equal "ConfigError", doc["error_class"]
        assert_equal Hive::Schemas::EnrollErrorKind::CONFIG, doc["error_kind"]
        assert_equal Hive::ExitCodes::CONFIG, doc["exit_code"]
        assert_match(/filesystem error/i, doc["message"])
      ensure
        File.chmod(original_dir_mode, hive_state) if File.exist?(hive_state)
        if original_home.nil?
          ENV.delete("HIVE_HOME")
        else
          ENV["HIVE_HOME"] = original_home
        end
      end
    end
  end
end
