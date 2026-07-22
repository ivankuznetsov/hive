require "test_helper"
require "hive/web/environment"

class WebEnvironmentTest < Minitest::Test
  SETTINGS = {
    "HIVE_WEB_APP_DIR" => "HIVEBOX_WEB_APP_DIR",
    "HIVE_WEB_ORIGIN" => "HIVEBOX_ORIGIN",
    "HIVE_WEB_STORAGE_DIR" => "HIVEBOX_STORAGE_DIR",
    "HIVE_WEB_LOCAL_LOOPBACK" => "HIVEBOX_LOCAL_LOOPBACK",
    "HIVE_WEB_DIFF_TIMEOUT_SEC" => "HIVEBOX_DIFF_TIMEOUT_SEC",
    "HIVE_WEB_CLONE_TIMEOUT_SEC" => "HIVEBOX_CLONE_TIMEOUT_SEC"
  }.freeze

  CONTAINER_ONLY = %w[
    HIVEBOX_IMAGE
    HIVEBOX_NAME
    HIVEBOX_BIND
    HIVEBOX_PORT
    HIVEBOX_DATA
    HIVEBOX_REPOS_DIR
    HIVEBOX_SESSION_SECRET
    HIVEBOX_SUPERVISOR_PID
  ].freeze

  def test_complete_precedence_and_warning_matrix_for_every_mapping
    SETTINGS.each do |canonical, legacy|
      assert_equal "fallback", value(canonical, {}, default: "fallback")
      assert_empty warnings(canonical => "", legacy => " ")

      assert_equal "new", value(canonical, { canonical => "new", legacy => "" })
      assert_empty warnings(canonical => "new", legacy => "")

      assert_equal "old", value(canonical, { legacy => "old" })
      old_warning = warnings(legacy => "old").fetch(0)
      assert_equal legacy, old_warning.fetch("alias")
      assert_equal canonical, old_warning.fetch("replacement")
      assert_equal false, old_warning.fetch("ignored")
      assert_match(/next major release/, old_warning.fetch("message"))

      %w[same old].each do |legacy_value|
        environment = { canonical => "same", legacy => legacy_value }
        assert_equal "same", value(canonical, environment)
        warning = warnings(environment).fetch(0)
        assert_equal true, warning.fetch("ignored")
        assert_match(/ignored/, warning.fetch("message"))
      end

      assert_equal "not-valid-for-the-consumer",
                   value(canonical, {
                     canonical => "not-valid-for-the-consumer",
                     legacy => "valid-legacy-value"
                   }),
                   "a nonblank canonical value must win even when the consumer rejects it"
    end
  end

  def test_repeated_reads_do_not_duplicate_warning_inventory
    environment = { "HIVEBOX_ORIGIN" => "https://old.example" }

    3.times { Hive::Web::Environment.value("HIVE_WEB_ORIGIN", environment: environment) }

    assert_equal 1, Hive::Web::Environment.warnings(environment: environment).length
  end

  def test_container_only_hivebox_settings_never_warn
    environment = CONTAINER_ONLY.to_h { |name| [ name, "configured" ] }

    assert_empty Hive::Web::Environment.warnings(environment: environment)
  end

  def test_emit_warnings_is_deduplicated_and_actionable
    output = StringIO.new
    environment = {
      "HIVEBOX_ORIGIN" => "https://old.example",
      "HIVE_WEB_ORIGIN" => "https://new.example",
      "HIVEBOX_STORAGE_DIR" => "/old/storage"
    }

    emitted = Hive::Web::Environment.emit_warnings(
      environment: environment,
      output: output,
      prefix: "hive web"
    )

    assert_equal 2, emitted.length
    assert_equal 1, output.string.scan("HIVEBOX_ORIGIN").length
    assert_equal 1, output.string.scan("HIVEBOX_STORAGE_DIR").length
    assert_includes output.string, "HIVE_WEB_ORIGIN"
    assert_includes output.string, "HIVE_WEB_STORAGE_DIR"
  end

  def test_boolean_accepts_documented_forms_and_rejects_invalid_canonical_value
    %w[1 true yes on].each do |selected|
      assert_equal true, Hive::Web::Environment.boolean(
        "HIVE_WEB_LOCAL_LOOPBACK", environment: { "HIVE_WEB_LOCAL_LOOPBACK" => selected }
      )
    end
    %w[0 false no off].each do |selected|
      assert_equal false, Hive::Web::Environment.boolean(
        "HIVE_WEB_LOCAL_LOOPBACK", environment: { "HIVE_WEB_LOCAL_LOOPBACK" => selected }
      )
    end
    assert_equal true, Hive::Web::Environment.boolean(
      "HIVE_WEB_LOCAL_LOOPBACK", environment: {}, default: true
    )

    error = assert_raises(Hive::Error) do
      Hive::Web::Environment.boolean(
        "HIVE_WEB_LOCAL_LOOPBACK",
        environment: {
          "HIVE_WEB_LOCAL_LOOPBACK" => "invalid",
          "HIVEBOX_LOCAL_LOOPBACK" => "true"
        }
      )
    end
    assert_match(/HIVE_WEB_LOCAL_LOOPBACK must be one of/, error.message)
  end

  def test_service_resolution_enables_bypass_only_for_an_enabled_loopback_bind
    loopback = Hive::Web::Environment.resolved_for_service(
      config: web_config("127.12.34.56"),
      environment: { "HIVEBOX_LOCAL_LOOPBACK" => "yes" },
      managed_app_dir: "/managed/web"
    )
    non_loopback = Hive::Web::Environment.resolved_for_service(
      config: web_config("0.0.0.0"),
      environment: { "HIVE_WEB_LOCAL_LOOPBACK" => "1" },
      managed_app_dir: "/managed/web"
    )
    explicitly_disabled = Hive::Web::Environment.resolved_for_service(
      config: web_config("localhost"),
      environment: {
        "HIVE_WEB_LOCAL_LOOPBACK" => "0",
        "HIVEBOX_LOCAL_LOOPBACK" => "1"
      },
      managed_app_dir: "/managed/web"
    )

    assert_equal "1", loopback.fetch("HIVE_WEB_LOCAL_LOOPBACK")
    assert_equal "0", non_loopback.fetch("HIVE_WEB_LOCAL_LOOPBACK"),
                 "an inherited bypass flag must not override an explicit non-loopback bind"
    assert_equal "0", explicitly_disabled.fetch("HIVE_WEB_LOCAL_LOOPBACK"),
                 "the canonical opt-out must keep precedence over its legacy alias"
    assert Hive::Web::Environment.warnings(
      environment: {
        "HIVE_WEB_LOCAL_LOOPBACK" => "0",
        "HIVEBOX_LOCAL_LOOPBACK" => "1"
      }
    ).fetch(0).fetch("ignored")
  end

  def test_unknown_canonical_setting_is_rejected
    error = assert_raises(ArgumentError) do
      Hive::Web::Environment.value("HIVE_WEB_UNKNOWN", environment: {})
    end

    assert_match(/unknown Hive web environment setting/, error.message)
  end

  def test_shared_app_runtime_has_no_deprecated_direct_reads_outside_resolver
    root = File.expand_path("../../..", __dir__)
    files = Dir[
      File.join(root, "lib/**/*.rb"),
      File.join(root, "web/app/**/*.rb"),
      File.join(root, "web/config/**/*.{rb,yml}"),
      File.join(root, "packaging/docker/Dockerfile")
    ].reject { |path| path.end_with?("lib/hive/web/environment.rb") }
    pattern = /ENV(?:\.fetch)?\(?[\[\"']+(?:#{SETTINGS.values.join('|')})/
    offenders = files.filter_map do |path|
      line = File.readlines(path).find_index { |source| source.match?(pattern) }
      "#{path.delete_prefix("#{root}/")}:#{line + 1}" if line
    end

    assert_empty offenders,
                 "deprecated native-web aliases must only be read by the resolver: #{offenders.join(', ')}"
  end

  private

  def value(canonical, environment, default: nil)
    Hive::Web::Environment.value(canonical, environment: environment, default: default)
  end

  def warnings(environment)
    Hive::Web::Environment.warnings(environment: environment)
  end

  def web_config(bind)
    {
      "bind" => bind,
      "port" => 4567,
      "origin" => "",
      "local_loopback" => true
    }
  end
end
