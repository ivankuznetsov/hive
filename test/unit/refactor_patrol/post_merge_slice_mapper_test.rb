require "test_helper"
require "hive/patrol/feature"
require "hive/refactor_patrol/post_merge_slice_mapper"

class RefactorPatrolPostMergeSliceMapperTest < Minitest::Test
  include HiveTestHelper

  class FakeWorktree
    attr_reader :path, :calls

    def initialize(path)
      @path = path
      @calls = []
      @exists = false
    end

    def create_detached_exact!(base_sha:)
      calls << [ :create, base_sha ]
      @exists = true
    end

    def assert_detached_exact!(base_sha:)
      calls << [ :assert, base_sha ]
      true
    end

    def discard!(force:)
      calls << [ :discard, force ]
      @exists = false
    end
  end

  def test_maps_every_path_at_exact_sha_and_uses_stable_fallback_for_unowned_path
    with_tmp_dir do |dir|
      worktree = FakeWorktree.new(File.join(dir, "map"))
      features = [
        Hive::Patrol::Feature.new(
          id: "component-checkout", kind: "component", entrypoints: [],
          owned_files: %w[lib/checkout.rb lib/shared.rb], context_files: [], tests: []
        ),
        Hive::Patrol::Feature.new(
          id: "component-payments", kind: "component", entrypoints: [],
          owned_files: %w[lib/shared.rb], context_files: [], tests: []
        )
      ]
      mapper = Hive::RefactorPatrol::PostMergeSliceMapper.new(
        worktree_factory: ->(_entry, _cfg) { worktree },
        mapper_factory: ->(_root, _entry, _cfg) { -> { features } }
      )

      result = mapper.call(
        entry: { "path" => dir, "hive_state_path" => File.join(dir, "state") },
        cfg: {}, analysis_sha: "a" * 40,
        paths: %w[lib/checkout.rb lib/shared.rb config/opaque.flux]
      )

      assert_equal "a" * 40, result.analysis_sha
      assert_equal [ "component-checkout" ], result.path_mappings[0].fetch("slice_ids")
      assert_equal %w[component-checkout component-payments], result.path_mappings[1].fetch("slice_ids")
      assert_match(/\Apath-[0-9a-f]{24}\z/, result.path_mappings[2].fetch("slice_ids").one? ? result.path_mappings[2].fetch("slice_ids").first : "")
      assert_equal [ [ :create, "a" * 40 ], [ :assert, "a" * 40 ], [ :discard, true ] ], worktree.calls
    end
  end
end
