require "test_helper"
require "hive/patrol/feature"
require "hive/refactor_patrol/post_merge_scope"

class HiveRefactorPatrolPostMergeScopeTest < Minitest::Test
  include HiveTestHelper

  def test_single_feature_covering_every_change_wins
    with_tmp_dir do |dir|
      result = selector(dir, [ feature("checkout", owned: %w[lib/checkout.rb lib/payment.rb]) ]).select(
        changed_paths: %w[lib/checkout.rb lib/payment.rb], base_sha: "base"
      )

      assert result.runnable?
      assert_equal "feature", result.kind
      assert_equal [ "checkout" ], result.values
      assert_equal [ "--changed-since", "base", "--feature", "checkout" ], result.arguments
      assert_equal({ "kind" => "feature", "values" => [ "checkout" ], "fallback" => false }, result.to_h)
      refute result.fallback
    end
  end

  def test_unique_entrypoint_boundary_wins_when_owned_files_do_not_cover_every_change
    with_tmp_dir do |dir|
      checkout = feature(
        "checkout",
        owned: [ "lib/checkout.rb" ],
        entrypoints: [ "bin/checkout" ],
        context: [ "config/checkout.yml" ]
      )
      result = selector(dir, [ checkout ]).select(
        changed_paths: [ "lib/checkout.rb", "config/checkout.yml" ], base_sha: "base"
      )

      assert_equal "entrypoint", result.kind
      assert_equal [ "bin/checkout" ], result.values
      assert_equal [ "--changed-since", "base", "--entrypoint", "bin/checkout" ], result.arguments
    end
  end

  def test_multi_feature_and_low_confidence_changes_use_stable_bounded_roots
    with_tmp_dir do |dir|
      features = [
        feature("checkout", owned: [ "lib/checkout/flow.rb" ]),
        feature("search", owned: [ "app/search/index.rb" ])
      ]
      result = selector(dir, features).select(
        changed_paths: [ "app/search/index.rb", "lib/checkout/flow.rb", "lib/checkout/card.rb" ],
        base_sha: "parent"
      )

      assert result.runnable?
      assert_equal "path", result.kind
      assert_equal [ "app/search", "lib/checkout" ], result.values
      assert result.fallback
      assert_equal [
        "--changed-since", "parent", "--path", "app/search", "--path", "lib/checkout"
      ], result.arguments
      refute_includes result.values, "."
    end
  end

  def test_root_files_remain_bounded_file_filters
    with_tmp_dir do |dir|
      result = selector(dir, []).select(changed_paths: [ "Gemfile", "lib/a.rb" ], base_sha: "base")
      assert_equal [ "Gemfile", "lib" ], result.values
    end
  end

  def test_empty_excluded_or_unsafe_paths_fail_closed
    with_tmp_dir do |dir|
      scoped = selector(dir, [], "refactor_patrol" => { "exclude" => [ "vendor/**" ] })
      assert_equal "scope_unusable", scoped.select(changed_paths: [], base_sha: "base").reason
      assert_equal "scope_unusable", scoped.select(changed_paths: [ "vendor/a.rb" ], base_sha: "base").reason

      [ "/tmp/escape", "../escape", "lib/$(touch nope)", "lib/a;rm" ].each do |path|
        result = scoped.select(changed_paths: [ path ], base_sha: "base")
        refute result.runnable?, path
        assert_equal "scope_unusable", result.reason
      end
    end
  end

  def test_unrunnable_result_invalid_boundary_and_mapper_failures_are_explicit
    result = Hive::RefactorPatrol::PostMergeScope::Result.new(runnable: false)
    assert_empty result.arguments
    assert_nil result.to_h

    with_tmp_dir do |dir|
      assert_raises(Hive::ConfigError) do
        selector(dir, []).select(changed_paths: [ "lib/a.rb" ], base_sha: "bad boundary!")
      end

      config_failure = Hive::RefactorPatrol::PostMergeScope.new(
        dir, cfg: Hive::Config.deep_dup(Hive::Config::DEFAULTS),
        mapper_factory: ->(*) { raise Hive::ConfigError, "bad map config" }
      )
      assert_raises(Hive::ConfigError) do
        config_failure.select(changed_paths: [ "lib/a.rb" ], base_sha: "base")
      end

      runtime_failure = Hive::RefactorPatrol::PostMergeScope.new(
        dir, cfg: Hive::Config.deep_dup(Hive::Config::DEFAULTS),
        mapper_factory: ->(*) { raise "mapper crashed" }
      )
      failed = runtime_failure.select(changed_paths: [ "lib/a.rb" ], base_sha: "base")
      assert_equal "scope_selection_failed", failed.evidence.fetch("detail")
    end
  end

  def test_default_mapper_configuration_and_empty_root_fallback_are_covered
    with_tmp_dir do |dir|
      cfg = Hive::Config.deep_dup(Hive::Config::DEFAULTS)
      scoped = Hive::RefactorPatrol::PostMergeScope.new(dir, cfg: cfg)
      mapper = scoped.instance_variable_get(:@mapper_factory).call(dir, cfg)
      assert_instance_of Hive::Patrol::Mapper, mapper

      empty_roots = Class.new(Hive::RefactorPatrol::PostMergeScope) do
        private

        def changed_roots(_paths) = []
      end.new(dir, cfg: cfg, mapper_factory: ->(*) { Struct.new(:call).new([]) })
      result = empty_roots.select(changed_paths: [ "lib/a.rb" ], base_sha: "base")
      assert_equal "no_non_root_scope", result.evidence.fetch("detail")
    end
  end

  private

  def selector(dir, features, cfg = {})
    config = Hive::Config.deep_merge(
      Hive::Config.deep_dup(Hive::Config::DEFAULTS),
      { "refactor_patrol" => { "include" => [], "exclude" => [] } }.merge(cfg)
    )
    mapper = Struct.new(:features) do
      def call
        features
      end
    end.new(features)
    Hive::RefactorPatrol::PostMergeScope.new(
      dir,
      cfg: config,
      mapper_factory: ->(_root, _cfg) { mapper }
    )
  end

  def feature(id, owned:, entrypoints: owned, context: [], tests: [])
    Hive::Patrol::Feature.new(
      id: id,
      kind: "command",
      entrypoints: entrypoints,
      owned_files: owned,
      context_files: context,
      tests: tests
    )
  end
end
