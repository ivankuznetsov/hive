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

      assert_operator result.dig("signals", "complexity"), :>, 0
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
      assert_operator result.dig("signals", "complexity"), :>, 0
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
