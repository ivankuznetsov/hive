require "test_helper"
require "hive/screenote/credential_store"

class ScreenoteCredentialStoreTest < Minitest::Test
  include HiveTestHelper

  def test_save_load_present_and_clear_round_trip_with_secure_mode
    with_tmp_dir do |dir|
      with_env("HIVE_HOME" => dir) do
        store = Hive::Screenote::CredentialStore.new
        data = store.save(
          access_token: "token",
          expires_at: "2027-06-22T12:00:00Z",
          nested: { project_id: "proj_123" },
          scopes: [ :mcp_read, "mcp_write" ]
        )

        assert_equal File.join(dir, "screenote.json"), store.path
        assert_equal "token", data["access_token"]
        assert_equal "proj_123", data.dig("nested", "project_id")
        assert_equal %w[mcp_read mcp_write], data["scopes"].map(&:to_s)
        assert store.present?
        assert_equal data, store.load
        assert_equal 0o600, File.stat(store.path).mode & 0o777

        File.chmod(0o644, store.path)
        store.save(data.merge("access_token" => "next-token"))
        assert_equal 0o600, File.stat(store.path).mode & 0o777
        assert_equal "next-token", store.load["access_token"]

        store.clear
        refute store.present?
        assert_nil store.load
      end
    end
  end

  def test_expired_treats_boundary_missing_and_invalid_expiry_as_expired
    store = Hive::Screenote::CredentialStore.new(path: "/tmp/nonexistent-screenote.json")
    expires_at = Time.utc(2027, 6, 22, 12, 0, 0)

    refute store.expired?({ "expires_at" => expires_at.iso8601 }, now: expires_at - 1)
    assert store.expired?({ "expires_at" => expires_at.iso8601 }, now: expires_at)
    assert store.expired?({ "expires_at" => "" }, now: expires_at)
    assert store.expired?({ "expires_at" => "not a timestamp" }, now: expires_at)
    assert store.expired?(nil, now: expires_at)
  end

  def test_load_rejects_invalid_json_and_non_object_payloads
    with_tmp_dir do |dir|
      path = File.join(dir, "screenote.json")
      store = Hive::Screenote::CredentialStore.new(path: path)

      File.write(path, "{")
      err = assert_raises(Hive::ConfigError) { store.load }
      assert_match(/invalid JSON/, err.message)

      File.write(path, "[]")
      err = assert_raises(Hive::ConfigError) { store.load }
      assert_match(/must contain a JSON object/, err.message)
    end
  end

  def test_save_rejects_non_hash_credentials
    store = Hive::Screenote::CredentialStore.new(path: "/tmp/nonexistent-screenote.json")

    err = assert_raises(Hive::ConfigError) { store.save([ "token" ]) }
    assert_match(/must be a Hash/, err.message)
  end
end
