# frozen_string_literal: true

require "digest"
require "fileutils"
require "hive/task_meta"

# Shared incident fixture helpers for Unit 5 acceptance integration tests:
# reproduces invalid plan frontmatter lists (e.g. `[F2, F3]`), archived
# same-project targets with slug/idempotency hints, and downstream dependents
# without duplicating parser matrices across test files.
module PlanDependencyIncidentFixture
  def create_done_prerequisite(project_root, slug:, id:, display_name: nil, idempotency_key: nil)
    folder = File.join(project_root, ".hive-state", "stages", "9-done", slug)
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "task.md"), "# #{slug}\n<!-- COMPLETE -->\n")
    attrs = {
      id: id,
      slug: slug,
      display_name: display_name || slug,
      completed_at: Time.now.utc
    }
    if idempotency_key
      attrs[:idempotency_key] = idempotency_key
      attrs[:input_fingerprint] = Digest::SHA256.hexdigest(idempotency_key)
    end
    Hive::TaskMeta.write(folder, **attrs)
    folder
  end

  def move_stage_task(project_root, slug, from:, to:)
    source = File.join(project_root, ".hive-state", "stages", from, slug)
    destination = File.join(project_root, ".hive-state", "stages", to, slug)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.mv(source, destination)
    destination
  end

  def incident_plan_markdown(depends_on: nil, low_risk: true, title: "Plan", marker: "COMPLETE")
    frontmatter = [ "---" ]
    if depends_on.is_a?(Array)
      frontmatter << "depends_on:"
      depends_on.each { |item| frontmatter << "  - #{item}" }
    elsif !depends_on.nil?
      frontmatter << "depends_on: #{depends_on}"
    end
    frontmatter << "files:"
    frontmatter << "  - lib/demo.rb"
    frontmatter << "  - test/demo_test.rb"
    frontmatter << "---"

    sections = [
      frontmatter.join("\n"),
      "# #{title}",
      "## Overview",
      "Incident acceptance plan.",
      "## Test scenarios",
      "- Focused integration tests verify the contract."
    ]
    if low_risk
      sections << "## Rollback"
      sections << "Revert this local change; it is fully reversible."
    end
    sections << "<!-- #{marker} -->"
    "#{sections.join("\n\n")}\n"
  end
end
