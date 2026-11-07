# frozen_string_literal: true

require "test_helper"
require "hive/remote/protocol"

class RemoteProtocolTest < Minitest::Test
  include HiveTestHelper

  def test_owner_and_loopback_interlocks_use_current_configuration_and_boolean_precedence
    with_tmp_global_config do
      with_env("HIVE_WEB_LOCAL_LOOPBACK" => nil, "HIVEBOX_LOCAL_LOOPBACK" => nil) do
        configure(owner: nil)
        assert_equal "api_unavailable_owner_blank", check
        configure(owner: "operator")
        assert_nil check
        with_env("HIVEBOX_LOCAL_LOOPBACK" => "1") do
          assert_equal "api_unavailable_loopback_bypass", check
          with_env("HIVE_WEB_LOCAL_LOOPBACK" => "0") { assert_nil check }
        end
        with_env("HIVE_WEB_LOCAL_LOOPBACK" => "1") do
          assert_equal "api_unavailable_loopback_bypass", check
        end
        configure(owner: "operator", local_loopback: true)
        assert_equal "api_unavailable_loopback_bypass", check(local_configuration: true)
        configure(owner: "operator", local_loopback: false)
        assert_nil check(local_configuration: true)
      end
    end
  end

  def test_mutation_receipt_interlock_is_independent_of_read_availability
    with_tmp_global_config do
      configure(owner: "operator")
      with_env("HIVE_WEB_LOCAL_LOOPBACK" => "0", "HIVEBOX_LOCAL_LOOPBACK" => nil) do
        sentinel = Object.new
        original = Hive::CommandOperation.method(:receipts_installed?)
        Hive::CommandOperation.define_singleton_method(:receipts_installed?) do |store|
          raise "unexpected receipt store" unless store.equal?(sentinel)
          false
        end
        assert_nil check(store: sentinel)
        assert_equal "api_unavailable_receipts_absent", check(mutation: true, store: sentinel)
        Hive::CommandOperation.define_singleton_method(:receipts_installed?) { |_store| true }
        assert_nil check(mutation: true, store: sentinel)
      ensure
        Hive::CommandOperation.define_singleton_method(:receipts_installed?, original)
      end
    end
  end

  def test_invalid_configuration_has_a_static_wire_response_without_exception_details
    with_tmp_global_config do
      File.write(Hive::Config.global_config_path, { "web" => { "port" => "secret-invalid-port" } }.to_yaml)
      assert_equal "api_unavailable_configuration", check
      payload = Hive::Remote::Protocol.unavailable
      assert_equal "hive-remote", payload.fetch("schema")
      assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-remote"), payload.fetch("schema_version")
      assert_nil payload.fetch("instance_id")
      assert_equal({ "code" => "unavailable", "message" => "remote API is unavailable" }, payload.fetch("error"))
      refute_includes JSON.generate(payload), "secret-invalid-port"
    end
  end

  def test_unreadable_configuration_fails_closed
    original = Hive::Config.method(:load_global_web)
    Hive::Config.define_singleton_method(:load_global_web) { raise Errno::EACCES, "/private/config" }
    assert_equal "api_unavailable_configuration", check
    refute_includes JSON.generate(Hive::Remote::Protocol.unavailable), "/private/config"
  ensure
    Hive::Config.define_singleton_method(:load_global_web, original)
  end

  private

  def configure(owner:, local_loopback: false)
    github = owner ? { "owner" => owner } : {}
    File.write(Hive::Config.global_config_path, {
      "web" => { "local_loopback" => local_loopback, "github" => github }
    }.to_yaml)
  end

  def check(**options)
    Hive::Remote::Protocol.interlock(mutation: false, **options)
  end
end
