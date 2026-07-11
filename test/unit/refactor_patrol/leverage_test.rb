require "test_helper"
require "hive/refactor_patrol/leverage"
require "hive/patrol/feature"

class RefactorPatrolLeverageTest < Minitest::Test
  include HiveTestHelper

  def test_churn_counts_recent_changes_and_affects_score
    with_tmp_git_repo do |dir|
      write(dir, "lib/checkout.rb", "class Checkout\nend\n")
      write(dir, "lib/search.rb", "class Search\nend\n")
      commit_all(dir, "features")
      3.times do |idx|
        write(dir, "lib/checkout.rb", "class Checkout\n  CHANGE = #{idx}\nend\n")
        commit_all(dir, "checkout #{idx}")
      end

      leverage = Hive::RefactorPatrol::Leverage.new(dir, cfg: cfg)
      checkout = feature("checkout", [ "lib/checkout.rb" ])
      search = feature("search", [ "lib/search.rb" ])

      assert_operator leverage.score(checkout).dig("signals", "churn"), :>, leverage.score(search).dig("signals", "churn")
      assert_operator leverage.score(checkout).fetch("score"), :>, leverage.score(search).fetch("score")
    end
  end

  def test_fan_in_complexity_and_coupling_contribute_to_breakdown
    with_tmp_git_repo do |dir|
      write(dir, "lib/checkout.rb", "require 'lib/payment'\nclass Checkout\n  def call\n    if true\n      Payment.new\n    end\n  end\nend\n")
      write(dir, "lib/payment.rb", "class Payment\nend\n")
      write(dir, "app/order.rb", "require 'lib/checkout'\nCheckout.new\n")
      write(dir, "app/cart.rb", "Checkout.new\n")
      commit_all(dir, "code")

      leverage = Hive::RefactorPatrol::Leverage.new(dir, cfg: cfg)
      result = leverage.score(feature("checkout", [ "lib/checkout.rb" ], entrypoints: [ "lib/checkout.rb" ]))

      assert_equal "feature", result.fetch("scope")
      assert_operator result.dig("signals", "fan_in"), :>=, 2
      assert_operator result.dig("signals", "complexity"), :>, 0
      assert_operator result.dig("signals", "coupling"), :>, 0
      assert_in_delta result.fetch("score"), result.fetch("breakdown").values.sum, 0.0002
      assert_equal %w[churn fan_in complexity coupling], result.fetch("breakdown").keys
    end
  end

  def test_weight_changes_shift_contribution
    with_tmp_git_repo do |dir|
      write(dir, "lib/checkout.rb", "class Checkout\nend\n")
      write(dir, "app/order.rb", "Checkout.new\n")
      commit_all(dir, "code")

      feature = feature("checkout", [ "lib/checkout.rb" ])
      fan_cfg = cfg("fan_in" => 1.0, "churn" => 0.0, "complexity" => 0.0, "coupling" => 0.0)
      size_cfg = cfg("fan_in" => 0.0, "churn" => 0.0, "complexity" => 1.0, "coupling" => 0.0)

      assert_operator(
        Hive::RefactorPatrol::Leverage.new(dir, cfg: fan_cfg).score(feature).dig("breakdown", "fan_in"),
        :>,
        Hive::RefactorPatrol::Leverage.new(dir, cfg: size_cfg).score(feature).fetch("breakdown").fetch("complexity")
      )
    end
  end

  def test_git_unavailable_degrades_churn_to_zero
    with_tmp_dir do |dir|
      write(dir, "lib/checkout.rb", "class Checkout\nend\n")
      failed = Struct.new(:success?).new(false)
      runner = ->(*) { [ "", "no git", failed ] }

      result = Hive::RefactorPatrol::Leverage.new(dir, cfg: cfg, command_runner: runner)
                                             .score(feature("checkout", [ "lib/checkout.rb" ]))

      assert_equal 0, result.dig("signals", "churn")
      assert result.key?("score")
    end
  end

  def test_git_exception_degrades_churn_to_zero
    with_tmp_dir do |dir|
      write(dir, "lib/checkout.rb", "class Checkout\nend\n")
      runner = ->(*) { raise "git unavailable" }

      result = Hive::RefactorPatrol::Leverage.new(dir, cfg: cfg, command_runner: runner)
                                             .score(feature("checkout", [ "lib/checkout.rb" ]))

      assert_equal 0, result.dig("signals", "churn")
      assert_equal [], result.dig("normalized").keys - Hive::RefactorPatrol::Leverage::SIGNALS
    end
  end

  def test_ls_files_failure_falls_back_to_directory_scan
    with_tmp_dir do |dir|
      write(dir, "lib/checkout.rb", "class Checkout\nend\n")
      write(dir, ".git/ignored", "ignored")
      failed = Struct.new(:success?).new(false)
      runner = ->(*) { [ "", "no git", failed ] }

      result = Hive::RefactorPatrol::Leverage.new(dir, cfg: cfg, command_runner: runner)
                                             .score(feature("checkout", [ "lib/checkout.rb" ], entrypoints: [ "lib/checkout.rb" ]))

      assert_equal 0, result.dig("signals", "complexity")
    end
  end

  def test_missing_owned_file_degrades_to_empty_content
    with_tmp_dir do |dir|
      result = Hive::RefactorPatrol::Leverage.new(dir, cfg: cfg)
                                             .score(feature("checkout", [ "lib/missing.rb" ], entrypoints: [ "lib/missing.rb" ]))

      assert_equal 0, result.dig("signals", "complexity")
      assert result.key?("score")
    end
  end

  def test_non_utf8_tracked_file_does_not_crash_scoring
    with_tmp_git_repo do |dir|
      write(dir, "lib/checkout.rb", "require 'lib/blob'\nclass Checkout\nend\n")
      File.binwrite(File.join(dir, "assets", "blob.bin").tap { |p| FileUtils.mkdir_p(File.dirname(p)) }, "\xFF\xFE\x00\x81binary".b)
      commit_all(dir, "code")

      result = Hive::RefactorPatrol::Leverage.new(dir, cfg: cfg)
                                             .score(feature("checkout", [ "lib/checkout.rb" ], entrypoints: [ "lib/checkout.rb" ]))

      assert result.key?("score")
      assert_equal 0, result.dig("signals", "complexity")
    end
  end

  def test_excluded_globs_are_skipped_in_content_scans
    with_tmp_git_repo do |dir|
      write(dir, "lib/checkout.rb", "class Checkout\nend\n")
      write(dir, "vendor/order.rb", "Checkout.new\n")
      commit_all(dir, "code")

      excluded = cfg.merge("refactor_patrol" => cfg.fetch("refactor_patrol").merge("exclude" => [ "vendor/**" ]))
      checkout = feature("checkout", [ "lib/checkout.rb" ], entrypoints: [ "lib/checkout.rb" ])

      with_exclude = Hive::RefactorPatrol::Leverage.new(dir, cfg: excluded).score(checkout).dig("signals", "fan_in")
      without_exclude = Hive::RefactorPatrol::Leverage.new(dir, cfg: cfg).score(checkout).dig("signals", "fan_in")

      assert_operator without_exclude, :>, with_exclude
    end
  end

  def test_optional_zero_weight_signals_are_excluded
    with_tmp_dir do |dir|
      write(dir, "lib/checkout.rb", "class Checkout\nend\n")
      result = Hive::RefactorPatrol::Leverage.new(dir, cfg: cfg).score(feature("checkout", [ "lib/checkout.rb" ]))

      refute_includes result.fetch("breakdown"), "bug_density"
      refute_includes result.fetch("breakdown"), "coverage_gap"
    end
  end

  def test_generic_entrypoint_basename_does_not_inflate_fan_in_or_coupling
    with_tmp_git_repo do |dir|
      write(dir, "lib/hive/config.rb", "module Hive::Config\nend\n")
      write(dir, "app/real.rb", "Hive::Config.load\n")
      write(dir, "docs/settings.txt", "the config value is documented here\n")
      write(dir, "app/configuration.rb", "CONFIG = true\n")
      commit_all(dir, "code")

      result = Hive::RefactorPatrol::Leverage.new(dir, cfg: cfg).score(
        feature("config", [ "lib/hive/config.rb" ], entrypoints: [ "lib/hive/config.rb" ])
      )

      assert_equal 1, result.dig("signals", "fan_in")
      assert_operator result.dig("signals", "coupling"), :<=, 1
    end
  end

  def test_complexity_is_decision_density_instead_of_raw_file_length
    with_tmp_dir do |dir|
      write(dir, "lib/large.rb", ([ "value = 1" ] * 1_000).join("\n"))
      write(dir, "lib/branchy.rb", ([ "if ready", "  work", "end" ] * 20).join("\n"))
      leverage = Hive::RefactorPatrol::Leverage.new(dir, cfg: cfg)

      large = leverage.score(feature("large", [ "lib/large.rb" ])).dig("signals", "complexity")
      branchy = leverage.score(feature("branchy", [ "lib/branchy.rb" ])).dig("signals", "complexity")

      assert_equal 0, large
      assert_operator branchy, :>, large
    end
  end

  def test_dependency_signals_use_production_sources_not_docs_tests_or_assets
    with_tmp_git_repo do |dir|
      write(dir, "services/catalog/catalog/Catalog.java", "package catalog; public class Catalog {}\n")
      write(dir, "services/web/web/Web.java", "class Web { Object value = catalog.Catalog.current; }\n")
      write(dir, "tests/catalog_test.java", "class Test { Object value = catalog.Catalog.current; }\n")
      write(dir, "docs/architecture.md", "The catalog.Catalog boundary is central.\n")
      write(dir, "assets/catalog.txt", "catalog.Catalog\n")
      commit_all(dir, "polyglot references")

      result = Hive::RefactorPatrol::Leverage.new(dir, cfg: cfg).score(
        feature(
          "catalog", [ "services/catalog/catalog/Catalog.java" ],
          entrypoints: [ "services/catalog/catalog/Catalog.java" ]
        )
      )

      assert_equal 1, result.dig("signals", "fan_in")
      assert_equal 1, result.dig("signals", "coupling")
    end
  end

  def test_churn_history_is_collected_once_for_all_features
    with_tmp_git_repo do |dir|
      write(dir, "lib/checkout.rb", "class Checkout\nend\n")
      write(dir, "lib/search.rb", "class Search\nend\n")
      commit_all(dir, "code")
      log_calls = 0
      runner = lambda do |*args|
        log_calls += 1 if args.include?("log")
        Open3.capture3(*args)
      end
      leverage = Hive::RefactorPatrol::Leverage.new(dir, cfg: cfg, command_runner: runner)

      leverage.score(feature("checkout", [ "lib/checkout.rb" ]))
      leverage.score(feature("search", [ "lib/search.rb" ]))

      assert_equal 1, log_calls
    end
  end

  def test_mapper_chunk_boundaries_do_not_count_as_architecture_coupling
    with_tmp_git_repo do |dir|
      write(dir, "lib/acme/client.rb", "require_relative 'policy'\nmodule Acme::Client; end\n")
      write(dir, "lib/acme/policy.rb", "module Acme::Policy; end\n")
      write(dir, "app/orders/checkout.rb", "require 'acme/client'\nAcme::Client.new\n")
      commit_all(dir, "component graph")
      leverage = Hive::RefactorPatrol::Leverage.new(dir, cfg: cfg)

      result = leverage.score(
        feature("client", [ "lib/acme/client.rb" ], entrypoints: [ "lib/acme/client.rb" ])
      )

      assert_equal 1, result.dig("signals", "fan_in")
      assert_equal 1, result.dig("signals", "coupling"),
                   "the peer policy file belongs to the same stable component root"
    end
  end

  def test_normalization_is_smooth_instead_of_saturating_at_the_scale
    leverage = Hive::RefactorPatrol::Leverage.new(Dir.pwd, cfg: cfg)
    at_scale = leverage.send(:normalize, "fan_in" => 50).fetch("fan_in")
    above_scale = leverage.send(:normalize, "fan_in" => 100).fetch("fan_in")

    assert_in_delta 0.5, at_scale
    assert_operator above_scale, :>, at_scale
    assert_operator above_scale, :<, 1.0
  end

  def test_proposal_score_multiplies_hotspot_contributions_by_bounded_relief
    hotspot = { "breakdown" => { "churn" => 0.4, "coupling" => 0.2 } }
    drivers = [
      { "signal" => "churn", "relief" => 0.5, "mechanism" => "isolate edits" },
      { "signal" => "coupling", "relief" => 0.25, "mechanism" => "centralize the boundary" }
    ]

    result = Hive::RefactorPatrol::Leverage.score_proposal(hotspot, drivers)

    assert_equal({ "churn" => 0.2, "coupling" => 0.05 }, result.fetch("breakdown"))
    assert_in_delta 0.25, result.fetch("score"), 0.0001
    assert_equal drivers, result.fetch("drivers")
  end

  def test_proposal_score_rejects_unknown_duplicate_and_out_of_range_drivers
    hotspot = { "breakdown" => { "churn" => 0.4 } }
    invalid_sets = [
      [ { "signal" => "unknown", "relief" => 0.5, "mechanism" => "no measurement" } ],
      [
        { "signal" => "churn", "relief" => 0.5, "mechanism" => "first" },
        { "signal" => "churn", "relief" => 0.2, "mechanism" => "duplicate" }
      ],
      [ { "signal" => "churn", "relief" => 1.1, "mechanism" => "too much" } ],
      [ { "signal" => "churn", "relief" => 0.5, "mechanism" => "" } ]
    ]

    invalid_sets.each do |drivers|
      assert_raises(ArgumentError) do
        Hive::RefactorPatrol::Leverage.score_proposal(hotspot, drivers)
      end
    end
  end

  def test_proposal_score_reports_the_missing_driver_field
    error = assert_raises(ArgumentError) do
      Hive::RefactorPatrol::Leverage.score_proposal(
        { "breakdown" => { "churn" => 0.4 } },
        [ { "signal" => "churn", "mechanism" => "isolate edits" } ]
      )
    end

    assert_includes error.message, "missing \"relief\""
  end

  def test_reference_needles_keep_nonstandard_source_roots
    leverage = Hive::RefactorPatrol::Leverage.new(Dir.pwd, cfg: cfg)

    needles = leverage.send(:reference_needles_for, "domain/checkout/service.rb")

    assert_includes needles, "domain/checkout/service"
  end

  def test_architecture_scan_failure_degrades_dependency_signals_to_empty
    with_tmp_dir do |dir|
      write(dir, "lib/checkout.rb", "class Checkout\nend\n")
      failing_mapper = Class.new do
        def initialize(*) = nil
        def call(*) = raise("mapper unavailable")
      end

      with_replaced_singleton_method(
        Hive::Patrol::ArchitectureMapper, :new, ->(*) { failing_mapper.new }
      ) do
        result = Hive::RefactorPatrol::Leverage.new(dir, cfg: cfg).score(
          feature("checkout", [ "lib/checkout.rb" ])
        )

        assert_equal 0, result.dig("signals", "fan_in")
        assert_equal 0, result.dig("signals", "coupling")
        assert_equal "incomplete", result.dig("measurement", "status")
        diagnostic = result.dig("measurement", "diagnostics", 0)
        assert_equal "architecture_map_failed", diagnostic.fetch("kind")
        assert_equal "RuntimeError", diagnostic.fetch("error_class")
        assert_includes diagnostic.fetch("message"), "mapper unavailable"
      end
    end
  end

  private

  def cfg(weights = {})
    {
      "refactor_patrol" => {
        "leverage" => {
          "weights" => {
            "churn" => 0.3,
            "fan_in" => 0.25,
            "complexity" => 0.25,
            "coupling" => 0.2,
            "bug_density" => 0.0,
            "coverage_gap" => 0.0
          }.merge(weights)
        }
      }
    }
  end

  def feature(id, files, entrypoints: files)
    Hive::Patrol::Feature.new(
      id: id,
      kind: "command",
      entrypoints: entrypoints,
      owned_files: files,
      context_files: [],
      tests: []
    )
  end

  def write(dir, path, content)
    FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
    File.write(File.join(dir, path), content)
  end

  def commit_all(dir, message)
    run!("git", "-C", dir, "add", ".")
    run!("git", "-C", dir, "commit", "-m", message, "--quiet")
  end
end
