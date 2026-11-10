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

  def test_locked_message_alone_never_changes_error_classification
    [ RuntimeError, Sequel::DatabaseError ].each do |error_class|
      error = error_class.new("database is locked")
      refute Hive::InternalError.sqlite_busy?(error)
      wrapped = Hive::InternalError.wrap(error)
      assert_instance_of Hive::InternalError, wrapped
      assert_equal Hive::ExitCodes::SOFTWARE, wrapped.exit_code
    end
  end

  def test_wrapper_uses_sqlite_primary_busy_code_without_message_inference
    { 5 => true, 517 => true, 1 => false, 6 => false, nil => false }.each do |code, busy|
      driver = SQLite3::Exception.new("opaque SQLite error")
      driver.define_singleton_method(:code) { code }
      sequel = Sequel::DatabaseError.new("query failed")
      sequel.define_singleton_method(:wrapped_exception) { driver }
      assert_equal busy, Hive::InternalError.sqlite_busy?(sequel)
      expected = busy ? Hive::ConcurrentRunError : Hive::InternalError
      assert_instance_of expected, Hive::InternalError.wrap(sequel)
    end
    impostor = RuntimeError.new("opaque error")
    impostor.define_singleton_method(:code) { 5 }
    refute Hive::InternalError.sqlite_busy?(impostor)
  end

  def test_exception_chain_visits_unique_nodes_and_stops_at_the_bound
    first = RuntimeError.new("first")
    second = RuntimeError.new("second")
    first.define_singleton_method(:cause) { second }
    first.define_singleton_method(:wrapped_exception) { second }
    second.define_singleton_method(:cause) { first }
    assert_equal [ first, second ], Hive::InternalError.exception_chain(first)

    chain = Array.new(17) { RuntimeError.new("wrapper") }
    chain << SQLite3::BusyException.new("busy")
    chain.each_cons(2) { |error, cause| error.define_singleton_method(:cause) { cause } }
    assert_equal chain.take(16), Hive::InternalError.exception_chain(chain.first)
    refute Hive::InternalError.sqlite_busy?(chain.first)
    assert_equal [], Hive::InternalError.exception_chain(nil)
  end
end
