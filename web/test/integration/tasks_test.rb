require "test_helper"
require "open3"
require "tmpdir"
require_relative "../../../test/support/workflow_helpers"

class TasksTest < ActionDispatch::IntegrationTest
  include HiveWorkflowTestHelper

  setup do
    @project = create_hive_project!
    @slug = create_task!(@project, "actions probe")
    sign_in!
  end

  test "status grid lists the task" do
    get "/grid"
    assert_response :success
    assert_match @slug, response.body
    assert_select "#status-grid", 1
  end

  test "closure entry requires authentication" do
    post "/logout"

    get "/tasks/#{@project}/#{@slug}/closure"

    assert_redirected_to "/login"
  end

  test "closure preview normalizes evidence and renders exact verified facts" do
    input = {
      "reason" => "already_delivered",
      "evidence" => [ "acme/app#42", "b" * 40 ],
      "successor" => nil,
      "attestation" => nil
    }
    preview = Hive::TaskClosure::Preview.new(
      input: input,
      task: { "project" => @project, "slug" => @slug },
      task_repository: {
        "identity" => "github.com/acme/app",
        "host" => "github.com",
        "repository" => "acme/app",
        "default_branch" => "main"
      },
      evidence: [
        {
          "kind" => "pull_request",
          "repository" => "acme/app",
          "number" => 42,
          "oid" => "a" * 40,
          "url" => "https://github.com/acme/app/pull/42"
        }
      ],
      successor: nil,
      authority: "remote_merge",
      evidence_digest: "e" * 64,
      preview_digest: "d" * 64,
      errors: [],
      blockers: []
    )
    calls = []

    with_replaced_singleton_method(
      Hive::TaskClosure, :preview, lambda { |**kwargs|
        calls << kwargs
        preview
      }
    ) do
      post "/tasks/#{@project}/#{@slug}/closure", params: {
        reason: "already_delivered",
        evidence: [ "acme/app#42\n#{'b' * 40}\n" ]
      }
    end

    assert_response :success
    assert_select ".closure-preview", 1
    assert_select "form input[name=preview_digest][value=?]", "d" * 64
    assert_select "a[href='https://github.com/acme/app/pull/42']", text: /42/
    assert_equal input, calls.first.fetch(:input)
  end

  test "closure confirmation uses the authenticated web operator" do
    calls = []
    confirmer = lambda do |**kwargs|
      calls << kwargs
      { "reason" => "already_delivered", "receipt_digest" => "e" * 64 }
    end

    with_replaced_singleton_method(Hive::TaskClosure, :confirm!, confirmer) do
      post "/tasks/#{@project}/#{@slug}/closure", params: {
        reason: "already_delivered",
        evidence: [ "acme/app#42" ],
        preview_digest: "d" * 64
      }
    end

    assert_redirected_to "/tasks/#{@project}/#{@slug}"
    assert_equal true, calls.first.fetch(:authorized)
    assert_equal "web", calls.first.fetch(:channel)
    assert_equal "alice", calls.first.fetch(:operator)
    assert_equal "d" * 64, calls.first.fetch(:preview_digest)
  end

  test "closure confirmation is CSRF protected" do
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    post "/tasks/#{@project}/#{@slug}/closure", params: {
      reason: "already_delivered",
      evidence: [ "acme/app#42" ],
      preview_digest: "d" * 64
    }

    assert_response :unprocessable_entity
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  test "task detail renders canonical closure evidence" do
    receipt = {
      "schema" => Hive::TaskClosure::SCHEMA,
      "schema_version" => 1,
      "reason" => "already_delivered",
      "authority" => "remote_merge",
      "receipt_digest" => "d" * 64,
      "evidence" => [
        {
          "repository" => "acme/app",
          "number" => 42,
          "oid" => "a" * 40,
          "url" => "https://github.com/acme/app/pull/42"
        }
      ]
    }

    with_replaced_singleton_method(Hive::TaskClosure, :projection, ->(*, **) { receipt }) do
      get "/tasks/#{@project}/#{@slug}"
    end

    assert_response :success
    assert_select ".task-closure", text: /already delivered/
    assert_select ".task-closure a[href='https://github.com/acme/app/pull/42']",
                  text: /42/
    assert_select ".task-closure code", text: "d" * 64
  end

  test "an archive link resolves a task omitted from the ordinary snapshot" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    row = {
      "slug" => @slug,
      "folder" => folder.to_s,
      "stage" => "9-done",
      "workflow" => "coding",
      "action" => "archived",
      "action_label" => "Archived",
      "age_seconds" => 10 * 86_400
    }
    ordinary = {
      "projects" => [
        { "name" => @project, "tasks" => [], "hidden_archived_task_count" => 1 }
      ]
    }
    archive = {
      "projects" => [
        { "name" => @project, "tasks" => [ row ] }
      ]
    }
    ordinary_snapshot = lambda do
      StatusBroadcaster::PageSnapshot.new(payload: ordinary, version: "ordinary-version")
    end
    archive_snapshot = -> { archive }

    with_replaced_singleton_method(StatusBroadcaster, :snapshot_with_version, ordinary_snapshot) do
      with_replaced_singleton_method(StatusBroadcaster, :archive_snapshot, archive_snapshot) do
        get task_path(@project, @slug)
        assert_response :not_found

        get task_path(@project, @slug, source: "archive")
        assert_response :success
        assert_select "#status-stream-owner[data-status-version='ordinary-version']"
        assert_select ".task-header", text: /#{Regexp.escape(@slug.sub(/-\d{6}-\h{4}\z/, "").tr("-", " "))}/i
      end
    end
  end

  test "task state renders implementation ownership as pending without mutating legacy state" do
    folder = stage_dir(@project, "1-inbox").join(@slug)

    get "/tasks/#{@project}/#{@slug}"

    assert_response :success
    assert_select "details.implementation-identity", 1
    assert_select "details.implementation-identity summary", text: /generation 0/
    assert_select "details.implementation-identity", text: /Pending execute capture/
    refute folder.join("events.jsonl").exist?
    refute folder.join("task-projection.json").exist?
  end

  test "an unpassable stage offers Force approve, never a doomed Approve" do
    get "/tasks/#{@project}/#{@slug}"
    assert_response :success
    assert_match "idea.md", response.body
    assert_select ".advanced form[action=?] button", "/tasks/#{@project}/#{@slug}/approve",
                  text: "Force approve", count: 1
    assert_select ".task-actions > form[action=?]", "/tasks/#{@project}/#{@slug}/approve",
                  count: 0
  end

  test "Advanced offers Drop, and dropping deletes the task for good" do
    get "/tasks/#{@project}/#{@slug}"
    assert_select ".advanced form[action=?] button", "/tasks/#{@project}/#{@slug}/drop",
                  text: "Drop", count: 1, message: "Drop must live in Advanced, not among primary actions"
    assert_select ".task-actions > form[action=?]", "/tasks/#{@project}/#{@slug}/drop", count: 0

    post "/tasks/#{@project}/#{@slug}/drop", params: { from: "1-inbox" }
    assert_redirected_to "/"
    refute stage_dir(@project, "1-inbox").join(@slug).directory?,
           "drop must hard-delete the task folder — Shift+X parity, no archive"
  end

  test "drop from a stale page is a readable error, not a deletion" do
    # The page rendered while the task sat in 1-inbox; by submit time it
    # moved on. The stage-scoped resolve must refuse rather than delete a
    # task whose state the operator never saw.
    FileUtils.mv(stage_dir(@project, "1-inbox").join(@slug),
                 stage_dir(@project, "2-brainstorm").join(@slug))

    post "/tasks/#{@project}/#{@slug}/drop", params: { from: "1-inbox" }
    assert_response :unprocessable_entity
    assert stage_dir(@project, "2-brainstorm").join(@slug).directory?,
           "a stale drop must leave the moved task untouched"
  end

  test "finalize leads with the deliverable: artifact.md first and open" do
    FileUtils.mv(stage_dir(@project, "1-inbox").join(@slug),
                 stage_dir(@project, "8-finalize").join(@slug))
    folder = stage_dir(@project, "8-finalize").join(@slug)
    folder.join("artifact.md").write("# Deliverable\n\nDone.\n")

    get "/tasks/#{@project}/#{@slug}"
    assert_response :success
    names = css_select("details[data-artifact-name]").map { |d| d["data-artifact-name"] }
    assert_equal "artifact.md", names.first,
                 "from finalize on, the run's deliverable is what the page is opened for"
    assert css_select("details[data-artifact-name='artifact.md']").first["open"],
           "the leading artifact must render expanded"
    assert_includes names, "idea.md", "the chronological story still follows"
  end

  test "a non-coding workflow renders its own stage artifacts, derived from the descriptor" do
    with_registered_workflow(content_workflow) do
      project = create_hive_project!("content-app")
      slug = "content-piece-260620-aaaa"
      folder = stage_dir(project, "2-research").join(slug)
      folder.mkpath
      folder.join("idea.md").write("---\ncreated_at: 2026-06-20\n---\nWrite about hive\n")
      folder.join("research.md").write("# Research\n\nFindings here.\n")
      Hive::TaskMeta.write(folder.to_s, id: 1, slug: slug, display_name: nil, workflow: "content_fixture")

      get "/tasks/#{project}/#{slug}"
      assert_response :success
      names = css_select("details[data-artifact-name]").map { |d| d["data-artifact-name"] }
      assert_includes names, "research.md",
                      "a non-coding stage artifact (research.md) must render — ARTIFACT_ORDER never lists it"
      assert_equal "idea.md", names.first, "content workflow still reads idea-first"
    end
  end

  test "earlier stages keep the chronological order, idea first" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    folder.join("artifact.md").write("# Early\n")

    get "/tasks/#{@project}/#{@slug}"
    names = css_select("details[data-artifact-name]").map { |d| d["data-artifact-name"] }
    assert_equal "idea.md", names.first, "working stages read top-to-bottom as a story"
  end

  test "the log renders after the artifacts" do
    log_dir = stage_dir(@project, "1-inbox").join("..", "..", "logs", @slug)
    log_dir.mkpath
    log_dir.join("stage-20260611T000000Z.log").write("one line\n")

    get "/tasks/#{@project}/#{@slug}"
    assert_response :success
    artifacts_at = response.body.index("<h2>Artifacts</h2>")
    log_at = response.body.index("<h2>Log</h2>")
    refute_nil artifacts_at
    refute_nil log_at
    assert_operator artifacts_at, :<, log_at, "the log is an appendix — artifacts come first"
  end

  test "md artifacts render as sanitized markdown, not raw text" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    folder.join("plan.md").write(<<~MD)
      ---
      created_at: 2026-06-11
      ---
      ## The Plan

      | step | what |
      |------|------|
      | 1    | ship |

      **bold move** and <script>alert(1)</script> stays inert.

      ```
      a code sample documenting <!-- COMPLETE --> markers
      ```

      <!-- a plain html comment -->

      <!-- COMPLETE -->
    MD

    get "/tasks/#{@project}/#{@slug}"
    assert_response :success
    plan = css_select("details[data-artifact-name='plan.md'] .markdown").first.to_s
    assert_includes plan, "<h2>The Plan</h2>", "headings must render as headings"
    assert_includes plan, "<td>ship</td>", "GFM tables must render as tables"
    assert_includes plan, "<strong>bold move</strong>"
    refute_includes plan, "<script>", "agent-written HTML must never execute"
    refute_includes plan, "created_at", "front matter is metadata, not prose"
    assert_includes plan, "a code sample documenting &lt;!-- COMPLETE --&gt; markers",
                     "a fenced example mentioning a marker is CONTENT, not machinery"
    assert_includes plan, "a plain html comment",
                     "escape_html renders non-marker comments as text — only real markers vanish"
    refute_match(/^<p>.*<!-- COMPLETE -->.*<\/p>/, plan,
                 "real marker lines are machinery — the stage badge owns that state")
    refute_includes plan.gsub(/a code sample[^<]*/, ""), "&lt;!-- COMPLETE",
                    "the standalone marker line must be stripped"
  end

  test "media route streams committed stills and gifs inline" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    media_fixture!(folder)

    get "/tasks/#{@project}/#{@slug}/media/01-home.png"
    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal png_bytes, response.body.b

    get "/tasks/#{@project}/#{@slug}/media/demo.gif"
    assert_response :success
    assert_equal "image/gif", response.media_type
    assert_equal gif_bytes, response.body.b
  end

  test "media route streams committed jpeg stills inline" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    media_dir = folder.join("media")
    media_dir.mkpath
    File.binwrite(media_dir.join("02-state.jpg"), jpg_bytes)

    get "/tasks/#{@project}/#{@slug}/media/02-state.jpg"
    assert_response :success
    assert_equal "image/jpeg", response.media_type
    assert_equal jpg_bytes, response.body.b
  end

  test "media route streams retained webm demos inline" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    media_dir = folder.join("media")
    media_dir.mkpath
    bytes = "synthetic-webm".b
    File.binwrite(media_dir.join("demo.webm"), bytes)

    get "/tasks/#{@project}/#{@slug}/media/demo.webm"

    assert_response :success
    assert_equal "video/webm", response.media_type
    assert_equal bytes, response.body.b
  end

  test "media responses are privately cached, never shared-proxy cacheable" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    media_fixture!(folder)

    get "/tasks/#{@project}/#{@slug}/media/01-home.png"
    assert_response :success
    cache_control = response.headers["Cache-Control"].to_s
    assert_includes cache_control, "max-age=60", "the media response must carry the 60s freshness window"
    assert_includes cache_control, "private",
                    "a user's task screenshots must not be cacheable by a shared proxy"
    refute_includes cache_control, "public",
                    "a regression to public:true would leak authenticated screenshots into shared caches"
  end

  test "a manifest with an unknown schema version hides the demo section" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    media_fixture!(folder)
    # Bump the on-disk manifest to a future schema the reader must not render.
    manifest = JSON.parse(folder.join("media", "manifest.json").read)
    manifest["schema"] = 2
    folder.join("media", "manifest.json").write("#{JSON.pretty_generate(manifest)}\n")

    get "/tasks/#{@project}/#{@slug}"
    assert_response :success
    assert_select "section.demo", count: 0,
                  message: "a future-schema manifest must be ignored, not rendered as garbage v1 items"
  end

  test "media route refuses traversal disallowed extensions and missing files" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    media_fixture!(folder)
    folder.join("media", "secret.rb").write("puts :nope")

    get "/tasks/#{@project}/#{@slug}/media/..%2f..%2fconfig.yml"
    assert_response :not_found

    get "/tasks/#{@project}/#{@slug}/media/secret.rb"
    assert_response :not_found

    get "/tasks/#{@project}/#{@slug}/media/missing.png"
    assert_response :not_found
  end

  test "media route refuses a symlinked media directory" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    media_fixture!(folder)
    outside = Pathname.new(Dir.mktmpdir("hive-media-escape"))
    File.binwrite(outside.join("01-home.png"), png_bytes)
    FileUtils.rm_rf(folder.join("media"))
    File.symlink(outside, folder.join("media"))

    get "/tasks/#{@project}/#{@slug}/media/01-home.png"
    assert_response :not_found
  ensure
    FileUtils.rm_rf(outside) if outside
  end

  test "media route 404s a valid-shape slug that names no task" do
    # A slug that satisfies the route constraint but matches no task row hits
    # the shared Task.find! -> InvalidTaskPath -> 404 path, the same handling
    # every other action gets for an unknown task (plan U3/U5).
    get "/tasks/#{@project}/ghost-task-260101-zzzz/media/01-home.png"
    assert_response :not_found
  end

  test "task page renders captured media gallery and screenote links" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    media_fixture!(folder)

    get "/tasks/#{@project}/#{@slug}"

    assert_response :success
    assert_select "section.demo h2", text: "Demo", count: 1
    assert_select "img[src=?][alt=?]", "/tasks/#{@project}/#{@slug}/media/01-home.png", "Home page after load", count: 1
    assert_select "img[src=?][alt=?]", "/tasks/#{@project}/#{@slug}/media/demo.gif", "Dark mode toggle", count: 1
    assert_select "figcaption", text: /Home page after load/
    assert_select "a[href='https://screenote.test/shot']", text: "View / annotate on screenote", count: 1
  end

  test "task page renders capture failed banner without broken images" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    write_media_manifest(folder, {
      "schema" => 1,
      "status" => "failed",
      "reason" => "dev server did not boot",
      "surface" => "ui",
      "items" => []
    })

    get "/tasks/#{@project}/#{@slug}"

    assert_response :success
    assert_select ".demo-banner", text: /Demo capture failed/
    assert_select ".demo-banner", text: /dev server did not boot/
    assert_select "section.demo img", count: 0
  end

  test "task page hides demo section for skipped or absent manifest" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    write_media_manifest(folder, {
      "schema" => 1,
      "status" => "skipped",
      "reason" => "no observable surface",
      "surface" => "none",
      "items" => []
    })

    get "/tasks/#{@project}/#{@slug}"
    assert_response :success
    assert_select "section.demo", count: 0

    FileUtils.rm_rf(folder.join("media"))
    get "/tasks/#{@project}/#{@slug}"
    assert_response :success
    assert_select "section.demo", count: 0
    assert_match "idea.md", response.body
  end

  test "a valid-JSON manifest with a non-object top level does not 500 the page" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    media_dir = folder.join("media")
    media_dir.mkpath

    [ "[]", "42", "null" ].each do |body|
      media_dir.join("manifest.json").write(body)
      get "/tasks/#{@project}/#{@slug}"
      assert_response :success, "a #{body.inspect} manifest must render the page, not raise"
      assert_select "section.demo", count: 0
    end
  end

  test "a captured manifest with only malformed items renders no empty demo section" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    write_media_manifest(folder, {
      "schema" => 1,
      "status" => "captured",
      "surface" => "ui",
      "items" => [
        "not-a-hash",
        { "file" => "../../etc/passwd.png", "type" => "still", "caption" => "traversal" },
        { "file" => "missing.png", "type" => "still", "caption" => "no file on disk" }
      ]
    })

    get "/tasks/#{@project}/#{@slug}"
    assert_response :success
    assert_select "section.demo", count: 0,
                  message: "all items filtered out → no bare Demo heading"
  end

  test "a captured manifest with a literal empty items list renders no demo section" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    write_media_manifest(folder, {
      "schema" => 1,
      "status" => "captured",
      "surface" => "ui",
      "items" => []
    })

    get "/tasks/#{@project}/#{@slug}"
    assert_response :success
    assert_select "section.demo", count: 0,
                  message: "a captured manifest with no items must not render a bare Demo heading"
  end

  test "a red task offers Retry which queues one identity-bound recovery request" do
    FileUtils.mv(stage_dir(@project, "1-inbox").join(@slug),
                 stage_dir(@project, "6-review").join(@slug))
    folder = stage_dir(@project, "6-review").join(@slug)
    state_file = folder.join("task.md")
    state_file.write("# t\n")
    Hive::Markers.set(
      state_file,
      :review_error,
      phase: "triage",
      reason: "merge_conflict",
      pass: 1
    )
    marker_id = Hive::Markers.current(state_file).attrs.fetch("marker_id")
    File.utime(Time.now - 3600, Time.now - 3600, state_file)

    get "/tasks/#{@project}/#{@slug}"
    assert_response :success
    assert_select ".state-banner-error", { count: 1, text: /REVIEW_ERROR|triage/ },
                  "the red state must say WHY, not just need recovery"
    assert_select ".task-actions form[action=?] button", "/tasks/#{@project}/#{@slug}/recover",
                  text: "Retry stage", count: 1

    post "/tasks/#{@project}/#{@slug}/recover"
    assert_redirected_to "/tasks/#{@project}/#{@slug}"
    assert_match(/\ARecovery queued — request /, flash[:notice])
    queue = Dir.glob(File.join(ENV["HIVE_HOME"], "**", "dispatch_request*", "**", "*"))
               .select { |f| File.file?(f) }
    payload = queue.filter_map do |path|
      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end.find { |entry| entry["slug"] == @slug }
    refute_nil payload
    assert_equal "web", payload.fetch("requestor")
    assert_equal "admitted", payload.dig("recovery", "phase")
    assert_equal marker_id, payload.fetch("expected_marker_id")
    refute_equal "markers", payload.fetch("argv")[1],
                 "the web surface must not recreate marker-clear authority"
  end

  test "recovery lifecycle renders an accessible status and disables duplicate actions" do
    FileUtils.mv(stage_dir(@project, "1-inbox").join(@slug),
                 stage_dir(@project, "6-review").join(@slug))
    state_file = stage_dir(@project, "6-review").join(@slug, "task.md")
    state_file.write("# t\n\n<!-- REVIEW_ERROR phase=triage reason=merge_conflict pass=1 -->\n")
    snapshot = StatusBroadcaster.snapshot
    row = snapshot.fetch("projects")
                  .find { |project| project["name"] == @project }
                  .fetch("tasks")
                  .find { |task| task["slug"] == @slug }
    row["recovery"] = {
      "status" => "queued",
      "request_id" => "recovery-1",
      "attempt_id" => nil,
      "phase" => "admitted",
      "failure_origin" => "merge_conflict",
      "next_eligible_at" => nil,
      "owner" => "scheduler",
      "reason" => nil,
      "remediation" => nil,
      "retry_count" => 1,
      "provider_hint" => nil,
      "terminal_outcome" => nil,
      "terminal_at" => nil
    }
    replacement = proc do
      StatusBroadcaster::PageSnapshot.new(payload: snapshot, version: "test-recovery")
    end

    with_replaced_singleton_method(StatusBroadcaster, :snapshot_with_version, replacement) do
      get "/tasks/#{@project}/#{@slug}"
      assert_response :success
      assert_select ".recovery-lifecycle[role=status][aria-live=polite][data-recovery-status=queued]",
                    text: /Recovery queued.*request recovery-1.*origin merge_conflict/
      assert_select ".task-actions form[action=?] button[disabled]",
                    "/tasks/#{@project}/#{@slug}/recover",
                    text: "Retry stage",
                    count: 1

      row["recovery"] = row.fetch("recovery").merge(
        "status" => "terminal",
        "phase" => "terminal",
        "attempt_id" => "attempt-1",
        "terminal_outcome" => "succeeded",
        "terminal_at" => "2026-07-25T12:00:00.000000Z"
      )
      get "/tasks/#{@project}/#{@slug}"
      assert_response :success
      assert_select ".recovery-lifecycle[data-recovery-status=terminal]",
                    text: /Completed.*attempt attempt-1.*succeeded/
      assert_select ".task-actions form[action=?]",
                    "/tasks/#{@project}/#{@slug}/recover",
                    count: 0
    end
  end

  test "recover on a healthy task is a readable 422, not a hidden run" do
    post "/tasks/#{@project}/#{@slug}/recover"
    assert_response :unprocessable_entity
    queue = Dir.glob(File.join(ENV["HIVE_HOME"], "**", "dispatch_request*", "**", "*"))
               .select { |f| File.file?(f) }
    assert queue.none? { |f| File.read(f).include?(@slug) },
           "a refused recover must queue NOTHING — a bare rerun behind a flash would be a hidden Run"
  end

  test "a healthy task shows no Retry button" do
    get "/tasks/#{@project}/#{@slug}"
    assert_select ".task-actions form[action=?]", "/tasks/#{@project}/#{@slug}/recover", count: 0
  end

  test "a complete stage offers Approve and hides the force override" do
    # Stamp the marker Commands::Approve actually requires for a forward move.
    Hive::Markers.set(stage_dir(@project, "1-inbox").join(@slug, "idea.md").to_s, :complete)

    get "/tasks/#{@project}/#{@slug}"

    assert_select ".task-actions > form[action=?] button", "/tasks/#{@project}/#{@slug}/approve",
                  text: "Approve", count: 1
    assert_select ".advanced form[action=?]", "/tasks/#{@project}/#{@slug}/approve",
                  count: 0, message: "a passable gate needs no force override in Advanced"
  end

  test "approve with force moves the task to the next stage" do
    post "/tasks/#{@project}/#{@slug}/approve", params: { from: "1-inbox", force: "1" }

    assert_redirected_to "/"
    assert stage_dir(@project, "2-brainstorm").join(@slug).directory?,
           "approve must move the task folder to 2-brainstorm"
  end

  test "unforced approve without a completion marker renders the typed error page" do
    # Move the task to a gated stage first (1-inbox forward moves are free).
    post "/tasks/#{@project}/#{@slug}/approve", params: { from: "1-inbox", force: "1" }

    post "/tasks/#{@project}/#{@slug}/approve", params: { from: "2-brainstorm" }

    assert_response :unprocessable_entity
    assert_match "Action failed", response.body
    assert_match "forward approve requires", response.body,
                 "the real Approve refusal reason must reach the operator"
    assert stage_dir(@project, "2-brainstorm").join(@slug).directory?,
           "a refused approve must not move the task"
  end

  test "unknown project and traversal slugs are 404" do
    get "/tasks/nope/#{@slug}"
    assert_response :not_found

    # A traversal-shaped slug fails the route constraint outright.
    get "/tasks/#{@project}/..%2f..%2fetc"
    assert_response :not_found
  end

  test "log route rejects unknown registered state before reading a path" do
    get "/tasks/nope/#{@slug}/log"
    assert_response :not_found

    get "/tasks/#{@project}/ghost-task-260101-zzzz/log"
    assert_response :not_found
  end

  test "task-local show log diff media and mutation routes perform zero fleet scans" do
    feed = Object.new
    feed.define_singleton_method(:current_state) { nil }
    feed.define_singleton_method(:snapshot_state) { raise "task route triggered a fleet scan" }
    previous_feed = StatusBroadcaster.feed
    StatusBroadcaster.feed = feed
    folder = stage_dir(@project, "1-inbox").join(@slug)
    media = folder.join("media")
    media.mkpath
    File.binwrite(media.join("probe.png"), png_bytes)

    get "/tasks/#{@project}/#{@slug}"
    assert_response :success
    get "/tasks/#{@project}/#{@slug}/log"
    assert_response :success
    get "/tasks/#{@project}/#{@slug}/diff"
    assert_response :conflict
    get "/tasks/#{@project}/#{@slug}/media/probe.png"
    assert_response :success
    post "/tasks/#{@project}/#{@slug}/run",
         params: { action_name: "ready_to_brainstorm", stage: "1-inbox" }
    assert_redirected_to "/tasks/#{@project}/#{@slug}"
  ensure
    StatusBroadcaster.feed = previous_feed if previous_feed
  end

  test "intervene writes the answer into the task" do
    post "/tasks/#{@project}/#{@slug}/approve", params: { from: "1-inbox", force: "1" }
    folder = stage_dir(@project, "2-brainstorm").join(@slug)
    brainstorm = folder.join("brainstorm.md")
    brainstorm.write("### Q1. Which option?\n\n### A1.\n\n")

    post "/tasks/#{@project}/#{@slug}/intervene", params: { message: "Prefer option B" }

    assert_redirected_to "/tasks/#{@project}/#{@slug}"
    answer = Hive::Bot::BrainstormParser.parse(brainstorm).first.answer.to_s.strip
    assert_equal "Prefer option B", answer
  end

  test "intervene rejects a blank answer without changing the task" do
    post "/tasks/#{@project}/#{@slug}/approve", params: { from: "1-inbox", force: "1" }
    brainstorm = stage_dir(@project, "2-brainstorm").join(@slug, "brainstorm.md")
    brainstorm.write("### Q1. Which option?\n\n### A1.\n\n")
    before = brainstorm.read

    post "/tasks/#{@project}/#{@slug}/intervene", params: { message: "   " }

    assert_response :unprocessable_entity
    assert_match "intervene message is required", response.body
    assert_equal before, brainstorm.read
  end

  test "a degraded fleet cache cannot block exact server-side mutation revalidation" do
    snapshot = {
      "projects" => [
        { "name" => @project, "error" => "project_load_failed", "tasks" => [] }
      ]
    }
    replacement = proc do
      StatusBroadcaster::PageSnapshot.new(
        payload: snapshot, version: 1, availability: "degraded",
        last_success_at: "2026-07-25T12:00:00.000000Z",
        error: "Hive::ConfigError: project load failed"
      )
    end

    with_replaced_singleton_method(StatusBroadcaster, :current_page_snapshot, replacement) do
      post "/tasks/#{@project}/#{@slug}/run",
           params: { action_name: "ready_to_brainstorm", stage: "1-inbox" }
    end

    assert_redirected_to "/tasks/#{@project}/#{@slug}"
    queue = Dir.glob(File.join(ENV["HIVE_HOME"], "**", "dispatch_requests", "**", "*"))
               .select { |file| File.file?(file) }
    assert queue.any? { |file| File.read(file).include?(@slug) },
           "the exact task resolver must revalidate the current row instead of trusting a degraded cache"
  end

  test "run stage dispatches the current stage's verb to the daemon queue" do
    post "/tasks/#{@project}/#{@slug}/run",
         params: { action_name: "ready_to_brainstorm", stage: "1-inbox" }

    assert_redirected_to "/tasks/#{@project}/#{@slug}",
                         "a queued dispatch returns to the task page"
    queue = Dir.glob(File.join(ENV["HIVE_HOME"], "**", "dispatch_requests", "**", "*"))
               .select { |f| File.file?(f) }
    assert queue.any? { |f| File.read(f).include?(@slug) },
           "the dispatch request must land in the daemon queue"
  end

  test "run stage rejects a bogus action with a readable 422" do
    post "/tasks/#{@project}/#{@slug}/run",
         params: { action_name: "run", stage: "1-inbox" }

    assert_response :unprocessable_entity
    assert_match "unknown dispatch action", response.body
  end

  test "open brainstorm questions render as a per-question Q&A form" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    folder.join("brainstorm.md").write("### Q1. Scope?\n\n### A1.\n\n### Q2. Acceptance?\n\n### A2.\n\n")

    get "/tasks/#{@project}/#{@slug}"

    assert_response :success
    assert_select ".qa-item", 2, "each open question must get its own answer field"
    assert_select "textarea[name='answers[1]']", 1
    assert_select "textarea[name='answers[2]']", 1
    assert_match "Scope?", response.body
  end

  test "submitted answers land under the right question headers" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    folder.join("brainstorm.md").write("### Q1. Scope?\n\n### A1.\n\n### Q2. Acceptance?\n\n### A2.\n\n")

    post "/tasks/#{@project}/#{@slug}/answers",
         params: { answers: { "1" => "Header only", "2" => "Green tests" } }

    assert_redirected_to "/tasks/#{@project}/#{@slug}"
    content = folder.join("brainstorm.md").read
    assert_match(/### A1\.\nHeader only/, content, "answer 1 must land under its header")
    assert_match(/### A2\.\nGreen tests/, content, "answer 2 must land under its header")
  end

  test "answering an already-closed question is a readable 422" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    folder.join("brainstorm.md").write("### Q1. Scope?\n\n### A1.\nDone\n\n")

    post "/tasks/#{@project}/#{@slug}/answers", params: { answers: { "1" => "again" } }

    assert_response :unprocessable_entity
    assert_match "no longer open", response.body
  end

  test "diff link renders only when the worktree exists" do
    get "/tasks/#{@project}/#{@slug}"
    assert_select "a", { text: "Diff", count: 0 }, "pre-execute stages have no worktree → no Diff link"

    # Worktrees first exist at 4-execute; move the task there (the mv IS the
    # pipeline's approval primitive) and materialize the derived path.
    FileUtils.mv(stage_dir(@project, "1-inbox").join(@slug),
                 stage_dir(@project, "4-execute").join(@slug))
    project_payload = StatusBroadcaster.snapshot.fetch("projects", [])
                                        .find { |p| p["name"] == @project }
    row = project_payload.fetch("tasks", []).find { |t| t["slug"] == @slug }
    assert row["worktree_path"].present?, "an execute-stage task must derive a worktree path"
    FileUtils.mkdir_p(row["worktree_path"])

    get "/tasks/#{@project}/#{@slug}"
    assert_select "a", { text: "Diff", count: 1 }, "an existing worktree must expose the Diff link"
  ensure
    FileUtils.rm_rf(row["worktree_path"]) if row && row["worktree_path"].present?
  end

  test "run stage appears only when the project daemon is disabled, labeled with the verb" do
    get "/tasks/#{@project}/#{@slug}"
    assert_select "form[action$='/run']", 0, "daemon-enabled projects must not offer manual runs"

    config_path = stage_dir(@project, "1-inbox").join("..", "..", "config.yml").to_s
    data = YAML.safe_load_file(config_path) || {}
    data["daemon"] = (data["daemon"] || {}).merge("enabled" => false)
    File.write(config_path, data.to_yaml)

    get "/tasks/#{@project}/#{@slug}"
    assert_select "form[action$='/run']", 1
    assert_select "form[action$='/run'] button", text: "Run brainstorm",
                  count: 1
  ensure
    if config_path && File.exist?(config_path)
      data = YAML.safe_load_file(config_path) || {}
      data["daemon"] = (data["daemon"] || {}).merge("enabled" => true)
      File.write(config_path, data.to_yaml)
    end
  end

  test "daemon-enabled task gives a recovery command when auto-advance is down" do
    get "/tasks/#{@project}/#{@slug}"

    assert_response :success
    assert_select ".daemon-blocker", text: /Auto-advance is paused/
    assert_select ".daemon-blocker code", text: "hive daemon start --detach"
    assert_select "form[action$='/run']", 0,
                  "web must not offer a queue button that a stopped daemon cannot consume"
  end

  test "running daemon does not show an auto-advance blocker" do
    report = Object.new
    report.define_singleton_method(:running_state) { { running: true } }
    original_new = Hive::Daemon::StatusReport.method(:new)
    Hive::Daemon::StatusReport.define_singleton_method(:new) { report }

    get "/tasks/#{@project}/#{@slug}"

    assert_response :success
    assert_select ".daemon-blocker", 0
  ensure
    Hive::Daemon::StatusReport.define_singleton_method(:new, original_new) if original_new
  end

  test "terminal stages from non-coding workflows do not show an auto-advance blocker" do
    with_registered_workflow(content_workflow) do
      project = create_hive_project!("completed-content-app")
      slug = "completed-content-260719-aaaa"
      folder = stage_dir(project, "4-done").join(slug)
      folder.mkpath
      folder.join("done.md").write("# Done\n")
      Hive::TaskMeta.write(folder.to_s, id: 1, slug: slug, display_name: nil, workflow: "content_fixture")

      get "/tasks/#{project}/#{slug}"

      assert_response :success
      assert_select ".daemon-blocker", 0
    end
  end

  test "all-answered brainstorm shows the waiting banner on a push-refreshed page" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    folder.join("brainstorm.md").write("### Q1. Scope?\n\n### A1.\nDone\n\n<!-- WAITING -->\n")

    get "/tasks/#{@project}/#{@slug}"
    assert_select "hive-status-stream-source[channel='StatusChannel'][data-turbo-permanent]", { minimum: 1 },
                  "the task page must subscribe to the status channel for push refreshes"
    assert_select "#status-stream-owner[data-controller~='status-refresh'][data-status-version]", 1,
                  "task pages must version the render used by confirmed Cable catch-up"
    assert_select "#status-stream-owner .advanced form", { minimum: 1 },
                  "the refresh owner must wrap task mutations so a pushed refresh cannot beat their redirect"
    assert_select "meta[name='turbo-refresh-method'][content='morph']", 1,
                  "refreshes must morph so permanent forms survive"
    assert_select ".state-banner", text: /waiting for the daemon|agent is working/i,
                  count: 1
    assert_select ".qa-item", 0, "no open questions → no answer form"
  end

  test "the Q&A form is morph-managed by the answers controller, never permanent" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    folder.join("brainstorm.md").write("### Q1. Scope?\n\n### A1.\n\n<!-- WAITING -->\n")

    get "/tasks/#{@project}/#{@slug}"
    assert_select "section#task-state[data-controller='answers']", 1,
                  "typed input survives morphs via snapshot/restore, not permanence"
    assert_select "form[data-turbo-permanent]", 0,
                  "permanent forms cannot be REMOVED by a morph — a new round would leave "                   "the old form lingering (pinned by the round-transition system test)"
    assert_select "form[id^='qa-form-']", 1
  end

  test "an oversized diff renders truncated with a notice, not a memory bomb" do
    FileUtils.mv(stage_dir(@project, "1-inbox").join(@slug),
                 stage_dir(@project, "4-execute").join(@slug))
    project_root = File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "repos", @project)
    task_folder = stage_dir(@project, "4-execute").join(@slug)
    File.write(File.join(project_root, "big.txt"), "x\n")
    system("git", "-C", project_root, "add", "big.txt", exception: true)
    system("git", "-C", project_root, "commit", "-qm", "seed tracked diff fixture", exception: true)
    base, base_status = Open3.capture2("git", "-C", project_root, "rev-parse", "HEAD")
    assert base_status.success?
    base = base.strip
    owned = Hive::Worktree.new(project_root, @slug)
    owned.create!(@slug, default_branch: "master")
    owned.write_pointer!(task_folder, @slug, execute_base_head: base)
    worktree = owned.path
    big = File.join(worktree, "big.txt")
    # >512KB of uncommitted change must come back capped, flagged, and fast.
    File.write(big, "y#{SecureRandom.hex(16)}
" * 25_000)

    get "/tasks/#{@project}/#{@slug}/diff"

    assert_response :success
    assert_select "nav a.nav-link-active", text: "Status"
    assert_match "Partial diff", response.body
    assert response.body.bytesize < 700 * 1024,
           "the rendered diff must be capped (got #{response.body.bytesize} bytes)"
  ensure
    FileUtils.rm_rf(worktree) if worktree.present?
  end

  test "diff for a valid task without a worktree is a typed conflict" do
    get "/tasks/#{@project}/#{@slug}/diff"
    assert_response :conflict
    assert_match "Diff unavailable", response.body
    assert_match "Worktree unavailable", response.body
  end

  private

  def media_fixture!(folder)
    media_dir = folder.join("media")
    media_dir.mkpath
    File.binwrite(media_dir.join("01-home.png"), png_bytes)
    File.binwrite(media_dir.join("demo.gif"), gif_bytes)
    write_media_manifest(folder, {
      "schema" => 1,
      "status" => "captured",
      "surface" => "ui",
      "items" => [
        {
          "file" => "01-home.png",
          "type" => "still",
          "caption" => "Home page after load",
          "screenote_url" => "https://screenote.test/shot"
        },
        {
          "file" => "demo.gif",
          "type" => "gif",
          "caption" => "Dark mode toggle",
          "screenote_url" => nil,
          "screenote_skipped_reason" => "Screenote is not connected; run `hive connect screenote`."
        }
      ]
    })
  end

  def write_media_manifest(folder, manifest)
    media_dir = folder.join("media")
    media_dir.mkpath
    media_dir.join("manifest.json").write("#{JSON.pretty_generate(manifest)}\n")
  end

  def png_bytes
    [ 137, 80, 78, 71, 13, 10, 26, 10 ].pack("C*") + "fake-png-body"
  end

  def jpg_bytes
    [ 0xFF, 0xD8, 0xFF, 0xE0 ].pack("C*") + "fake-jpg-body"
  end

  def gif_bytes
    "GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;".b
  end
end
