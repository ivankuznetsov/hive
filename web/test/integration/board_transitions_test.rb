require "test_helper"

class BoardTransitionsTest < ActionDispatch::IntegrationTest
  setup do
    @project = create_hive_project!("transition-app")
    @slug = create_task!(@project, "guarded board transition")
    TransitionMetrics.reset!
    sign_in!
  end

  test "server derives the queued verb and persists actor guard identity" do
    card = current_card

    post task_transition_path(@project, @slug), params: {
      destination: "2-brainstorm",
      expected_fingerprint: card.fetch("fingerprint"),
      verb: "drop"
    }, as: :json

    assert_response :accepted
    body = response.parsed_body
    assert_equal "queued", body.fetch("state")
    assert_equal "brainstorm", body.dig("transition", "verb")
    request = Hive::Daemon::DispatchRequestQueue.pending.find do |entry|
      entry.request_id == body.fetch("request_id")
    end
    refute_nil request
    assert_equal "web", request.requestor
    assert_equal "alice", request.actor
    assert_equal card.fetch("fingerprint"), request.expected_fingerprint
    assert_equal "2-brainstorm", request.transition_destination
  end

  test "the plain HTML Move-to form remains a complete non-JavaScript path" do
    card = current_card

    post task_transition_path(@project, @slug), params: {
      destination: "2-brainstorm", expected_fingerprint: card.fetch("fingerprint")
    }, headers: { "HTTP_REFERER" => board_url(project: @project) }

    assert_redirected_to board_url(project: @project)
    assert_match(/Move queued/, flash[:notice])
    request = Hive::Daemon::DispatchRequestQueue.pending.find { |entry| entry.slug == @slug }
    assert_equal "web", request.requestor
  end

  test "illegal destination returns a fresh card and increments only denial metrics" do
    card = current_card

    assert_no_difference -> { operator_event_count } do
      post task_transition_path(@project, @slug), params: {
        destination: "9-done", expected_fingerprint: card.fetch("fingerprint")
      }, as: :json
    end

    assert_response :conflict
    assert_equal "stale_task", response.parsed_body.fetch("error")
    assert_equal @slug, response.parsed_body.dig("card", "slug")
    assert_equal 1, TransitionMetrics.snapshot.fetch("Hive::StaleTask")
  end

  test "changed task fingerprint returns conflict without queueing" do
    card = current_card
    metadata = Hive::TaskMeta.read(card.fetch("folder"))
    Hive::TaskMeta.write(
      card.fetch("folder"), id: metadata[:id], slug: @slug,
      display_name: metadata[:display_name], depends_on: "missing-task-260719-dead",
      workflow: metadata[:workflow]
    )
    before = Hive::Daemon::DispatchRequestQueue.pending.size

    post task_transition_path(@project, @slug), params: {
      destination: "2-brainstorm", expected_fingerprint: card.fetch("fingerprint")
    }, as: :json

    assert_response :conflict
    assert_equal before, Hive::Daemon::DispatchRequestQueue.pending.size
    assert_equal "stale_task", response.parsed_body.fetch("error")
  end

  test "unsigned operator session cannot enqueue a transition" do
    card = current_card
    before = Hive::Daemon::DispatchRequestQueue.pending.size
    anonymous = open_session

    anonymous.post task_transition_path(@project, @slug), params: {
      destination: "2-brainstorm", expected_fingerprint: card.fetch("fingerprint")
    }, as: :json

    anonymous.assert_response :redirect
    assert_equal before, Hive::Daemon::DispatchRequestQueue.pending.size
  end

  private

  def current_card
    Hive::Commands::Status.new.task_card(project: @project, slug: @slug)
  end

  def operator_event_count
    Dir[File.join(stage_dir(@project, "*"), @slug, "events.jsonl")].sum do |path|
      File.readlines(path, chomp: true).count do |line|
        JSON.parse(line)["event_type"] == "operator_action"
      end
    end
  end
end
