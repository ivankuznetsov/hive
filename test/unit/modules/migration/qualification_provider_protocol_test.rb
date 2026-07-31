require "test_helper"
require "hive/modules/migration/qualification_provider_protocol"

class ModulesMigrationQualificationProviderProtocolTest <
    Minitest::Test
  PROTOCOL =
    Hive::Modules::Migration::QualificationProviderProtocol

  def test_request_and_success_response_are_canonical_and_context_bound
    request = build_request
    loaded = PROTOCOL.load_request(
      PROTOCOL.canonical(request.to_h)
    )

    assert_equal request.to_h, loaded.to_h
    assert_equal "case-one", loaded.case_id
    assert_equal 2, loaded.generation
    assert_match(/\Aprovider-[0-9a-f]{64}\z/, loaded.request_id)

    response = PROTOCOL.build_ok_response(
      request: loaded,
      output_sha256: "d" * 64
    )
    reloaded = PROTOCOL.load_response(
      PROTOCOL.canonical(response.to_h),
      expected_request_id: loaded.request_id
    )

    assert_predicate reloaded, :ok?
    assert_equal "d" * 64, reloaded.output_sha256
    assert_nil reloaded.reason
  end

  def test_request_identity_changes_for_every_host_session_dimension
    baseline = build_request
    changes = [
      { session: "session-#{"b" * 64}" },
      { case_id: "case-two" },
      { generation: 3 },
      { scenario_request_sha256: "c" * 64 },
      { prompt: "different prompt" },
      {
        output_ref:
          "sandbox/repository/.hive-state/other/findings.json"
      }
    ]

    ids = changes.map do |change|
      build_request(**change).request_id
    end

    refute_includes ids, baseline.request_id
    assert_equal ids.length, ids.uniq.length
  end

  def test_error_response_has_closed_reason_and_no_provider_prose
    request = build_request
    response = PROTOCOL.build_error_response(
      request_id: request.request_id,
      reason: "provider_rate_limited"
    )
    loaded = PROTOCOL.load_response(
      PROTOCOL.canonical(response.to_h),
      expected_request_id: request.request_id
    )

    refute_predicate loaded, :ok?
    assert_equal "provider_rate_limited", loaded.reason
    refute_includes PROTOCOL.canonical(loaded.to_h), "secret"

    assert_raises(Hive::ConfigError) do
      PROTOCOL.build_error_response(
        request_id: request.request_id,
        reason: "429: secret provider message"
      )
    end
  end

  def test_protocol_rejects_unknown_noncanonical_over_cap_and_unsafe_output
    request = build_request.to_h
    mutations = [
      request.merge("unknown" => true),
      request.merge("session" => "wrong"),
      request.merge("generation" => 0),
      request.merge("scenario_request_sha256" => "short"),
      request.merge(
        "output_ref" =>
          "sandbox/repository/.hive-state/../../findings.json"
      )
    ]
    mutations.each do |payload|
      assert_raises(Hive::ConfigError) do
        PROTOCOL.load_request(PROTOCOL.canonical(payload))
      end
    end
    assert_raises(Hive::ConfigError) do
      PROTOCOL.load_request(JSON.pretty_generate(request))
    end
    assert_raises(Hive::ConfigError) do
      PROTOCOL.load_request(
        "x" * (PROTOCOL::MAX_FRAME_BYTES + 1)
      )
    end
  end

  def test_content_is_canonicalized_and_root_is_kind_specific
    bytes = PROTOCOL.canonical_content(
      "{ \"findings\" : [] }",
      kind: "ordinary_findings"
    )

    assert_equal "{\"findings\":[]}\n", bytes
    assert_raises(Hive::ConfigError) do
      PROTOCOL.canonical_content(
        '{"theses":[]}',
        kind: "ordinary_findings"
      )
    end
  end

  private

  def build_request(
    session: "session-#{"a" * 64}",
    case_id: "case-one",
    generation: 2,
    scenario_request_sha256: "b" * 64,
    prompt: "review this fixture",
    output_ref:
      "sandbox/repository/.hive-state/patrol/run/findings.json"
  )
    PROTOCOL.build_request(
      session: session,
      case_id: case_id,
      generation: generation,
      scenario_request_sha256:
        scenario_request_sha256,
      kind: "ordinary_findings",
      prompt: prompt,
      context_refs: [
        "sandbox/repository/lib/example.rb"
      ],
      output_ref: output_ref
    )
  end
end
