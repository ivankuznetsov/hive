require "test_helper"
require "open3"
require "tmpdir"
require_relative "../../../test/support/workflow_helpers"
require_relative "../support/outcome_evidence_helper"

class TasksTest < ActionDispatch::IntegrationTest
  include HiveWorkflowTestHelper
  include OutcomeEvidenceHelper

  setup do
    @project = create_hive_project!
    @slug = create_task!(@project, "actions probe")
    refresh_status_feed!
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
    folder = stage_dir(@project, "9-done").join(@slug)
    FileUtils.mv(stage_dir(@project, "1-inbox").join(@slug), folder)
    Hive::TaskMeta.rewrite(
      folder.to_s,
      completed_at: Time.now.utc - (10 * 86_400)
    )
    media_fixture!(folder)
    ordinary = {
      "projects" => [
        { "name" => @project, "tasks" => [], "hidden_archived_task_count" => 1 }
      ]
    }
    ordinary_snapshot = lambda do
      StatusBroadcaster::PageSnapshot.new(payload: ordinary, version: "ordinary-version")
    end
    fleet_archive_snapshot = -> { raise "archive task route attempted a fleet scan" }

    with_replaced_singleton_method(StatusBroadcaster, :current_page_snapshot, ordinary_snapshot) do
      with_replaced_singleton_method(
        StatusBroadcaster, :archive_snapshot, fleet_archive_snapshot
      ) do
        get task_path(@project, @slug)
        assert_response :not_found

        get task_path(@project, @slug, source: "archive")
        assert_response :success
        assert_select "#status-stream-owner[data-status-version='ordinary-version']"
        assert_select ".task-header", text: /#{Regexp.escape(@slug.sub(/-\d{6}-\h{4}\z/, "").tr("-", " "))}/i
        assert_select "img[src*='source=archive']", minimum: 1
        assert_select "form[action*='source=archive']", minimum: 1
        assert_select "form[action*='source=archive'] button:not([disabled])", count: 0,
                      message: "archived task mutation controls must fail closed"
        assert_select(
          "turbo-frame[id^='task-log-'][data-controller='poll']",
          { count: 0 },
          "an archived task log is immutable and must not trigger status work every 3 seconds"
        )

        get task_log_path(@project, @slug)
        assert_response :not_found
        get task_log_path(@project, @slug, source: "archive")
        assert_response :success

        get task_media_path(@project, @slug, "01-home.png")
        assert_response :not_found
        get task_media_path(@project, @slug, "01-home.png", source: "archive")
        assert_response :success

        get task_diff_path(@project, @slug, source: "archive")
        assert_response :conflict
        assert_match(/worktree unavailable/i, response.body)
      end
    end
  end

  test "every archived task mutation endpoint is read-only" do
    folder = stage_dir(@project, "9-done").join(@slug)
    FileUtils.mv(stage_dir(@project, "1-inbox").join(@slug), folder)
    Hive::TaskMeta.rewrite(folder.to_s, completed_at: Time.now.utc - (10 * 86_400))

    mutation_requests = {
      "approval" => [ task_approve_path(@project, @slug, source: "archive"),
                      { from: "9-done", force: "1" } ],
      "rejection" => [ task_reject_path(@project, @slug, source: "archive"),
                       { from: "9-done" } ],
      "drop" => [ task_drop_path(@project, @slug, source: "archive"),
                  { from: "9-done" } ],
      "run" => [ task_run_path(@project, @slug, source: "archive"),
                 { action_name: "run", stage: "9-done" } ],
      "recovery" => [ task_recover_path(@project, @slug, source: "archive"), {} ],
      "closure" => [ task_closure_path(@project, @slug, source: "archive"),
                     { reason: "already_delivered" } ],
      "intervention" => [ task_intervene_path(@project, @slug, source: "archive"),
                          { message: "No mutation", binding: "slot" } ],
      "answers" => [ task_answers_path(@project, @slug, source: "archive"),
                     { answers: { "slot" => "No mutation" } } ],
      "publication" => [ task_publication_path(@project, @slug, source: "archive"), {} ]
    }

    mutation_requests.each do |name, (path, params)|
      post path, params: params
      assert_response :unprocessable_entity, "#{name} must reject archived tasks"
      assert_match(/archived tasks are read-only/i, response.body, name)
      assert folder.directory?, "#{name} must leave the archived task intact"
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

  test "task detail renders one plan review projection with exact decision forms" do
    move_task_to_plan!
    details = plan_review_details_fixture

    with_replaced_instance_method(Task, :plan_review_details, -> { details }) do
      get "/tasks/#{@project}/#{@slug}"
    end

    assert_response :success
    assert_select "section.plan-review[data-review-id=?]", "pr-#{'a' * 64}", count: 1
    assert_select ".plan-review", text: /mandatory.*awaiting decision/m
    assert_select ".plan-review", text: /2 complete.*1 failed/m
    assert_select ".plan-review", text: /grok-build.*grok-4.6/m
    assert_select ".plan-review-findings > li", 2
    assert_select "form[action=?] input[name=expected_artifact_digest][value=?]",
                  "/tasks/#{@project}/#{@slug}/plan-review", "e" * 64, minimum: 4
    assert_select "form[action=?] input[name=review_id][value=?]",
                  "/tasks/#{@project}/#{@slug}/plan-review", "pr-#{'a' * 64}", minimum: 4
    assert_select "input[name=review_action][value=approve_finding]", 1
    assert_select "input[name=review_action][value=answer_finding]", 1
    assert_select "input[name=review_action][value=waive_coverage]", 1
    assert_select "input[name=review_action][value=downgrade_level]", 1
    assert_select ".plan-review-artifact", text: /current critique/
    assert_select ".advanced form[action=?] button",
                  "/tasks/#{@project}/#{@slug}/approve", text: "Force approve", count: 0
  end

  test "verification blockers do not expose futile finding decisions" do
    move_task_to_plan!
    details = plan_review_details_fixture
    details.fetch("summary")["state"] = "blocked"
    details.fetch("summary")["required_action"] = "start a new linked plan"

    with_replaced_instance_method(Task, :plan_review_details, -> { details }) do
      get "/tasks/#{@project}/#{@slug}"
    end

    assert_response :success
    assert_select "input[name=review_action][value=approve_finding]", 0
    assert_select "input[name=review_action][value=answer_finding]", 0
    assert_select ".plan-review-required-action", text: /start a new linked plan/
  end

  test "plan review action delegates the exact observation to the shared task mutation" do
    captured = nil
    projection = Struct.new(:record).new(Struct.new(:state).new("revising"))
    replacement = proc do |**arguments|
      captured = arguments
      { applied: true, decision: Object.new, projection: projection }
    end

    with_replaced_instance_method(Task, :plan_review_action!, replacement) do
      post "/tasks/#{@project}/#{@slug}/plan-review", params: {
        review_action: "answer_finding", review_id: "pr-#{'a' * 64}",
        task_generation: "generation-1", policy_fingerprint: "b" * 64,
        expected_artifact_digest: "e" * 64, target_fingerprint: "prf-#{'d' * 64}",
        answer: "Use the reversible path."
      }
    end

    assert_redirected_to "/tasks/#{@project}/#{@slug}"
    assert_equal "answer_finding", captured.fetch(:action)
    assert_equal "prf-#{'d' * 64}", captured.fetch(:target_fingerprint)
    assert_equal "Use the reversible path.", captured.fetch(:answer)
    assert_equal "alice", captured.fetch(:operator)
    assert captured.fetch(:authorized)
  end

  test "stale plan review submission refreshes without applying an action" do
    calls = 0
    replacement = proc do |**|
      calls += 1
      raise Hive::PlanReview::StaleDecision, "projection changed"
    end

    with_replaced_instance_method(Task, :plan_review_action!, replacement) do
      post "/tasks/#{@project}/#{@slug}/plan-review", params: {
        review_action: "approve_finding", review_id: "pr-#{'a' * 64}",
        task_generation: "generation-1", policy_fingerprint: "b" * 64,
        expected_artifact_digest: "e" * 64, target_fingerprint: "prf-#{'d' * 64}"
      }
    end

    assert_equal 1, calls
    assert_redirected_to "/tasks/#{@project}/#{@slug}"
    assert_equal "Plan review changed. Refreshed the current review; no action was applied.",
                 flash[:alert]
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
    assert_select "section.demo h2", text: /Demo/, count: 1
    assert_select ".legacy-label", text: "Legacy diagnostic", count: 1
    assert_select "img[src=?][alt=?]", "/tasks/#{@project}/#{@slug}/media/01-home.png", "Home page after load", count: 1
    assert_select "img[src=?][alt=?]", "/tasks/#{@project}/#{@slug}/media/demo.gif", "Dark mode toggle", count: 1
    assert_select "figcaption", text: /Home page after load/
    assert_select "a[href='https://screenote.test/shot']", text: "View / annotate on screenote", count: 1
  end

  test "task page leads with accepted claim evidence and serves admitted representations" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    result = write_accepted_outcome_evidence(
      folder, slug: @slug, project: @project, project_root: folder.join("..", "..", "..", "..").cleanpath
    )
    refresh_status_feed!

    get "/tasks/#{@project}/#{@slug}"

    assert_response :success
    assert_select "section.outcome-evidence h2", text: "Outcome evidence", count: 1
    assert_select ".evidence-status--accepted", text: "accepted", count: 1
    assert_select ".evidence-claim h3", text: /checkout confirmation/, count: 1
    assert_select ".evidence-verdict--accepted", text: /directly explains/, count: 1
    assert_select "details.evidence-audit summary", text: "Review history and provenance", count: 1
    assert_operator response.body.index("Outcome evidence"), :<, response.body.index("Artifacts")

    representation = result.fetch(:evidence).fetch("representations").last
    get task_evidence_path(@project, @slug, "attempt-01-web", representation.fetch("sha256"))
    assert_response :success
    assert_equal "text/plain", response.media_type
    assert_equal representation.fetch("bytes").to_s, response.headers.fetch("Content-Length")
    assert_includes response.body, "Checkout outcome"

    rejected_digest = representation.fetch("sha256") == "0" * 64 ? "1" * 64 : "0" * 64
    get task_evidence_path(@project, @slug, "attempt-01-web", rejected_digest)
    assert_response :not_found
    assert_empty response.body
  end

  test "task page explains blocked evidence and prints its exact recovery command" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    result = write_blocked_outcome_evidence(
      folder, slug: @slug, project: @project,
      project_root: folder.join("..", "..", "..", "..").cleanpath
    )
    refresh_status_feed!

    get "/tasks/#{@project}/#{@slug}"

    assert_response :success
    assert_select ".evidence-status--blocked", text: "blocked", count: 1
    assert_select ".evidence-verdict--revise", text: /final confirmation/, count: 1
    assert_select ".evidence-blocker h3", text: "Operator recovery required", count: 1
    command = css_select(".evidence-blocker code").first.text
    assert_includes command, result.dig(:pointer, "generation")
    assert_includes command, result.dig(:pointer, "recovery_digest")
    assert_includes command, "hive evidence recover #{@project}:#{@slug}"
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
    snapshot = refresh_status_feed!
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
    get "/tasks/#{@project}/#{@slug}.json"
    assert_response :success
    get "/tasks/#{@project}/#{@slug}/timeline.json"
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
    binding = Hive::Commands::Answer.inventory(@slug, project: @project).dig("slots", 0, "binding")

    post "/tasks/#{@project}/#{@slug}/intervene",
         params: { message: "Prefer option B", binding: binding }

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
    post "/tasks/#{@project}/#{@slug}/approve", params: { from: "1-inbox", force: "1" }
    folder = stage_dir(@project, "2-brainstorm").join(@slug)
    folder.join("brainstorm.md").write("### Q1. Scope?\n\n### A1.\n\n### Q2. Acceptance?\n\n### A2.\n\n")

    get task_path(@project, @slug, format: :json)
    workspace = response.parsed_body
    operator_questions = workspace.dig("operator", "questions")
    assert_equal [ "Scope?", "Acceptance?" ], operator_questions.map { |row| row.fetch("text") }
    assert_equal "partial", workspace.dig("status", "state")
    assert_equal "answer", workspace.dig("decision", "posture")
    assert workspace.dig("decision", "action", "enabled")

    get "/tasks/#{@project}/#{@slug}"

    assert_response :success
    assert_select ".qa-item", 2, "each open question must get its own answer field"
    operator_questions.each do |question|
      assert_select ".qa-question", text: /#{Regexp.escape(question.fetch("text"))}/
      assert_select "textarea[data-question-number=?][name=?]:not([disabled])",
                    question.fetch("n").to_s, "answers[#{question.fetch('binding')}]", count: 1
    end
    assert_select "form[id^='qa-form-'] input[type='submit']:not([disabled])", 1
  end

  test "submitted answers land under the right question headers" do
    post "/tasks/#{@project}/#{@slug}/approve", params: { from: "1-inbox", force: "1" }
    folder = stage_dir(@project, "2-brainstorm").join(@slug)
    folder.join("brainstorm.md").write("### Q1. Scope?\n\n### A1.\n\n### Q2. Acceptance?\n\n### A2.\n\n")
    slots = Hive::Commands::Answer.inventory(@slug, project: @project).fetch("slots")
    answers = slots.to_h do |slot|
      [ slot.fetch("binding"), slot.fetch("question_number") == 1 ? "Header only" : "Green tests" ]
    end

    post "/tasks/#{@project}/#{@slug}/answers",
         params: { answers: answers }

    assert_redirected_to "/tasks/#{@project}/#{@slug}"
    content = folder.join("brainstorm.md").read
    answer_1_header = Regexp.escape(Hive::BrainstormParser.encoded_answer_header(1))
    answer_2_header = Regexp.escape(Hive::BrainstormParser.encoded_answer_header(2))
    assert_match(/#{answer_1_header}\nHeader only/, content, "answer 1 must land under its header")
    assert_match(/#{answer_2_header}\nGreen tests/, content, "answer 2 must land under its header")
  end

  test "answering an already-closed question is a readable 422" do
    post "/tasks/#{@project}/#{@slug}/approve", params: { from: "1-inbox", force: "1" }
    folder = stage_dir(@project, "2-brainstorm").join(@slug)
    folder.join("brainstorm.md").write("### Q1. Scope?\n\n### A1.\nDone\n\n")
    binding = Hive::Commands::Answer.inventory(@slug, project: @project).dig("slots", 0, "binding")

    post "/tasks/#{@project}/#{@slug}/answers", params: { answers: { binding => "again" } }

    assert_response :unprocessable_entity
    assert_match "reload the page", response.body
  end

  test "diff link renders only when the worktree exists" do
    get "/tasks/#{@project}/#{@slug}"
    assert_select "a", { text: "Diff", count: 0 }, "pre-execute stages have no worktree → no Diff link"

    # Worktrees first exist at 4-execute; move the task there (the mv IS the
    # pipeline's approval primitive) and materialize the derived path.
    FileUtils.mv(stage_dir(@project, "1-inbox").join(@slug),
                 stage_dir(@project, "4-execute").join(@slug))
    project_payload = refresh_status_feed!.fetch("projects", [])
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
    post "/tasks/#{@project}/#{@slug}/approve", params: { from: "1-inbox", force: "1" }
    folder = stage_dir(@project, "2-brainstorm").join(@slug)
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
    post "/tasks/#{@project}/#{@slug}/approve", params: { from: "1-inbox", force: "1" }
    folder = stage_dir(@project, "2-brainstorm").join(@slug)
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

  test "publication GET is authenticated cache-only HTML and JSON" do
    api_factory = ->(*) { flunk "ordinary publication GET must not construct a GitHub client" }

    with_replaced_singleton_method(GithubApi, :new, api_factory) do
      get task_publication_path(@project, @slug)
      assert_response :success
      assert_select "turbo-frame[id^='task-publication-']", 1
      assert_select ".publication-panel", text: /Worktree unavailable/i

      get task_publication_path(@project, @slug, format: :json)
      assert_response :success
      assert_equal "application/json", response.media_type
      assert_equal "worktree_unavailable", response.parsed_body.fetch("publication_state")
    end

    post "/logout"
    get task_publication_path(@project, @slug)
    assert_redirected_to "/login"
  end

  test "existing task route serves authenticated schema-valid workspace JSON" do
    get "/tasks/#{@project}/#{@slug}.json"

    assert_response :success
    assert_equal "application/json", response.media_type
    document = JSON.parse(response.body)
    schemer = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-task-workspace")))
    )
    assert_empty schemer.validate(document).to_a
    assert_equal @project, document.dig("task", "project")
    assert_equal @slug, document.dig("task", "slug")
    assert_equal "hive-task-workspace", document.fetch("schema")
    assert_equal Hive::TaskWorkspace::PANEL_NAMES.sort,
                 document.fetch("panels").keys.sort
    refute_includes document.to_s, stage_dir(@project, "1-inbox").to_s
    refute document.to_s.include?("suggested_command")
    refute document.to_s.include?("observation_token")

    post "/logout"
    get "/tasks/#{@project}/#{@slug}.json"
    assert_redirected_to "/login"
  end

  test "task HTML composes the same normalized workspace with correctly owned evidence frames" do
    get task_path(@project, @slug, format: :json)
    workspace = response.parsed_body

    get task_path(@project, @slug)

    assert_response :success
    assert_select "#status-stream-owner[data-controller~='task-workspace']", 1
    assert_select "#workspace-summary-heading",
                  text: workspace.dig("decision", "posture").humanize
    %w[attempts provenance timeline dependencies artifacts publication].each do |panel|
      assert_select "#workspace-#{panel}", 1, "#{panel} must be represented exactly once"
    end
    assert_select "turbo-frame[id^='task-diff-'][data-turbo-permanent]", 1
    assert_select "turbo-frame[id^='task-publication-'][refresh='morph']", 1
    assert_select "turbo-frame[id^='task-publication-'][data-turbo-permanent]", count: 0
    assert_select "turbo-frame[id^='task-publication-'][src]", count: 0
    assert_select "turbo-frame[id^='task-timeline-inspection-'][data-turbo-permanent]", 1
    assert_select ".workspace-table-scroll[role='region'][tabindex='0']", minimum: 1
    assert_select "#task-workspace-announcement[role='status'][aria-live='polite']", 1
    refute_includes response.body, stage_dir(@project, "1-inbox").to_s
  end

  test "a failed publication source degrades only that panel" do
    original = Task.instance_method(:publication)
    Task.define_method(:publication) { |cache: nil| raise Errno::EIO, "publication unavailable" }

    get task_path(@project, @slug)

    assert_response :success
    assert_select "#workspace-publication.workspace-state-unavailable", text: /Unavailable/i
    assert_select "#workspace-artifacts details[data-artifact-name='idea.md']", 1
    assert_select ".advanced form", minimum: 1
  ensure
    Task.define_method(:publication, original) if original
  end

  test "timeline endpoint pages material events and expands bounded noise groups" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    records = 205.times.map do |index|
      {
        "event_id" => "material-#{index}", "event_type" => "stage_enter",
        "ts" => (Time.utc(2026, 8, 12, 12) + index).iso8601,
        "stage" => "1-inbox", "source" => "controller"
      }
    end
    records.concat(25.times.map do |index|
      {
        "event_id" => "noise-#{index}", "event_type" => "heartbeat",
        "ts" => (Time.utc(2026, 8, 12, 13) + index).iso8601,
        "stage" => "1-inbox", "source" => "runtime_receipt"
      }
    end)
    folder.join("events.jsonl").write(
      records.map { |record| JSON.generate(record) }.join("\n") + "\n"
    )

    get task_path(@project, @slug)
    assert_response :success
    assert_select "#workspace-timeline > ol.timeline-list", 1,
                  "the current timeline must remain outside drill-down navigation"
    assert_select "#workspace-timeline a[data-turbo-frame^='task-timeline-inspection-']",
                  minimum: 1

    get "/tasks/#{@project}/#{@slug}/timeline.json"
    assert_response :success
    first = JSON.parse(response.body)
    assert_equal 200, first.fetch("records").length
    assert first.fetch("truncated")
    refute_nil first.fetch("older_cursor")
    assert_equal 25, first.dig("noise_groups", 0, "count")

    get "/tasks/#{@project}/#{@slug}/timeline.json",
        params: { cursor: first.fetch("older_cursor") }
    assert_response :success
    older = JSON.parse(response.body)
    assert_equal 5, older.fetch("records").length
    assert_nil older["older_cursor"]

    get "/tasks/#{@project}/#{@slug}/timeline.json",
        params: { raw_cursor: first.dig("noise_groups", 0, "raw_cursor") }
    assert_response :success
    raw = JSON.parse(response.body)
    assert_equal 20, raw.fetch("records").length
    assert raw.fetch("truncated")

    get task_timeline_path(@project, @slug), params: { cursor: first.fetch("older_cursor") }
    assert_response :success
    assert_select "turbo-frame[id^='task-timeline-inspection-']", 1
    assert_select ".timeline-inspection", 1
    assert_select "a[href='#workspace-timeline'][data-turbo-frame='_top']",
                  text: "Return to current timeline"

    get "/tasks/#{@project}/#{@slug}/timeline.json",
        params: { cursor: "#{first.fetch('older_cursor')}x" }
    assert_response :unprocessable_entity
  end

  test "publication refresh performs at most one fixed remote read" do
    sign_in!(token: "github-session-token")
    panel = publication_fixture
    original_publication = Task.instance_method(:publication)
    Task.define_method(:publication) { |cache: nil| panel }
    cache = Object.new
    refreshes = []
    cache.define_singleton_method(:refresh) do |identity, &block|
      refreshes << [ identity, block.call ]
    end
    api = Object.new
    remote_calls = []
    api.define_singleton_method(:pull_request) do |**kwargs|
      remote_calls << kwargs
      panel.dig("remote", "observation")
    end

    with_replaced_singleton_method(
      Hive::TaskWorkspace::PublicationCache, :new, ->(**) { cache }
    ) do
      with_replaced_singleton_method(GithubApi, :new, ->(*) { api }) do
        post task_publication_path(@project, @slug)
      end
    end

    assert_response :success
    assert_equal 1, refreshes.length
    assert_equal 1, remote_calls.length
    assert_equal "github.com/acme/demo", remote_calls.first.fetch(:repository)
    assert_select "turbo-frame[id^='task-publication-']", 1
    assert_select "form[data-turbo-frame^='task-publication-']", 1
  ensure
    Task.define_method(:publication, original_publication) if original_publication
  end

  test "publication refresh is CSRF protected and unavailable for archives" do
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    post task_publication_path(@project, @slug)
    assert_response :unprocessable_entity
    ActionController::Base.allow_forgery_protection = previous

    folder = stage_dir(@project, "9-done").join(@slug)
    FileUtils.mv(stage_dir(@project, "1-inbox").join(@slug), folder)
    Hive::TaskMeta.rewrite(folder.to_s, completed_at: Time.now.utc)
    post task_publication_path(@project, @slug, source: "archive")
    assert_response :unprocessable_entity
    assert_match(/read-only/, response.body)
  ensure
    ActionController::Base.allow_forgery_protection = previous if previous != nil
  end

  private

  def move_task_to_plan!
    source = stage_dir(@project, "1-inbox").join(@slug)
    destination = stage_dir(@project, "3-plan").join(@slug)
    destination.dirname.mkpath
    FileUtils.mv(source, destination)
    destination.join("plan.md").write("# Plan\n\n## Tests\n\nRun focused tests.\n\n<!-- WAITING -->\n")
  end

  def plan_review_details_fixture
    summary = {
      "applicable" => true, "review_id" => "pr-#{'a' * 64}", "version" => 4,
      "observation_digest" => "e" * 64, "task_generation" => "generation-1",
      "plan_digest" => "f" * 64, "policy_fingerprint" => "b" * 64,
      "computed_level" => "mandatory", "effective_level" => "mandatory",
      "state" => "awaiting_decision", "outcome" => nil, "degraded" => false,
      "degradation_reason" => nil, "attempt_count" => 2,
      "current_attempt_id" => "pra-#{'9' * 64}",
      "coverage_counts" => {
        "requested" => 0, "completed" => 2, "failed" => 1,
        "unsupported" => 0, "waived" => 0
      },
      "finding_counts" => {
        "open" => 2, "approved" => 0, "answered" => 0, "incorporated" => 0,
        "verified" => 0, "resolved" => 0, "waived" => 0, "total" => 2,
        "open_gated" => 1, "open_manual" => 1, "fyi" => 0
      },
      "blockers" => [ { "owner" => "operator", "reason" => "manual finding" } ],
      "blocker_owner" => "operator", "blocker_reason" => "manual finding",
      "required_action" => "answer manual plan finding", "retry_at" => nil,
      "routes" => [], "artifacts" => {},
      "freshness" => { "status" => "current", "reason" => nil },
      "execution_allowed" => false
    }
    findings = [
      plan_review_finding("gated_auto", "Approve the compatibility boundary", 1, "1"),
      plan_review_finding("manual", "Choose the rollback boundary", 2, "2")
    ]
    coverage = [
      plan_review_coverage("whole_document", "completed", "3"),
      plan_review_coverage("adversarial", "completed", "4"),
      plan_review_coverage("security", "failed", "5", required: false)
    ]
    routes = [
      {
        "role" => "adversarial",
        "requested" => {
          "provider" => "grok-build", "model" => "grok-4.6", "family" => "grok",
          "effort" => "high", "route" => "native"
        },
        "actual" => {
          "provider" => "grok-build", "model" => "grok-4.6", "family" => "grok",
          "effort" => "high", "route" => "native"
        },
        "outcome" => "success", "capability_result" => "present",
        "independence_verified" => true
      }
    ]
    {
      "summary" => summary.merge("routes" => routes), "coverage" => coverage,
      "findings" => findings, "routes" => routes,
      "artifacts" => [
        {
          "name" => "primary_result", "path" => "reviews/current/result.json",
          "sha256" => "6" * 64, "bytes" => 42, "format" => "json",
          "content" => "{\"summary\":\"current critique\"}\n"
        }
      ]
    }
  end

  def plan_review_finding(classification, title, order, digest_character)
    {
      "fingerprint" => "prf-#{digest_character * 64}", "source" => "whole_document",
      "classification" => classification, "risk" => "high", "title" => title,
      "description" => "Resolve this exact finding before execution.",
      "evidence" => {
        "path" => "plan.md", "start_line" => order, "end_line" => order,
        "anchor_digest" => digest_character * 64
      },
      "lifecycle" => "open", "display_order" => order
    }
  end

  def plan_review_coverage(name, status, digest_character, required: true)
    {
      "name" => name, "required" => required, "status" => status,
      "fingerprint" => "prc-#{digest_character * 64}",
      "reason" => status == "failed" ? "provider unavailable" : nil
    }
  end

  def with_replaced_instance_method(receiver, name, replacement)
    original = receiver.instance_method(name)
    visibility = if receiver.private_method_defined?(name)
      :private
    elsif receiver.protected_method_defined?(name)
      :protected
    else
      :public
    end
    receiver.define_method(name, replacement)
    receiver.send(visibility, name)
    yield
  ensure
    receiver.define_method(name, original)
    receiver.send(visibility, name)
  end

  def publication_fixture
    identity = {
      "repository" => "github.com/acme/demo", "number" => 42,
      "expected_head" => "a" * 40
    }
    observation = {
      "repository" => identity.fetch("repository"), "number" => 42,
      "url" => "https://github.com/acme/demo/pull/42", "state" => "OPEN",
      "is_draft" => false, "title" => "Ship", "body" => "Body",
      "base_branch" => "main", "head_oid" => "a" * 40,
      "head_matches" => true, "head_branch_present" => true,
      "checks" => [], "checks_truncated" => false
    }
    local = {
      "state" => "current", "repository" => identity.fetch("repository"),
      "branch" => @slug, "expected_branch" => @slug, "base_branch" => "main",
      "base_oid" => "b" * 40, "head_oid" => "a" * 40,
      "base_state" => "ancestor", "dirty" => false, "commits" => [],
      "commits_truncated" => false,
      "push" => { "state" => "pushed", "tracking_oid" => "a" * 40,
                  "ahead" => 0, "behind" => 0 }
    }
    pr = {
      "state" => "current", "reference" => "pr.md",
      "url" => observation.fetch("url"), "repository" => identity.fetch("repository"),
      "number" => 42, "declared_head_oid" => "a" * 40,
      "title" => "Ship", "body" => "Body", "truncated" => false, "conflicts" => []
    }
    remote = {
      "state" => "current", "cache_state" => "fresh", "refresh_state" => "idle",
      "observation" => observation, "observed_at" => "2026-08-12T12:00:00Z",
      "refreshed_at" => "2026-08-12T12:00:00Z", "retry_at" => nil,
      "diagnostics" => []
    }
    {
      "state" => "current", "records" => [], "local" => local,
      "pull_request" => pr, "remote" => remote,
      "publication_state" => "open",
      "refresh" => { "eligible" => true, "reason" => nil, "identity" => identity },
      "diagnostics" => [], "truncated" => false
    }
  end

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
