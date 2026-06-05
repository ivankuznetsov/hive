require "test_helper"
require_relative "../../support/web_session_helper"
require "hive/web/app"
require "hive/commands/init"
require "hive/commands/new"

# Read-side route coverage (U4): the grid lists registered tasks once
# authenticated, and an unknown slug returns a 404 rather than leaking a
# stack trace.
class WebStatusRoutesTest < Minitest::Test
  include HiveTestHelper
  include WebSessionHelper

  def with_seeded_box
    with_tmp_global_config do |home|
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "grid probe").call }
        slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
        boot_web_app
        login!
        yield(project, slug, home)
      end
    end
  end

  def test_grid_lists_registered_tasks
    with_seeded_box do |project, slug, _home|
      get "/", {}, "HTTP_HOST" => "127.0.0.1"

      assert last_response.ok?, "authenticated GET / should render the grid"
      assert_includes last_response.body, project
      assert_includes last_response.body, slug
    end
  end

  def test_unknown_slug_returns_404
    with_seeded_box do |project, _slug, _home|
      get "/tasks/#{project}/does-not-exist", {}, "HTTP_HOST" => "127.0.0.1"

      assert_equal 404, last_response.status
      refute_match(/Traceback|NoMethodError|undefined method/, last_response.body)
    end
  end

  def test_unauthenticated_grid_redirects_to_login
    with_seeded_box do |_project, _slug, _home|
      clear_cookies
      get "/", {}, "HTTP_HOST" => "127.0.0.1"

      assert_equal 302, last_response.status
      assert_match(%r{/login\z}, last_response["Location"])
    end
  end

  def test_diff_returns_404_when_worktree_missing
    with_seeded_box do |project, slug, _home|
      get "/tasks/#{project}/#{slug}/diff", {}, "HTTP_HOST" => "127.0.0.1"

      assert_equal 404, last_response.status, "no worktree on disk for a 1-inbox task → 404"
      assert_includes last_response.body, "worktree not found"
    end
  end

  def test_diff_rejects_malformed_slug_before_filesystem_access
    with_seeded_box do |project, _slug, _home|
      # A dotted slug isn't a valid task-folder name; safe_slug! must halt
      # before any File.join/git runs (path-traversal guard).
      get "/tasks/#{project}/has.dots/diff", {}, "HTTP_HOST" => "127.0.0.1"

      assert_equal 404, last_response.status
      assert_includes last_response.body, "unknown task"
    end
  end

  def test_logs_rejects_malformed_slug
    with_seeded_box do |project, _slug, _home|
      get "/tasks/#{project}/has.dots/logs", {}, "HTTP_HOST" => "127.0.0.1"

      assert_equal 404, last_response.status
      assert_includes last_response.body, "unknown task"
    end
  end

  # Counts acquire/release so a test can prove a route never leaks a slot.
  class CountingLimiter
    attr_reader :live

    def initialize(max:)
      @max = max
      @live = 0
      @mutex = Mutex.new
    end

    def acquire
      @mutex.synchronize do
        return false if @live >= @max

        @live += 1
        true
      end
    end

    def release
      @mutex.synchronize { @live -= 1 if @live.positive? }
    end
  end

  # A limiter that is always full: every SSE route must reject with 503.
  class FullLimiter
    def acquire = false
    def release; end
  end

  # Status feed that yields exactly one snapshot then returns, so a Rack::Test
  # request can drive the /events emission path to completion (it would
  # otherwise loop forever). on_idle is exercised by yielding nothing on a
  # second pass is unnecessary here — the single yield covers the data frame.
  class OneShotFeed
    def snapshot = { "schema" => "hive-status", "projects" => [] }

    def each_snapshot(on_idle: nil)
      on_idle # referenced to satisfy the signature
      yield({ "projects" => [ { "name" => "demo", "tasks" => [] } ] })
    end
  end

  # Status feed that raises IOError (the client vanished mid-write), exercising
  # the /events `rescue IOError` path that must swallow it and release.
  class DisconnectingFeed
    def snapshot = { "schema" => "hive-status", "projects" => [] }
    def each_snapshot(on_idle: nil) = raise(IOError, "client gone")
  end

  # P1-9: the 503 (limiter full) body must NOT inherit the SSE content type —
  # the error has to read as plain text, not a malformed event-stream frame.
  def test_events_503_is_not_event_stream
    with_seeded_box do |_project, _slug, _home|
      @app.set :sse_limiter, FullLimiter.new

      get "/events", {}, "HTTP_HOST" => "127.0.0.1"

      assert_equal 503, last_response.status
      refute_match(/text\/event-stream/, last_response.content_type.to_s,
                   "the 503 body must not be framed as an SSE event-stream")
      assert_includes last_response.body, "too many live connections"
    end
  end

  def test_logs_503_is_not_event_stream
    with_seeded_box do |project, slug, _home|
      write_log(project, slug, "line one\n")
      @app.set :sse_limiter, FullLimiter.new

      get "/tasks/#{project}/#{slug}/logs", {}, "HTTP_HOST" => "127.0.0.1"

      assert_equal 503, last_response.status
      refute_match(/text\/event-stream/, last_response.content_type.to_s)
    end
  end

  # P1-8: if a stream cannot start, the acquired slot must still be released —
  # never leaked. We make `stream` raise before its block runs by feeding the
  # status feed an each_snapshot that raises; the route-level ensure releases.
  def test_events_releases_slot_when_stream_raises
    with_seeded_box do |_project, _slug, _home|
      limiter = CountingLimiter.new(max: 4)
      @app.set :sse_limiter, limiter
      @app.set :status_feed, RaisingFeed.new

      # The stream body runs deferred (during response buffering) and raises;
      # what matters is that the acquired slot is ALWAYS released regardless,
      # so it can never leak. Swallow the propagated stream error and assert
      # the slot count returned to zero.
      begin
        get "/events", {}, "HTTP_HOST" => "127.0.0.1"
      rescue RuntimeError => e
        raise unless e.message == "stream boom"
      end

      assert_equal 0, limiter.live, "a stream that raises must still release its SSE slot (no leak)"
    end
  end

  # P1-8 (the core leak): if `stream` ITSELF raises synchronously — before the
  # block ever runs, so the block's own ensure can never fire — the
  # route-level ensure must still release the acquired slot. Force that by
  # making `stream` raise.
  def test_events_release_when_stream_helper_raises_synchronously
    with_seeded_box do |_project, _slug, _home|
      limiter = CountingLimiter.new(max: 4)
      @app.set :sse_limiter, limiter
      with_raising_stream do
        begin
          get "/events", {}, "HTTP_HOST" => "127.0.0.1"
        rescue RuntimeError => e
          raise unless e.message == "no stream for you"
        end
      end

      assert_equal 0, limiter.live, "a synchronous stream failure must still release the slot"
    end
  end

  def test_logs_release_when_stream_helper_raises_synchronously
    with_seeded_box do |project, slug, _home|
      write_log(project, slug, "seed\n")
      limiter = CountingLimiter.new(max: 4)
      @app.set :sse_limiter, limiter
      with_raising_stream do
        begin
          get "/tasks/#{project}/#{slug}/logs", {}, "HTTP_HOST" => "127.0.0.1"
        rescue RuntimeError => e
          raise unless e.message == "no stream for you"
        end
      end

      assert_equal 0, limiter.live, "a synchronous stream failure must still release the slot"
    end
  end

  # P1-10/server contract: a live /events stream emits a NAMED `status` event
  # with a JSON data frame the frontend subscribes to. Drive one snapshot to
  # completion and assert the frame shape.
  def test_events_emits_named_status_frame
    with_seeded_box do |_project, _slug, _home|
      limiter = CountingLimiter.new(max: 4)
      @app.set :sse_limiter, limiter
      @app.set :status_feed, OneShotFeed.new

      get "/events", {}, "HTTP_HOST" => "127.0.0.1"

      assert_includes last_response.body, "event: status\n", "the live feed must emit a named status event"
      assert_includes last_response.body, %(data: {"projects":), "the frame carries the snapshot JSON"
      assert_equal 0, limiter.live, "the completed stream must release its slot"
    end
  end

  # P1-8: an IOError mid-stream (client disconnected) must be swallowed and the
  # slot released — not surfaced as a 500 or leaked.
  def test_events_swallows_ioerror_and_releases
    with_seeded_box do |_project, _slug, _home|
      limiter = CountingLimiter.new(max: 4)
      @app.set :sse_limiter, limiter
      @app.set :status_feed, DisconnectingFeed.new

      get "/events", {}, "HTTP_HOST" => "127.0.0.1"

      assert_equal 0, limiter.live, "an IOError mid-stream must still release the slot"
    end
  end

  # P3/F10 happy path: a real worktree with an actual diff returns 200 and the
  # diff body (the `@diff = out` success branch).
  def test_diff_returns_200_with_real_diff
    with_seeded_box do |project, slug, _home|
      worktree = make_git_worktree_with_diff(project, slug)
      assert File.directory?(worktree)

      get "/tasks/#{project}/#{slug}/diff", {}, "HTTP_HOST" => "127.0.0.1"

      assert_equal 200, last_response.status, "a successful git diff renders 200"
      assert_includes last_response.body, "changed line", "the rendered diff shows the change"
    end
  end

  # P1-10: the content-emission branch — new bytes appended after the stream
  # starts must be framed as a named `log` event. A writer thread appends just
  # after the tail begins so the empty-then-content path runs.
  def test_logs_stream_emits_appended_content
    with_seeded_box do |project, slug, _home|
      log = write_log(project, slug, "")
      limiter = CountingLimiter.new(max: 4)
      @app.set :sse_limiter, limiter
      @app.set :log_stream_tick, 0.02
      @app.set :log_stream_idle_timeout, 2.0

      writer = Thread.new do
        # Append after the tail has reached EOF and entered its first idle wait.
        sleep 0.05
        File.open(log, "a") { |f| f.write("hello world\n") }
        # Then let the idle budget end the stream.
      end

      get "/tasks/#{project}/#{slug}/logs", {}, "HTTP_HOST" => "127.0.0.1"
      writer.join

      assert_includes last_response.body, "event: log\n", "appended bytes must emit a named log event"
      assert_includes last_response.body, "data: hello world", "the appended line is framed as data"
      assert_equal 0, limiter.live
    end
  end

  # P1-8/P1-10: a write to a vanished client raises IOError mid-tail; the log
  # stream must swallow it (rescue IOError) and still release the slot. Drive
  # `stream` with a fake `out` whose first write raises IOError.
  def test_logs_stream_swallows_ioerror_on_write
    with_seeded_box do |project, slug, _home|
      write_log(project, slug, "")
      limiter = CountingLimiter.new(max: 4)
      @app.set :sse_limiter, limiter
      @app.set :log_stream_tick, 0.001
      @app.set :log_stream_idle_timeout, 5.0
      with_ioerror_stream do
        get "/tasks/#{project}/#{slug}/logs", {}, "HTTP_HOST" => "127.0.0.1"
      end

      assert_equal 0, limiter.live, "an IOError mid-tail must still release the slot"
    end
  end

  # P1-10: an idle/closed log stream must terminate and release the slot
  # rather than parking the thread forever. Drive it with a sub-millisecond
  # idle timeout so the bounded-idle break fires immediately.
  def test_logs_stream_terminates_and_releases_when_idle
    with_seeded_box do |project, slug, _home|
      write_log(project, slug, "seed\n")
      limiter = CountingLimiter.new(max: 4)
      @app.set :sse_limiter, limiter
      @app.set :log_stream_tick, 0.001
      @app.set :log_stream_idle_timeout, 0.001

      get "/tasks/#{project}/#{slug}/logs", {}, "HTTP_HOST" => "127.0.0.1"

      assert_equal 200, last_response.status
      assert_equal 0, limiter.live, "an idle log stream must release its SSE slot"
      assert_includes last_response.body, ": keep-alive", "an idle tail emits keep-alive comments"
    end
  end

  # P1-10: the log frame must be a NAMED `event: log` with proper multi-line
  # `data:` framing (one data line per source line) — not the old literal
  # `\n`-escape that no consumer could parse.
  def test_log_event_uses_named_event_and_multiline_framing
    frame = Hive::Web::App.encode_log_event("alpha\nbeta")

    assert_includes frame, "event: log\n", "log frames must carry a named `log` event"
    assert_includes frame, "data: alpha\n", "first line gets its own data: field"
    assert_includes frame, "data: beta\n", "second line gets its own data: field"
    refute_includes frame, "\\n", "must not literal-escape newlines inside one data: field"
  end

  # P3/F10: a failed `git diff` must surface as 422, not a 200 that renders
  # stderr as if it were a real diff. Point the worktree at a non-git dir so
  # git exits non-zero.
  def test_diff_fails_with_422_when_git_errors
    with_seeded_box do |project, slug, _home|
      worktree = make_non_git_worktree(project, slug)
      assert File.directory?(worktree)

      get "/tasks/#{project}/#{slug}/diff", {}, "HTTP_HOST" => "127.0.0.1"

      assert_equal 422, last_response.status, "a git diff failure must be a 422, not a 200"
      assert_includes last_response.body, "git diff failed"
    end
  end

  private

  # Status feed whose each_snapshot raises before yielding, simulating a
  # stream that fails to start.
  class RaisingFeed
    def snapshot = { "schema" => "hive-status", "projects" => [] }
    def each_snapshot(*, **) = raise(RuntimeError, "stream boom")
  end

  # A fake SSE sink that is "open" but raises IOError the moment anything is
  # written to it — i.e. the client socket died between accept and first write.
  class IOErrorOut
    def closed? = false
    def <<(_chunk) = raise(IOError, "broken pipe")
    def close; end
  end

  # Override `stream` so it yields an IOErrorOut to the route block, exercising
  # the route's `rescue IOError` path. Removed afterward so it can't leak.
  def with_ioerror_stream
    sink = IOErrorOut.new
    Hive::Web::App.send(:define_method, :stream) { |*, **, &blk| blk.call(sink) }
    yield
  ensure
    Hive::Web::App.send(:remove_method, :stream)
  end

  # Temporarily override the app's `stream` helper so it raises synchronously
  # (before any stream block runs), then remove the override so it can't leak
  # into sibling tests sharing the reloaded App class.
  def with_raising_stream
    Hive::Web::App.send(:define_method, :stream) { |*, **| raise "no stream for you" }
    yield
  ensure
    Hive::Web::App.send(:remove_method, :stream)
  end

  def write_log(project, slug, content)
    project_hash = settings_project(project)
    dir = File.join(project_hash["hive_state_path"], "logs", slug)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "agent.log")
    File.write(path, content)
    path
  end

  # Build a real git worktree with a committed file and an uncommitted edit so
  # `git diff` produces non-empty output (the diff success path).
  def make_git_worktree_with_diff(project, slug)
    worktree = worktree_path(project, slug)
    FileUtils.mkdir_p(worktree)
    system("git", "-C", worktree, "init", "-q", exception: true)
    system("git", "-C", worktree, "config", "user.email", "t@example.com", exception: true)
    system("git", "-C", worktree, "config", "user.name", "T", exception: true)
    file = File.join(worktree, "f.txt")
    File.write(file, "original line\n")
    system("git", "-C", worktree, "add", "f.txt", exception: true)
    system("git", "-C", worktree, "commit", "-q", "-m", "seed", exception: true)
    File.write(file, "changed line\n")
    worktree
  end

  def worktree_path(project, slug)
    project_hash = settings_project(project)
    cfg = Hive::Config.load(project_hash["path"])
    root = cfg["worktree_root"] || File.expand_path("~/Dev/#{project}.worktrees")
    File.join(root, slug)
  end

  def make_non_git_worktree(project, slug)
    worktree = worktree_path(project, slug)
    FileUtils.mkdir_p(worktree)
    worktree
  end

  def settings_project(project)
    Hive::Config.registered_projects.find { |p| p["name"] == project }
  end
end
