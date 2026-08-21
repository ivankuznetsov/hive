require "test_helper"
require "hive/patrol/feature"
require "hive/refactor_patrol/frozen_revision_map_rig"

class RefactorPatrolFrozenRevisionMapRigTest < Minitest::Test
  include HiveTestHelper

  SHA = "a" * 40

  class FakeWorktree
    attr_reader :path, :calls

    def initialize(path)
      @path = path
      @calls = []
      @exists = false
    end

    def fetch_strict_origin_base!(branch)
      calls << [ :fetch, branch ]
      SHA
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

  def test_maps_supplied_revision_only_after_exact_detached_assertion
    with_tmp_dir do |dir|
      worktree = FakeWorktree.new(File.join(dir, "map"))
      feature = Hive::Patrol::Feature.new(
        id: "component", kind: "component", entrypoints: [],
        owned_files: [ "lib/component.rb" ], context_files: [], tests: []
      )
      rig = build_rig(worktree) { [ feature ] }

      result = rig.call(entry: entry(dir), cfg: {}, analysis_sha: SHA)

      assert_equal SHA, result.analysis_sha
      assert_equal [ feature ], result.features
      assert_equal [ [ :create, SHA ], [ :assert, SHA ], [ :discard, true ] ], worktree.calls
    end
  end

  def test_freezes_origin_revision_and_cleans_up_when_mapping_fails
    with_tmp_dir do |dir|
      worktree = FakeWorktree.new(File.join(dir, "map"))
      rig = build_rig(worktree) { raise "mapping failed" }

      error = assert_raises(RuntimeError) do
        rig.call(entry: entry(dir), cfg: { "default_branch" => "stable" })
      end

      assert_equal "mapping failed", error.message
      assert_equal(
        [ [ :fetch, "stable" ], [ :create, SHA ], [ :assert, SHA ], [ :discard, true ] ],
        worktree.calls
      )
    end
  end

  def test_rejects_an_invalid_frozen_revision_and_still_discards_the_worktree
    with_tmp_dir do |dir|
      worktree = FakeWorktree.new(File.join(dir, "map"))
      rig = build_rig(worktree) { flunk }

      assert_raises(Hive::ConfigError) do
        rig.call(entry: entry(dir), cfg: {}, analysis_sha: "not-an-oid")
      end

      assert_equal [ [ :discard, true ] ], worktree.calls
    end
  end

  def test_default_builders_apply_the_isolated_root_and_architecture_mapper_config
    with_tmp_dir do |dir|
      captured = {}
      worktree = FakeWorktree.new(File.join(dir, "mapped"))
      worktree_new = lambda do |root, slug, worktree_root:|
        captured[:worktree] = [ root, slug, worktree_root ]
        worktree
      end
      state = Object.new
      state_new = ->(*_args, **_kwargs) { state }
      mapper = -> { [] }
      mapper_new = lambda do |root, cfg:, state:, dry_run:, capabilities:|
        captured[:mapper] = [ root, cfg, state, dry_run, capabilities ]
        mapper
      end
      cfg = {
        "worktree_root" => File.join(dir, "worktrees"),
        "patrol" => { "include" => [ "old" ] },
        "refactor_patrol" => {
          "include" => [ "lib" ], "exclude" => [ "vendor" ], "review" => "high"
        }
      }
      rig = Hive::RefactorPatrol::FrozenRevisionMapRig.new

      with_replaced_singleton_method(Hive::Worktree, :new, worktree_new) do
        with_replaced_singleton_method(Hive::RefactorPatrol::StateStore, :new, state_new) do
          with_replaced_singleton_method(Hive::Patrol::Mapper, :new, mapper_new) do
            assert_same worktree, rig.send(:build_worktree, entry(dir), cfg)
            assert_same mapper, rig.send(:build_mapper, worktree.path, entry(dir), cfg)
          end
        end
      end

      assert_equal dir, captured.dig(:worktree, 0)
      assert_match(%r{/\.refactor-patrol/frozen-revision-map\z}, captured.dig(:worktree, 2))
      assert_equal [ "lib" ], captured.dig(:mapper, 1, "patrol", "include")
      assert_equal %i[architecture documentation], captured.dig(:mapper, 4)
    end
  end

  private

  def entry(dir)
    { "path" => dir, "hive_state_path" => File.join(dir, ".hive-state") }
  end

  def build_rig(worktree, &mapping)
    Hive::RefactorPatrol::FrozenRevisionMapRig.new(
      worktree_factory: ->(_entry, _cfg) { worktree },
      mapper_factory: ->(_root, _entry, _cfg) { mapping }
    )
  end
end
