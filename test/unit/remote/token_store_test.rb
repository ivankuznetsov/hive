# frozen_string_literal: true

require "test_helper"
require "hive/remote/token_store"
require "hive/remote/protocol"

class RemoteTokenStoreTest < Minitest::Test
  include HiveTestHelper

  def test_default_owner_loader_maps_blank_validation_to_setup_guidance_and_preserves_other_errors
    with_tmp_global_config do
      path = Hive::Config.global_config_path
      [ "", "  ", "operator" ].each do |owner|
        File.write(path, { "web" => { "github" => { "owner" => owner } } }.to_yaml)
        if owner == "operator"
          issued = Hive::Remote::TokenStore.new.create(name: "owner", scopes: [], all_projects: true)
          assert issued.fetch("token")
        else
          assert_equal "api_unavailable_owner_blank", Hive::Remote::Protocol.interlock(mutation: false)
          error = assert_raises(Hive::ConfigError) { Hive::Remote::TokenStore.new.create(name: "blank", scopes: [], all_projects: true) }
          assert_includes error.message, "configure a non-blank web.github.owner"
        end
      end
      File.write(path, { "web" => { "github" => { "owner" => "operator", "client_id" => "" } } }.to_yaml)
      error = assert_raises(Hive::ConfigError) { Hive::Remote::TokenStore.new.create(name: "invalid", scopes: [], all_projects: true) }
      assert_includes error.message, "web.github.client_id"
      assert_equal "api_unavailable_configuration", Hive::Remote::Protocol.interlock(mutation: false)
    end
  end

  def with_store
    Dir.mktmpdir do |root|
      project = { "name" => "demo", "registration_id" => "registration", "path" => root,
                  "hive_state_path" => root, "repository_identity" => "repo" }
      now = Time.utc(2030, 1, 1)
      store = Hive::Remote::TokenStore.new(root: File.join(root, "tokens"),
        projects: -> { [ project ] }, owner: -> { "operator" }, clock: -> { now })
      yield store, project, now
    end
  end

  def test_secret_is_revealed_once_and_registry_is_private
    with_store do |store, _project, _now|
      issued = store.create(name: "reader", scopes: [ "read" ], projects: [ "demo" ])
      bearer = issued.fetch("token")
      assert_match(/\A[0-9a-f]{24}\.[0-9a-f]{64}\z/, bearer)
      assert_equal [ "read" ], store.authenticate(bearer).fetch("scopes")
      refute_includes File.read(store.path), bearer.split(".").last
      refute_includes JSON.generate(store.list), bearer
      assert_equal 0o600, File.stat(store.path).mode & 0o777
      assert_equal 0o700, File.stat(File.dirname(store.path)).mode & 0o777
      assert_nil store.authenticate("#{issued.fetch('id')}.#{'0' * 64}")
      store.revoke(issued.fetch("id"))
      assert_nil store.authenticate(bearer)
      assert_equal 0o600, File.stat(store.path).mode & 0o777
    end
  end

  def test_expiry_and_all_scopes_are_independent
    with_store do |store, _project, now|
      %w[read create act answer].each do |scope|
        issued = store.create(name: scope, scopes: [ scope ], all_projects: true,
                              expires_at: (now + 1).iso8601)
        assert_equal [ scope ], store.authenticate(issued.fetch("token")).fetch("scopes")
      end
      assert_raises(Hive::UsageError) { store.create(name: "bad", scopes: [ "admin" ], all_projects: true) }
      assert_raises(Hive::UsageError) { store.create(name: "bad", scopes: [], projects: []) }
      assert_raises(Hive::UsageError) { store.create(name: "bad", scopes: [], projects: [ "other" ]) }
      assert_raises(Hive::UsageError) do
        store.create(name: "bad", scopes: [], all_projects: true, expires_at: now.iso8601)
      end
      issued = store.create(name: "soon", scopes: [], all_projects: true, expires_at: (now + 1).iso8601)
      later = Hive::Remote::TokenStore.new(root: File.dirname(store.path), owner: -> { "operator" }, clock: -> { now + 1 })
      assert_nil later.authenticate(issued.fetch("token"))
      fractional = store.create(name: "fractional", scopes: [], all_projects: true, expires_at: (now + 0.5).iso8601(6))
      assert store.authenticate(fractional.fetch("token"))
    end
  end

  def test_owner_and_future_version_fail_visibly
    with_store do |store, _project, _now|
      store.create(name: "first", scopes: [], all_projects: true)
      data = JSON.parse(File.read(store.path))
      data["schema_version"] = 99
      File.write(store.path, JSON.generate(data))
      error = assert_raises(Hive::ConfigError) { store.list }
      assert_includes error.message, "upgrade"
      ownerless = Hive::Remote::TokenStore.new(root: File.dirname(store.path), owner: -> { "  " })
      error = assert_raises(Hive::ConfigError) { ownerless.create(name: "bad", scopes: [], all_projects: true) }
      assert_includes error.message, "web.github.owner"
    end
  end

  def test_concurrent_issuance_preserves_records
    with_store do |store, _project, _now|
      threads = 6.times.map do |index|
        Thread.new { store.create(name: "token-#{index}", scopes: [], all_projects: true) }
      end
      ids = threads.map { |thread| thread.value.fetch("id") }
      assert_equal ids.sort, store.list.map { |row| row.fetch("id") }.sort
    end
  end
end
