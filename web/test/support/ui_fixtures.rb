# Reusable, filesystem-backed workspaces for visual tests. These use the same
# disposable HIVE_HOME and native task creation as the rest of the web suite.
module UiFixtures
  TASKS = [
    [ "hive-demo", "Make task progress easier to scan", "1-inbox", nil, nil ],
    [ "hive-demo", "Keep long task titles readable on a small phone screen", "1-inbox", nil, nil ],
    [ "hive-demo", "Choose how notifications should work", "2-brainstorm", "brainstorm.md", "WAITING" ],
    [ "hive-demo", "Plan keyboard navigation for the task board", "3-plan", "plan.md", "COMPLETE" ],
    [ "hive-demo", "Recover a failed screenshot upload", "4-execute", "task.md", "ERROR" ],
    [ "hive-demo", "Review the new project setup flow", "6-review", "review.md", "REVIEW_WAITING" ],
    [ "hive-demo", "Improve empty workspace guidance", "9-done", "task.md", "COMPLETE" ],
    [ "notes-demo", "Add image attachments to notes", "1-inbox", nil, nil ],
    [ "notes-demo", "Decide how shared notebooks should behave", "2-brainstorm", "brainstorm.md", "WAITING" ]
  ].freeze

  def seed_ui_fixture!(scenario)
    raise "UI fixtures require the isolated test workspace" unless Rails.env.test? &&
      File.basename(ENV.fetch("HIVE_TEST_HOME_ROOT")).start_with?("hive-web-test")
    raise ArgumentError, "unknown UI scenario: #{scenario}" unless %i[empty populated].include?(scenario)
    raise "seed UI fixtures before creating other projects" unless Hive::Config.registered_projects.empty?
    return [] if scenario == :empty

    TASKS.map(&:first).uniq.each { |project| create_hive_project!(project) }
    TASKS.map do |project, title, stage, artifact, marker|
      slug = create_task!(project, title)
      source = stage_dir(project, "1-inbox").join(slug)
      folder = stage_dir(project, stage).join(slug)
      FileUtils.mv(source, folder) unless source == folder
      Hive::TaskMeta.update_display_name(folder.to_s, title)
      if artifact
        body = marker == "WAITING" ? "### Q1. Which behavior should we prioritize?\n\n### A1.\n\n" : "Sample task evidence for UI testing.\n\n"
        folder.join(artifact).write("# #{title}\n\n#{body}<!-- #{marker} -->\n")
      end
      Hive::TaskMeta.rewrite(folder.to_s, completed_at: Time.now.utc) if stage == "9-done"
      { project:, slug:, title:, stage: }
    end
  end
end
