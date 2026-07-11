require "test_helper"
require "hive/gh"

class GhIssueHelpersTest < Minitest::Test
  include HiveTestHelper

  def test_issues_with_marker_reads_every_slurped_page_and_excludes_pull_requests
    marker = "<!-- hive-refactor-patrol family=af1-abc action=issue:af1-abc -->"
    pages = [
      [
        issue(1, state: "open", body: "before\n#{marker}\nafter"),
        issue(2, state: "open", body: "a different marker"),
        issue(3, state: "open", body: marker).merge(
          "pull_request" => { "url" => "https://api.github.com/repos/acme/demo/pulls/3" }
        )
      ],
      [
        issue(4, state: "closed", body: marker),
        issue(5, state: "closed", body: nil)
      ]
    ]
    calls = []
    cfg = { "gh" => { "network_timeout_sec" => 9 } }
    capture = lambda do |*args, **kwargs|
      calls << [ args, kwargs ]
      [ JSON.generate(pages), "", Hive::Gh::CommandStatus.new(exitstatus: 0) ]
    end

    result = with_capture(capture) do
      Hive::Gh.issues_with_marker(
        repository: "acme/demo", marker: marker, host: "github.com", cfg: cfg
      )
    end

    assert_equal [ 1, 4 ], result.map { |item| item.fetch("number") }
    assert_equal %w[OPEN CLOSED], result.map { |item| item.fetch("state") }
    assert_equal "https://github.com/acme/demo/issues/1", result.first.fetch("url")
    assert_equal marker, result.last.fetch("body")
    assert_equal 1, calls.size
    args, kwargs = calls.first
    assert_equal [
      "gh", "api", "--hostname", "github.com",
      "repos/acme/demo/issues?state=all&per_page=100",
      "--paginate", "--slurp"
    ], args
    assert_equal({ cfg: cfg }, kwargs)
  end

  def test_issues_with_marker_requires_the_exact_marker_bytes
    marker = "<!-- hive-refactor-patrol family=af1-exact action=issue:af1-exact -->"
    partial = "<!-- hive-refactor-patrol family=af1-exact -->"
    pages = [ [
      issue(1, state: "open", body: partial),
      issue(2, state: "closed", body: "prefix #{marker} suffix"),
      issue(3, state: "closed", body: "context\n#{marker}\nmore context")
    ] ]

    result = with_capture(successful(JSON.generate(pages))) do
      Hive::Gh.issues_with_marker(
        repository: "acme/demo", marker: marker, host: "github.com", cfg: nil
      )
    end

    assert_equal [ 3 ], result.map { |item| item.fetch("number") }
  end

  def test_issues_with_marker_rejects_malformed_json_pages_and_issue_shapes
    malformed = {
      "invalid JSON" => "{",
      "non-array envelope" => JSON.generate("items" => []),
      "flat non-slurped response" => JSON.generate([ issue(1, state: "open", body: "marker") ]),
      "non-array page" => JSON.generate([ { "items" => [] } ]),
      "non-object issue" => JSON.generate([ [ "issue" ] ]),
      "missing body key" => JSON.generate([ [ issue(1, state: "open", body: "marker").reject { |key| key == "body" } ] ]),
      "invalid issue state" => JSON.generate([ [ issue(1, state: "merged", body: "marker") ] ]),
      "invalid issue number" => JSON.generate([ [ issue(0, state: "open", body: "marker") ] ]),
      "wrong repository URL" => JSON.generate([ [
        issue(1, state: "open", body: "marker").merge(
          "html_url" => "https://github.com/other/demo/issues/1"
        )
      ] ])
    }

    malformed.each do |label, output|
      error = assert_raises(Hive::GhError, label) do
        with_capture(successful(output)) do
          Hive::Gh.issues_with_marker(
            repository: "acme/demo", marker: "marker", host: "github.com", cfg: nil
          )
        end
      end
      refute_empty error.message, label
    end
  end

  def test_issues_with_marker_fails_closed_on_remote_error
    capture = lambda do |*, **|
      [ "partial", "network unavailable", Hive::Gh::CommandStatus.new(exitstatus: 1) ]
    end

    error = assert_raises(Hive::GhError) do
      with_capture(capture) do
        Hive::Gh.issues_with_marker(
          repository: "acme/demo", marker: "marker", host: "github.com", cfg: nil
        )
      end
    end

    assert_includes error.message, "network unavailable"
    assert_includes error.message, "listing issues"
  end

  def test_issues_with_marker_validates_repository_before_running_gh
    called = false
    capture = lambda do |*, **|
      called = true
      successful("[]").call
    end

    [ "", "acme", "acme/demo/extra", "acme /demo", "acme/demo?state=open" ].each do |repository|
      assert_raises(Hive::GhError) do
        with_capture(capture) do
          Hive::Gh.issues_with_marker(
            repository: repository, marker: "marker", host: "github.com", cfg: nil
          )
        end
      end
    end
    refute called
  end

  def test_create_issue_uses_explicit_repository_and_exact_body_file_content
    calls = []
    body_paths = []
    cfg = { "gh" => { "network_timeout_sec" => 7 } }
    body = "## Architecture finding\n\nUnicode: café 🐝\n"
    capture = lambda do |*args, **kwargs|
      body_index = args.index("--body-file")
      path = args.fetch(body_index + 1)
      body_paths << path
      calls << [ args, kwargs, File.binread(path) ]
      [
        "https://github.com/acme/demo/issues/9\n", "",
        Hive::Gh::CommandStatus.new(exitstatus: 0)
      ]
    end

    url = with_capture(capture) do
      Hive::Gh.create_issue(
        repository: "acme/demo", title: "Architecture patrol: isolate policy",
        body: body, host: "github.com", cfg: cfg
      )
    end

    assert_equal "https://github.com/acme/demo/issues/9", url
    assert_equal 1, calls.size
    args, kwargs, transported_body = calls.first
    assert_equal "gh", args.first
    assert_equal "issue", args[1]
    assert_equal "create", args[2]
    assert_equal "github.com/acme/demo", args.fetch(args.index("--repo") + 1)
    assert_equal "Architecture patrol: isolate policy", args.fetch(args.index("--title") + 1)
    assert_equal body.b, transported_body
    assert_equal({ cfg: cfg }, kwargs)
    refute File.exist?(body_paths.first), "Tempfile.create block should remove the body file"
  end

  def test_create_issue_fails_closed_on_remote_error_and_empty_url
    remote_error = assert_raises(Hive::GhError) do
      failure = ->(*, **) { [ "", "permission denied", Hive::Gh::CommandStatus.new(exitstatus: 1) ] }
      with_capture(failure) do
        Hive::Gh.create_issue(
          repository: "acme/demo", title: "Title", body: "Body", host: "github.com", cfg: nil
        )
      end
    end
    assert_includes remote_error.message, "permission denied"

    empty_url = assert_raises(Hive::GhError) do
      with_capture(successful(" \n")) do
        Hive::Gh.create_issue(
          repository: "acme/demo", title: "Title", body: "Body", host: "github.com", cfg: nil
        )
      end
    end
    assert_includes empty_url.message, "no issue URL"

    wrong_repository = assert_raises(Hive::GhError) do
      with_capture(successful("https://github.com/other/demo/issues/9\n")) do
        Hive::Gh.create_issue(
          repository: "acme/demo", title: "Title", body: "Body", host: "github.com", cfg: nil
        )
      end
    end
    assert_includes wrong_repository.message, "unexpected issue URL"
  end

  def test_create_issue_validates_repository_before_creating_tempfile_or_running_gh
    called = false
    capture = lambda do |*, **|
      called = true
      successful("").call
    end

    assert_raises(Hive::GhError) do
      with_capture(capture) do
        Hive::Gh.create_issue(
          repository: "../demo", title: "Title", body: "Body", host: "github.com", cfg: nil
        )
      end
    end
    refute called
  end

  def test_issue_helpers_reject_urls_from_a_different_github_host
    wrong_host_pages = JSON.generate([ [
      issue(1, state: "open", body: "marker").merge(
        "html_url" => "https://github.com/acme/demo/issues/1"
      )
    ] ])
    lookup_error = assert_raises(Hive::GhError) do
      with_capture(successful(wrong_host_pages)) do
        Hive::Gh.issues_with_marker(
          repository: "acme/demo", marker: "marker", host: "github.example.test", cfg: nil
        )
      end
    end
    assert_includes lookup_error.message, "does not belong"

    create_error = assert_raises(Hive::GhError) do
      with_capture(successful("https://github.com/acme/demo/issues/9\n")) do
        Hive::Gh.create_issue(
          repository: "acme/demo", title: "Title", body: "Body",
          host: "github.example.test", cfg: nil
        )
      end
    end
    assert_includes create_error.message, "unexpected issue URL"
  end

  private

  def issue(number, state:, body:)
    {
      "number" => number,
      "state" => state,
      "html_url" => "https://github.com/acme/demo/issues/#{number}",
      "body" => body
    }
  end

  def successful(output)
    status = Hive::Gh::CommandStatus.new(exitstatus: 0)
    ->(*, **) { [ output, "", status ] }
  end

  def with_capture(replacement, &block)
    with_replaced_singleton_method(Hive::Gh, :capture3, replacement, &block)
  end
end
