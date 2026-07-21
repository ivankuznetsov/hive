require "test_helper"
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
    get "/"
    assert_response :success
    assert_match @slug, response.body
    assert_select "#projects", 1
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

  test "a red task offers Retry which queues the clear-then-rerun pair" do
    FileUtils.mv(stage_dir(@project, "1-inbox").join(@slug),
                 stage_dir(@project, "6-review").join(@slug))
    folder = stage_dir(@project, "6-review").join(@slug)
    folder.join("task.md").write("# t\n\n<!-- REVIEW_ERROR phase=triage reason=merge_conflict pass=1 -->\n")

    get "/tasks/#{@project}/#{@slug}"
    assert_response :success
    assert_select ".state-banner-error", { count: 1, text: /REVIEW_ERROR|triage/ },
                  "the red state must say WHY, not just need recovery"
    assert_select ".task-actions form[action=?] button", "/tasks/#{@project}/#{@slug}/recover",
                  text: "Retry stage", count: 1

    post "/tasks/#{@project}/#{@slug}/recover"
    assert_redirected_to "/tasks/#{@project}/#{@slug}"
    queue = Dir.glob(File.join(ENV["HIVE_HOME"], "**", "dispatch_request*", "**", "*"))
               .select { |f| File.file?(f) }
    assert queue.any? { |f| File.read(f).include?("markers") },
           "recover must queue the guarded marker clear"
    assert queue.any? { |f| content = File.read(f); content.include?("review") && content.include?(@slug) },
           "recover must queue the stage rerun behind the clear"
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

  test "intervene writes the answer into the task" do
    post "/tasks/#{@project}/#{@slug}/approve", params: { from: "1-inbox", force: "1" }

    post "/tasks/#{@project}/#{@slug}/intervene", params: { message: "Prefer option B" }

    # Without an open brainstorm question the writer reports a typed error —
    # still a readable page, never a blank 500.
    assert_includes [ 302, 422 ], response.status
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
    assert_select "turbo-cable-stream-source", { minimum: 1 },
                  "the task page must subscribe to the status channel for push refreshes"
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
    project_payload = StatusBroadcaster.snapshot.fetch("projects", [])
                                        .find { |p| p["name"] == @project }
    row = project_payload.fetch("tasks", []).find { |t| t["slug"] == @slug }
    worktree = row["worktree_path"]
    FileUtils.mkdir_p(worktree)
    system("git", "init", "-q", worktree, exception: true)
    big = File.join(worktree, "big.txt")
    File.write(big, "x
")
    system("git", "-C", worktree, "add", ".", exception: true)
    system("git", "-C", worktree, "-c", "user.email=t@e.c", "-c", "user.name=T",
           "commit", "-qm", "seed", exception: true)
    # >512KB of uncommitted change must come back capped, flagged, and fast.
    File.write(big, "y#{SecureRandom.hex(16)}
" * 25_000)

    get "/tasks/#{@project}/#{@slug}/diff"

    assert_response :success
    assert_select "nav a.nav-link-active", text: "Status"
    assert_match "Diff truncated to the first 512", response.body
    assert response.body.bytesize < 700 * 1024,
           "the rendered diff must be capped (got #{response.body.bytesize} bytes)"
  ensure
    FileUtils.rm_rf(worktree) if worktree.present?
  end

  test "diff for a task without a worktree is 404 not a crash" do
    get "/tasks/#{@project}/#{@slug}/diff"
    assert_response :not_found
    assert_match "no worktree", response.body
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
