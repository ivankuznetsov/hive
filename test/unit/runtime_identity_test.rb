require "test_helper"

class RuntimeIdentityTest < Minitest::Test
  DOGFOOD_SHA = "0864de726d9a75f7bc46610a89db851c90b402ee"

  def test_unannotated_install_is_a_release_runtime
    identity = Hive::RuntimeIdentity.new(
      environment: {
        "HIVE_RUNTIME_BUILD_SHA" => DOGFOOD_SHA,
        "HIVE_RUNTIME_DEPLOYMENT_ID" => "stray-deployment"
      }
    ).to_h

    assert_equal(
      {
        "channel" => "release",
        "release_version" => Hive::VERSION,
        "display_version" => Hive::VERSION,
        "build_sha" => nil,
        "deployment_id" => nil
      },
      identity
    )
  end

  def test_dogfood_runtime_carries_exact_build_and_deployment_identity
    identity = Hive::RuntimeIdentity.new(
      environment: {
        "HIVE_RUNTIME_CHANNEL" => "dogfood",
        "HIVE_RUNTIME_BUILD_SHA" => DOGFOOD_SHA,
        "HIVE_RUNTIME_DEPLOYMENT_ID" => "hive-dogfood-0864de726"
      }
    ).to_h

    assert_equal "dogfood", identity.fetch("channel")
    assert_equal Hive::VERSION, identity.fetch("release_version")
    assert_equal "#{Hive::VERSION}+dogfood.0864de726", identity.fetch("display_version")
    assert_equal DOGFOOD_SHA, identity.fetch("build_sha")
    assert_equal "hive-dogfood-0864de726", identity.fetch("deployment_id")
    assert_equal identity, Hive::RuntimeIdentity.parse(identity)
  end

  def test_invalid_runtime_annotations_degrade_without_echoing_untrusted_values
    identity = Hive::RuntimeIdentity.new(
      environment: {
        "HIVE_RUNTIME_CHANNEL" => "secret-channel",
        "HIVE_RUNTIME_BUILD_SHA" => "not-a-sha",
        "HIVE_RUNTIME_DEPLOYMENT_ID" => "../../untrusted deployment"
      }
    ).to_h

    assert_equal "unknown", identity.fetch("channel")
    assert_equal "#{Hive::VERSION}+unknown", identity.fetch("display_version")
    assert_nil identity.fetch("build_sha")
    assert_nil identity.fetch("deployment_id")
    refute_includes identity.values.compact, "secret-channel"
  end

  def test_incomplete_dogfood_annotations_degrade_to_unknown
    [
      { "HIVE_RUNTIME_BUILD_SHA" => DOGFOOD_SHA },
      { "HIVE_RUNTIME_DEPLOYMENT_ID" => "hive-dogfood-0864de726" },
      {
        "HIVE_RUNTIME_BUILD_SHA" => "not-a-sha",
        "HIVE_RUNTIME_DEPLOYMENT_ID" => "hive-dogfood-0864de726"
      },
      {
        "HIVE_RUNTIME_BUILD_SHA" => DOGFOOD_SHA,
        "HIVE_RUNTIME_DEPLOYMENT_ID" => "../not-safe"
      }
    ].each do |annotations|
      identity = Hive::RuntimeIdentity.new(
        environment: annotations.merge("HIVE_RUNTIME_CHANNEL" => "dogfood")
      ).to_h

      assert_equal "unknown", identity.fetch("channel")
      assert_equal "#{Hive::VERSION}+unknown", identity.fetch("display_version")
      assert_nil identity.fetch("build_sha")
      assert_nil identity.fetch("deployment_id")
    end
  end

  def test_invalidly_encoded_dogfood_annotations_degrade_without_crashing
    invalid = "\xFF".dup.force_encoding(Encoding::UTF_8)
    identity = Hive::RuntimeIdentity.new(
      environment: {
        "HIVE_RUNTIME_CHANNEL" => "dogfood",
        "HIVE_RUNTIME_BUILD_SHA" => invalid,
        "HIVE_RUNTIME_DEPLOYMENT_ID" => invalid
      }
    ).to_h

    assert_equal "unknown", identity.fetch("channel")
    assert_nil identity.fetch("build_sha")
    assert_nil identity.fetch("deployment_id")
    assert JSON.generate(identity)
  end

  def test_parse_rejects_inconsistent_process_identity
    identity = Hive::RuntimeIdentity.new(environment: {}).to_h

    assert_nil Hive::RuntimeIdentity.parse(identity.merge("build_sha" => DOGFOOD_SHA))
    assert_nil Hive::RuntimeIdentity.parse(identity.merge("unexpected" => true))
    assert_nil Hive::RuntimeIdentity.parse(channel: "release")
    assert_equal identity, Hive::RuntimeIdentity.parse(identity.to_a.reverse.to_h)
  end
end
