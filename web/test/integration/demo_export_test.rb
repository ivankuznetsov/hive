require "test_helper"
require "tmpdir"
require_relative "../../script/support/demo/exporter"

class DemoExportTest < ActiveSupport::TestCase
  def export_without_host_discovery
    forbidden = ->(*) { flunk "Static export attempted host project discovery" }
    original = Hive::Config.method(:registered_projects)
    Hive::Config.define_singleton_method(:registered_projects, forbidden)
    Dir.mktmpdir("hive-demo-export-test") do |destination|
      yield destination, HiveDemo::Exporter.new.export(destination)
    end
  ensure
    Hive::Config.define_singleton_method(:registered_projects, original)
  end

  def page(destination, route)
    File.read(File.join(destination, route.fetch("page")))
  end

  test "exports the selected real corpus through the snapshot route graph" do
    export_without_host_discovery do |destination, routes|
      by_path = routes.index_by { |route| route.fetch("path") }
      expected = %w[/ /grid /archive /done /repos /honeycombs/workflows /honeycombs/modules /patrol /digest/2026-09-15]
      expected.each { |path| assert by_path.key?(path), "missing route #{path}" }
      assert_equal 12, routes.count { |route| route.fetch("kind") == "task" }
      assert_equal 10, routes.count { |route| route.fetch("kind") == "change" }
      assert_operator routes.size, :>=, 250
      assert by_path.key?(File.join("/tasks/screenote", "add-image-attachments-to-screenote-260816-6a00"))
    end
  end

  test "renders approved real records on every required surface" do
    export_without_host_discovery do |destination, routes|
      by_path = routes.index_by { |route| route.fetch("path") }

      board = page(destination, by_path.fetch("/"))
      assert_equal 2, Nokogiri::HTML.fragment(board).css("article.kanban-card").size
      assert_includes board, "Explore 10 completed tasks across 5 projects"
      assert_includes board, "Patrol-native skill improvement"
      assert_includes board, "Token usage analytics"

      done = page(destination, by_path.fetch("/done"))
      assert_equal 10, Nokogiri::HTML.fragment(done).css("article.kanban-card").size
      archive = page(destination, by_path.fetch("/archive"))
      assert_equal 10, Nokogiri::HTML.fragment(archive).css("article.task-row").size

      task = page(destination, by_path.fetch("/tasks/screenote/add-image-attachments-to-screenote-260816-6a00"))
      assert_includes task, "Image attachments in comments and replies"
      assert_includes task, "https://github.com/ivankuznetsov/screenote/pull/67"
      assert_includes task, 'id="workspace-primary-result"'
      assert_includes task, "documents/reviews/grok-ce-code-review-01.md"
      assert_equal 1, Nokogiri::HTML.fragment(task).css("section#workspace-snapshot-documents").size

      active = page(destination, by_path.fetch("/tasks/hive/build-a-patrol-native-self-260829-cc36"))
      assert_equal 9, Nokogiri::HTML.fragment(active).css("#task-questions .qa-item").size
      assert_includes active, "data-snapshot-action=\"answer\""
      assert_not_includes active, "workspace-publication"

      digest = page(destination, by_path.fetch("/digest/2026-09-15"))
      assert_equal 8, Nokogiri::HTML.fragment(digest).css("li.digest-item").size
      assert_includes digest, "Selected public-project view"

      repos = page(destination, by_path.fetch("/repos"))
      assert_equal 5, Nokogiri::HTML.fragment(repos).css("article.repo-row").size
      workflows = page(destination, by_path.fetch("/honeycombs/workflows"))
      assert_equal 5, Nokogiri::HTML.fragment(workflows).css("article.workflow-row").size
      assert_includes workflows, "Package metadata and permissions"
      modules = page(destination, by_path.fetch("/honeycombs/modules"))
      assert_equal 1, Nokogiri::HTML.fragment(modules).css("article.module-row").size
      patrol = page(destination, by_path.fetch("/patrol"))
      assert_equal 3, Nokogiri::HTML.fragment(patrol).css("article.patrol-row").size
      assert_includes patrol, "selected from"
    end
  end

  test "exports no live control, remote media, or unpublished identity" do
    export_without_host_discovery do |destination, routes|
      published_paths = routes.map { |route| route.fetch("path") }.to_set
      published_paths << "/privacy.html"
      routes.each do |route|
        html = page(destination, route)
        fragment = Nokogiri::HTML.fragment(html)
        assert_empty fragment.css("select, textarea, iframe, object, embed, turbo-frame, turbo-stream, [data-controller], [data-action]"),
                     "#{route.fetch('path')} exposes a live control"
        assert_empty fragment.css("form:not(#waitlist-form)"), "#{route.fetch('path')} exposes a live form"
        assert_empty fragment.css("input:not(#waitlist-email)"), "#{route.fetch('path')} exposes a live input"
        assert_empty fragment.css("button:not([data-snapshot-action]):not([data-waitlist-open]):not(#waitlist-submit):not(#waitlist-close)"),
                     "#{route.fetch('path')} exposes a live button"
        assert_empty fragment.css("script:not(#demo-config):not([src='/app.mjs'])"), "#{route.fetch('path')} exposes live script"
        assert_empty fragment.css("[src]:not([src='/app.mjs'])"), "#{route.fetch('path')} exposes a live source"
        assert_empty fragment.css("img, video, audio"), "#{route.fetch('path')} exposes remote media"
        fragment.css("a[href^='/']").each do |anchor|
          path = anchor["href"].split("#", 2).first
          assert published_paths.include?(path), "#{route.fetch('path')} links to unexported #{path}"
        end
        assert_not_includes html, "writero"
        assert_not_includes html, "hive-private"
        assert_not_includes html, "/home/"
      end
    end
  end

  test "labels every saved page and preserves frozen state qualifiers" do
    export_without_host_discovery do |destination, routes|
      by_path = routes.index_by { |route| route.fetch("path") }
      routes.each do |route|
        html = page(destination, route)
        assert_includes html, "Saved Hive snapshot", "#{route.fetch('path')} lost the saved-snapshot notice"
        assert_includes html, "<!-- DEMO_CONFIG -->"
      end
      change = page(destination, by_path.fetch("/tasks/hive/improve-hive-web-task-detail-260812-19e1/change"))
      assert_includes change, "Diff unavailable"
      assert_includes change, "https://github.com/ivankuznetsov/hive/pull/1015"
      unavailable = page(destination, by_path.fetch("/unavailable/agents"))
      assert_includes unavailable, "Not part of this saved snapshot"
    end
  end

  test "rejects injected live actions and unreviewed destinations" do
    [
      '<form action="/tasks/hive/demo/run" method="post"><button>Run</button></form>',
      '<hive-status-stream-source channel="StatusChannel"></hive-status-stream-source>',
      '<turbo-frame src="/tasks/hive/demo/diff"></turbo-frame>',
      '<script src="/assets/application.js"></script>',
      '<a href="/agents/login">Log in</a>',
      '<p onclick="fetch(\'/run\')">Run</p>'
    ].each do |html|
      assert_raises(RuntimeError, html) { HiveDemo::Static.fragment(html) }
    end
  end

  test "replaces omitted media and unapproved links with visible notes" do
    html = HiveDemo::Static.fragment('<p>Before <img src="https://example.com/a.png" alt="diagram"> after</p>')
    assert_includes html, "snapshot-media-omitted"
    assert_includes html, "diagram"

    html = HiveDemo::Static.fragment('<p><a href="https://example.com/private">secret</a></p>')
    assert_includes html, "snapshot-link-omitted"
    assert_includes html, "secret"
    assert_not_includes html, "example.com"
  end
end
