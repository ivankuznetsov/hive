require "test_helper"
require "hive/digest/shipped_item"

class HiveDigestShippedItemTest < Minitest::Test
  def test_blank_project_name_is_rejected_at_the_boundary
    error = assert_raises(ArgumentError) { build(project_name: "  ") }

    assert_match(/non-blank project_name/, error.message)
  end

  def test_blank_pr_number_and_slug_together_are_rejected
    # A blank pr_number AND a blank slug would yield a "<project>/" id that
    # collides every such item onto one key in the categorizer's id→row map.
    error = assert_raises(ArgumentError) { build(pr_number: nil, slug: "") }

    assert_match(/collision-safe categorizer_id/, error.message)
  end

  def test_slug_alone_keeps_the_id_collision_safe
    item = build(pr_number: nil, slug: "demo-260613-abcd")

    assert_equal "alpha/demo-260613-abcd", item.categorizer_id
  end

  private

  def build(project_name: "alpha", slug: "slug-1", pr_number: 10)
    Hive::Digest::ShippedItem.new(
      project_name: project_name,
      slug: slug,
      display_name: "Task",
      pr_url: "https://example.test/pulls/1",
      pr_number: pr_number,
      pr_title: "Title",
      pr_body: "body",
      shipped_at: Time.utc(2026, 6, 13, 12)
    )
  end
end
