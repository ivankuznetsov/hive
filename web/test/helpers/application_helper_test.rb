require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "digest helpers preserve task source and parse persisted timestamps" do
    destination = { project: "demo", slug: "waiting-task", source: "archive" }

    assert_equal "/tasks/demo/waiting-task?source=archive#task-questions",
                 digest_task_path(destination, anchor: "task-questions")
    assert_includes digest_time_tag("2026-08-30T12:30:00Z"),
                    'datetime="2026-08-30T12:30:00Z"'
    assert_includes digest_time_tag("not-a-time"), "Time unavailable"
  end

  test "primary markdown receives deterministic collision-safe anchors and an outline at four h2 sections" do
    source = <<~MD
      # Guide

      ## Review
      One.

      ## Review
      Two.

      ## Ship & learn
      Three.

      ## Finish
      Four.
    MD

    first = render_markdown_document(source)
    second = render_markdown_document(source)

    assert_equal first, second
    assert_equal %w[review review-2 ship-learn finish], first.fetch(:outline).pluck(:id)
    assert_includes first.fetch(:html), '<h2 id="review">Review</h2>'
    assert_includes first.fetch(:html), '<h2 id="review-2">Review</h2>'
  end

  test "short markdown keeps anchors without unnecessary outline chrome and remains sanitized" do
    document = render_markdown_document(<<~MD)
      ## Safe

      [bad](javascript:alert(1)) <script>alert(2)</script>

      ## Also safe
    MD

    assert_empty document.fetch(:outline)
    assert_includes document.fetch(:html), '<h2 id="safe">Safe</h2>'
    refute_includes document.fetch(:html), "<script>"
    refute_includes document.fetch(:html), "javascript:"
  end
end
