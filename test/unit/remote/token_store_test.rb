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

  def test_invalid_names_credentials_and_ambiguous_grants_do_not_issue_a_token
    with_store do |store, project, _now|
      assert_empty store.list
      [ "", "  ", "line\nbreak", "a" * 129, "bad\xff".b ].each do |name|
        assert_raises(Hive::UsageError) { store.create(name: name, scopes: [], all_projects: true) }
      end
      [ nil, "", "not-a-bearer", "#{'a' * 24}.#{'b' * 64}" ].each { |bearer| assert_nil store.authenticate(bearer) }
      assert_raises(Hive::UsageError) { store.revoke("unknown-public-id") }
      assert_raises(Hive::UsageError) { store.create(name: "bad expiry", scopes: [], all_projects: true, expires_at: "tomorrow") }
      assert_raises(Hive::UsageError) { store.create(name: "mixed", scopes: [], all_projects: true, projects: [ "demo" ]) }
      ambiguous = Hive::Remote::TokenStore.new(root: File.dirname(store.path), owner: -> { "operator" },
        projects: -> { [ project, project.dup ] })
      assert_raises(Hive::UsageError) { ambiguous.create(name: "ambiguous", scopes: [], projects: [ "demo" ]) }
      assert_empty store.list
    end
  end

  def test_corrupt_or_invalid_registry_fails_visibly_instead_of_authenticating
    with_store do |store, _project, _now|
      issued = store.create(name: "original", scopes: [ "read" ], all_projects: true)
      data = JSON.parse(File.read(store.path))
      invalid = [ "{", JSON.generate({ "schema_version" => 0, "tokens" => [] }) ]
      missing_timestamp = Marshal.load(Marshal.dump(data))
      missing_timestamp.fetch("tokens").first.delete("created_at")
      invalid << JSON.generate(missing_timestamp)
      bad_timestamp = Marshal.load(Marshal.dump(data))
      bad_timestamp.fetch("tokens").first["expires_at"] = "not a timestamp"
      invalid << JSON.generate(bad_timestamp)
      duplicate = Marshal.load(Marshal.dump(data))
      duplicate.fetch("tokens") << duplicate.fetch("tokens").first.dup
      invalid << JSON.generate(duplicate)
      invalid.each do |bytes|
        File.write(store.path, bytes)
        error = assert_raises(Hive::ConfigError) { store.authenticate(issued.fetch("token")) }
        assert_includes error.message, "invalid API token registry"
        refute_includes error.message, issued.fetch("token")
      end
    end
  end

  def test_registry_permissions_and_symlinks_fail_closed
    with_store do |store, _project, _now|
      store.create(name: "private", scopes: [], all_projects: true)
      File.chmod(0o644, store.path)
      assert_raises(Hive::ConfigError) { store.list }
      File.chmod(0o600, store.path)
      target = "#{store.path}.saved"
      File.rename(store.path, target)
      File.symlink(target, store.path)
      assert_raises(Hive::ConfigError) { store.list }
    end
    with_store do |store, _project, _now|
      directory = File.dirname(store.path)
      FileUtils.mkdir_p("#{directory}.actual")
      File.symlink("#{directory}.actual", directory)
      assert_raises(Hive::ConfigError) { store.list }
    end
    return unless defined?(File::NOFOLLOW)

    with_store do |store, _project, _now|
      directory = File.dirname(store.path)
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "sentinel"), "unchanged")
      File.symlink(File.join(directory, "sentinel"), File.join(directory, ".tokens.lock"))
      assert_raises(Hive::ConfigError) { store.list }
      assert_equal "unchanged", File.read(File.join(directory, "sentinel"))
    end
  end
end
