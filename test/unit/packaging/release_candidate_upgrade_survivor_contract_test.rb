require "test_helper"
require "open3"
require "rbconfig"
require_relative "../../../packaging/release_candidate/repository"
require_relative "../../../packaging/release_candidate/upgrade_survivor"

class ReleaseCandidateUpgradeSurvivorContractTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__).freeze
  SOURCE_ROOT = File.join(ROOT, "packaging/release_candidate").freeze
  COLLABORATORS = {
    HiveReleaseCandidate::ChannelPrefixOracle => "channel_prefix_oracle.rb",
    HiveReleaseCandidate::UpgradeSurvivor::ReviewedChannelUpdater => "reviewed_channel_updater.rb",
    HiveReleaseCandidate::UpgradeSurvivor::FixedChannelExecutor => "fixed_channel_executor.rb",
    HiveReleaseCandidate::UpgradeSurvivor::StateSnapshotter => "state_snapshotter.rb",
    HiveReleaseCandidate::UpgradeSurvivor::FixedPhaseExecutor => "fixed_phase_executor.rb"
  }.freeze

  def test_root_is_a_bounded_coordinator_and_collaborators_own_their_methods
    root = File.join(SOURCE_ROOT, "upgrade_survivor.rb")

    assert_operator File.readlines(root).length, :<=, 350
    run_source = HiveReleaseCandidate::UpgradeSurvivor.instance_method(:run).source_location.first
    assert_equal root, File.expand_path(run_source)
    COLLABORATORS.each do |owner, basename|
      method_name = owner == HiveReleaseCandidate::UpgradeSurvivor::ReviewedChannelUpdater ? :apply! : :call
      method_name = :verify if owner == HiveReleaseCandidate::ChannelPrefixOracle
      expected = File.join(SOURCE_ROOT, "upgrade_survivor", basename)

      assert_equal expected, File.expand_path(owner.instance_method(method_name).source_location.first)
      assert_operator File.readlines(expected).length, :<=, 250
    end
  end

  def test_each_collaborator_loads_without_the_coordinator_root
    COLLABORATORS.each_value do |basename|
      path = File.join(SOURCE_ROOT, "upgrade_survivor", basename)
      stdout, stderr, status = Open3.capture3(
        { "BUNDLE_GEMFILE" => nil, "RUBYLIB" => nil, "RUBYOPT" => nil },
        RbConfig.ruby, "--disable-gems", "-e", "require File.expand_path(ARGV.fetch(0))", path
      )

      assert status.success?, "#{basename}: stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
    end
  end

  def test_candidate_tool_identity_includes_every_collaborator
    captured_paths = nil
    repository = HiveReleaseCandidate::Repository.allocate
    repository.define_singleton_method(:committed_or_placeholder) { |*, **| {} }
    repository.define_singleton_method(:baseline_input) { |*| {} }
    repository.define_singleton_method(:action_lock_input) { |*| {} }
    repository.define_singleton_method(:paths_input) do |_sha, paths, **|
      captured_paths = paths
      {}
    end

    repository.inputs("a" * 40)

    COLLABORATORS.each_value do |basename|
      assert_includes(
        captured_paths,
        "packaging/release_candidate/upgrade_survivor/#{basename}"
      )
    end
  end
end
