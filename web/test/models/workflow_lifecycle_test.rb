require "test_helper"

class WorkflowLifecycleTest < ActiveSupport::TestCase
  Resolution = Data.define(:name, :version, :catalog_commit, :source_commit, :manifest_digest)

  test "preview registry accepts the exact reviewed package identity" do
    resolution = build_resolution
    registry = preview_registry(resolution, resolution.to_h.transform_keys(&:to_s))

    Dir.mktmpdir do |destination|
      assert_same resolution, registry.fetch("honeycomb/demo", destination: destination)
    end
  end

  test "preview registry rejects a package that changed after disclosure" do
    resolution = build_resolution(source_commit: "c" * 40)
    expected = resolution.to_h.transform_keys(&:to_s).merge("source_commit" => "a" * 40)
    registry = preview_registry(resolution, expected)

    error = assert_raises(Hive::Web::WorkflowLifecycle::PreviewChanged) do
      Dir.mktmpdir do |destination|
        registry.fetch("honeycomb/demo", destination: destination)
      end
    end
    assert_match "preview it again", error.message
  end

  private

  def build_resolution(source_commit: "a" * 40)
    Resolution.new(
      name: "demo", version: "1.0.0", catalog_commit: "c" * 40,
      source_commit: source_commit, manifest_digest: "b" * 64
    )
  end

  def preview_registry(resolution, expected)
    delegate = Object.new
    delegate.define_singleton_method(:fetch) do |_source, destination:|
      FileUtils.mkdir_p(destination)
      resolution
    end
    Hive::Web::WorkflowLifecycle::PreviewRegistry.new(delegate, expected)
  end
end
