# frozen_string_literal: true

require "test_helper"
require "hive/remote/read_service"
require "hive/attempts/api"

class RemoteReadServiceTest < Minitest::Test
  include HiveTestHelper

  def test_question_state_reads_are_literal_bounded_and_contained
    with_tmp_dir do |root|
      folder = File.join(root, "task")
      FileUtils.mkdir_p(folder)
      task = Struct.new(:folder, :state_file).new(folder, File.join(folder, "brainstorm.md"))
      assert_nil Hive::Remote::ReadService.validate_state!(task)
      assert_raises(Hive::InvalidTaskPath) { Hive::Remote::ReadService.validate_state!(task, allow_missing: false) }
      literal = "### Q1. Which token?\n### A1.\n<!-- WAITING -->\n"
      File.write(task.state_file, literal)
      assert_equal literal, Hive::Remote::ReadService.validate_state!(task, strict_text: true)
      File.binwrite(task.state_file, "x" * (Hive::Remote::ReadService::STATE_BYTES + 1))
      assert_equal 413, assert_raises(Hive::Remote::Error) { Hive::Remote::ReadService.validate_state!(task) }.status
      [ "bad\xff".b, "binary\0text" ].each do |bytes|
        File.binwrite(task.state_file, bytes)
        error = assert_raises(Hive::Remote::Error) { Hive::Remote::ReadService.validate_state!(task, strict_text: true) }
        assert_equal 503, error.status
        refute_includes error.message, root
      end
      File.unlink(task.state_file)
      outside = File.join(root, "outside.md")
      File.write(outside, "private sentinel")
      File.symlink(outside, task.state_file)
      assert_equal 503, assert_raises(Hive::Remote::Error) { Hive::Remote::ReadService.validate_state!(task) }.status
      task.state_file = outside
      assert_equal 503, assert_raises(Hive::Remote::Error) { Hive::Remote::ReadService.validate_state!(task) }.status
    end
  end

  def test_nonregular_state_cannot_block_a_remote_reader
    with_tmp_dir do |root|
      state = File.join(root, "brainstorm.md")
      File.mkfifo(state)
      task = Struct.new(:folder, :state_file).new(root, state)
      error = assert_raises(Hive::Remote::Error) { Hive::Remote::ReadService.validate_state!(task) }
      assert_equal 503, error.status
    end
  end

  def test_correlated_logs_redact_then_apply_a_valid_utf8_byte_cap
    service = Hive::Remote::ReadService.new
    reference = { "size" => 1_000_000, "opaque" => "reference" }
    service.define_singleton_method(:task) { |**| { "diagnostic" => { "log" => { "reference" => reference } } } }
    secret = "ghp_#{'A' * 36}"
    log = { "tail" => "#{secret}\né" * 1000 }
    reader = Object.new
    reader.define_singleton_method(:read) do |received|
      raise "wrong correlation reference" unless received == reference
      log
    end
    api = Struct.new(:correlated_log_reader).new(reader)
    with_api(api) do
      result = service.logs(project: {}, task: nil, max_bytes: 65)
      assert_equal "available", result.fetch("state")
      assert_operator result.fetch("content").bytesize, :<=, 65
      assert result.fetch("content").valid_encoding?
      assert result.fetch("truncated")
      refute_includes result.fetch("content"), secret
      assert_includes result.fetch("content"), "[REDACTED:github_token]"
      log = { "tail" => "https://user:pass@host/path #{'a' * 24}.#{'b' * 64}" }
      scrubbed = service.logs(project: {}, task: nil).fetch("content")
      refute_includes scrubbed, "user:pass"
      refute_includes scrubbed, "#{'a' * 24}.#{'b' * 64}"
      assert_nil result.fetch("continuation")
      assert_operator service.logs(project: {}, task: nil, max_bytes: 1_000_000).fetch("content").bytesize, :<=, 256 * 1024
      [ 0, -1, "bad", nil ].each do |limit|
        assert_raises(Hive::UsageError) { service.logs(project: {}, task: nil, max_bytes: limit) }
      end
      log = nil
      assert_equal "unavailable", service.logs(project: {}, task: nil).fetch("state")
    end
  end

  private

  def with_api(api)
    original = Hive::Attempts::API.method(:new)
    Hive::Attempts::API.define_singleton_method(:new) { |**| api }
    yield
  ensure
    Hive::Attempts::API.define_singleton_method(:new, original)
  end
end
