require "test_helper"
require "json"
require "hive/babysitter/logger"

class BabysitterLoggerTest < Minitest::Test
  include HiveTestHelper

  def test_writes_json_line_events
    with_tmp_dir do |dir|
      path = File.join(dir, "babysitter.log")
      logger = Hive::Babysitter::Logger.new(path: path, max_bytes: 1024, max_files: 2)
      logger.event(:tick_begin, now: "2026-05-26T10:00:00Z")
      logger.close

      doc = JSON.parse(File.read(path))
      assert_equal "hive-babysitter-log", doc.fetch("schema")
      assert_equal "tick_begin", doc.fetch("event")
      assert_equal "2026-05-26T10:00:00Z", doc.fetch("now")
    end
  end

  def test_rejects_unknown_events
    with_tmp_dir do |dir|
      logger = Hive::Babysitter::Logger.new(path: File.join(dir, "babysitter.log"))
      assert_raises(ArgumentError) { logger.event(:bogus) }
    ensure
      logger&.close
    end
  end
end
