# frozen_string_literal: true

require "test_helper"
require "hive/remote/request_boundary"

class RemoteRequestBoundaryTest < Minitest::Test
  class AuditLogger
    attr_reader :messages

    def initialize = @messages = []

    def silence(_level)
      previous = @silenced
      @silenced = true
      yield
    ensure
      @silenced = previous
    end

    def info(message)
      @messages << message unless @silenced
    end
  end

  class ClosingBody
    attr_reader :closed

    def initialize(parts, logger)
      @parts, @logger = parts, logger
    end

    def each(&block) = @parts.each(&block)

    def close
      @closed = true
      @logger.info("untrusted-response-close-secret")
    end
  end

  def test_browser_requests_keep_the_existing_application_boundary
    environment = { "PATH_INFO" => "/login" }
    expected = [ 302, { "location" => "/auth/github" }, [] ]
    boundary = Hive::Remote::RequestBoundary.new(->(env) { assert_same environment, env; expected })
    assert_same expected, boundary.call(environment)
    refute environment.key?("hive.remote.audit")
  end

  def test_api_response_is_closed_under_log_silencing_before_the_only_audit_entry
    logger = AuditLogger.new
    body = ClosingBody.new([ "{", "}" ], logger)
    application = lambda do |environment|
      logger.info("raw bearer-secret 203.0.113.5")
      assert_equal({ "text" => "literal prompt" }, environment.fetch("action_dispatch.request.request_parameters"))
      assert_equal '{"text":"literal prompt"}', environment.fetch("rack.input").read
      environment.fetch("hive.remote.audit").merge!("token_id" => "public-id", "operation" => "creations.create", "outcome" => "allowed")
      [ 201, { "content-type" => "application/json" }, body ]
    end
    with_interlock(nil) do
      response = Hive::Remote::RequestBoundary.new(application, logger: logger).call(env(body: '{"text":"literal prompt"}'))
      assert_equal 201, response[0]
      assert_equal [ "{}" ], response[2]
    end
    assert body.closed
    assert_equal 1, logger.messages.length
    audit = JSON.parse(logger.messages.first)
    assert_equal %w[operation outcome project token_id], audit.keys.sort
    assert_equal "public-id", audit.fetch("token_id")
    refute_match(/secret|203\.0\.113|literal prompt/, logger.messages.join)
  end

  def test_unknown_base_paths_are_typed_and_do_not_reach_the_application
    %w[/api /api/v0/context /api/v2/projects/demo/tasks].each do |path|
      response, audit = rejected(env(path: path))
      assert_equal 404, response[0]
      assert_equal "unsupported_version", JSON.parse(response[2].join).dig("error", "code")
      assert_equal [ "/api/v1" ], JSON.parse(response[2].join).dig("error", "served_base_paths")
      assert_equal "unsupported_version", audit.fetch("outcome")
    end
  end

  def test_all_interlocks_have_byte_identical_responses_and_private_distinct_audits
    responses = %w[api_unavailable_owner_blank api_unavailable_loopback_bypass api_unavailable_receipts_absent].map do |reason|
      response, audit = rejected(env, interlock: reason)
      assert_equal 503, response[0]
      assert_equal reason, audit.fetch("outcome")
      response
    end
    assert_equal 1, responses.map { |response| response[2].join }.uniq.length
  end

  def test_raw_and_declared_body_limits_reject_before_parsing_or_domain_dispatch
    cap = Hive::Remote::Protocol::MAX_MUTATION_BYTES
    [ env(body: "x" * (cap + 1)), env(body: "{}", length: (cap + 1).to_s) ].each do |environment|
      response, audit = rejected(environment)
      assert_equal 413, response[0]
      assert_equal "too_large", JSON.parse(response[2].join).dig("error", "code")
      assert_equal "body_too_large", audit.fetch("outcome")
    end
  end

  def test_only_json_objects_are_mutation_inputs
    [ env(body: "{"), env(body: "[]"), env(body: "null"), env(body: "{}", content_type: "text/plain") ].each do |environment|
      response, audit = rejected(environment)
      assert_equal 400, response[0]
      assert_equal "malformed_input", audit.fetch("outcome")
    end
    with_interlock(nil) do
      application = ->(_env) { [ 200, {}, [ "{}" ] ] }
      response = Hive::Remote::RequestBoundary.new(application, logger: AuditLogger.new).call(env(method: "GET", body: "not JSON"))
      assert_equal 200, response[0]
    end
  end

  def test_oversized_application_response_is_replaced_and_closed_without_leaking_content
    logger = AuditLogger.new
    body = ClosingBody.new([ "x" * Hive::Remote::Protocol::MAX_RESPONSE_BYTES, "secret" ], logger)
    with_interlock(nil) do
      response = Hive::Remote::RequestBoundary.new(->(_env) { [ 200, {}, body ] }, logger: logger).call(env(method: "GET"))
      assert_equal 503, response[0]
      assert_equal Hive::Remote::Protocol.unavailable, JSON.parse(response[2].join)
    end
    assert body.closed
    assert_equal "response_too_large", JSON.parse(logger.messages.fetch(0)).fetch("outcome")
    refute_includes logger.messages.join, "secret"
  end

  def test_framework_parameter_errors_have_a_safe_typed_response
    # The native bundle has no Rails dependency. Supply just its exception
    # interface; the web controller suite separately exercises real Rails.
    created = !Object.const_defined?(:ActionDispatch)
    dispatch = created ? Object.const_set(:ActionDispatch, Module.new) : ActionDispatch
    unless dispatch.const_defined?(:Http)
      dispatch.const_set(:Http, Module.new)
      dispatch::Http.const_set(:Parameters, Module.new)
      dispatch::Http::Parameters.const_set(:ParseError, Class.new(StandardError))
    end
    logger = AuditLogger.new
    application = ->(_env) { raise ActionDispatch::Http::Parameters::ParseError, "private body secret" }
    with_interlock(nil) do
      response = Hive::Remote::RequestBoundary.new(application, logger: logger).call(env(method: "GET"))
      assert_equal 400, response[0]
      assert_equal "malformed_input", JSON.parse(response[2].join).dig("error", "code")
      refute_includes response[2].join, "private body secret"
    end
    assert_equal "malformed_input", JSON.parse(logger.messages.fetch(0)).fetch("outcome")
  ensure
    Object.send(:remove_const, :ActionDispatch) if created
  end

  private

  def env(path: "/api/v1/projects/demo/tasks", method: "POST", body: "{}", length: "", content_type: "application/json")
    { "PATH_INFO" => path, "REQUEST_METHOD" => method, "CONTENT_LENGTH" => length,
      "CONTENT_TYPE" => content_type, "rack.input" => StringIO.new(body),
      "HTTP_AUTHORIZATION" => "Bearer bearer-secret", "REMOTE_ADDR" => "203.0.113.5" }
  end

  def rejected(environment, interlock: nil)
    logger = AuditLogger.new
    application = ->(_env) { flunk "rejected request reached domain application" }
    response = with_interlock(interlock) do
      Hive::Remote::RequestBoundary.new(application, logger: logger).call(environment)
    end
    [ response, JSON.parse(logger.messages.fetch(0)) ]
  end

  def with_interlock(reason)
    protocol = Hive::Remote::Protocol
    original = protocol.method(:interlock)
    protocol.define_singleton_method(:interlock) { |**| reason }
    yield
  ensure
    protocol.define_singleton_method(:interlock, original)
  end
end
