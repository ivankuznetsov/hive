require "test_helper"
require_relative "../../script/support/demo/exporter"

class DemoExportTest < ActiveSupport::TestCase
  test "exports real board and workspace views for both prepared branches without host discovery" do
    forbidden = ->(*) { flunk "Static export attempted host project discovery" }
    original = Hive::Config.method(:registered_projects)
    Hive::Config.define_singleton_method(:registered_projects, forbidden)
    begin
      Dir.mktmpdir("hive-demo-export-test") do |destination|
        manifest = HiveDemo::Exporter.new.export(destination)
        assert_equal 9, manifest.fetch(:states).size
        assert_equal 4, manifest.fetch(:tasks).size
        assert_match(/\A[0-9a-f]{40}\z/, manifest.fetch(:source_commit))
        assert File.file?(File.join(destination, manifest.fetch(:stylesheet)))
        board = File.read(File.join(destination, manifest.fetch(:states).fetch("question").fetch(:board)))
        assert_equal 4, Nokogiri::HTML.fragment(board).css("article.kanban-card").size
        assert_includes board, "Needs your answer"
        assert_includes board, "Ready for review"
        %w[system manual].each do |branch|
          state = manifest.fetch(:states).fetch("#{branch}-completed")
          assert_nil state.fetch(:next)
          panels = state.fetch(:tasks).fetch("dark-mode")
          overview = File.read(File.join(destination, panels.fetch(:overview)))
          assert_includes overview, 'id="workspace-summary"'
          assert_includes overview, 'id="workspace-primary-result"'
          assert_includes overview, "Dark mode is ready"
          diff = File.read(File.join(destination, panels.fetch(:diff)))
          assert_includes diff, 'class="diff-result diff-result-available"'
          if branch == "system"
            assert_includes diff, "matchMedia"
          else
            assert_not_includes diff, "matchMedia"
          end
          assert_includes File.read(File.join(destination, panels.fetch(:evidence))), "not live test output"
        end
        Dir[File.join(destination, "**/*.html")].each do |path|
          html = File.read(path)
          assert_empty Nokogiri::HTML.fragment(html).css("form, script, turbo-frame, turbo-stream, iframe, button, [data-controller], [data-action], [src]")
          assert_not_includes html, ENV.fetch("HIVE_HOME")
        end
      end
    ensure
      Hive::Config.define_singleton_method(:registered_projects, original)
    end
  end

  test "rejects injected live actions and streams instead of silently publishing them" do
    exporter = HiveDemo::Exporter.new
    [
      '<form action="/tasks/Notebook/dark-mode/run" method="post"><button>Run</button></form>',
      '<hive-status-stream-source channel="StatusChannel"></hive-status-stream-source>',
      '<turbo-frame src="/tasks/Notebook/dark-mode/diff"></turbo-frame>',
      '<script src="/assets/application.js"></script>',
      '<a href="/agents/login">Log in</a>',
      '<a href="https://api.example.com">Provider</a>',
      '<p onclick="fetch(\'/run\')">Run</p>'
    ].each do |html|
      assert_raises(RuntimeError, html) { exporter.static_fragment(html) }
    end
  end
end
