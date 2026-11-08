require "test_helper"

class InternalErrorWrapTest < Minitest::Test
  def test_sqlite_busy_becomes_retryable_concurrent_run_error
    busy = begin
      begin
        raise SQLite3::BusyException, "database is locked"
      rescue SQLite3::BusyException
        raise Sequel::DatabaseError, "SQLite3::BusyException: database is locked"
      end
    rescue Sequel::DatabaseError => e
      e
    end

    wrapped = Hive::InternalError.wrap(busy)

    assert_instance_of Hive::ConcurrentRunError, wrapped
    assert_equal Hive::ExitCodes::TEMPFAIL, wrapped.exit_code
    assert_match(/runtime database busy/, wrapped.message)
  end

  def test_other_unexpected_errors_stay_internal
    wrapped = Hive::InternalError.wrap(ArgumentError.new("bad input"))

    assert_instance_of Hive::InternalError, wrapped
    assert_equal Hive::ExitCodes::SOFTWARE, wrapped.exit_code
    assert_equal "internal error: ArgumentError: bad input", wrapped.message
  end
end
