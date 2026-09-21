require "test_helper"
require "hive/commands/init"
require "hive/tui/bubble_model"
require "hive/tui/composer_staging"

class TuiNewIdeaAttachmentsTest < Minitest::Test
  include HiveTestHelper

  def initialize_project(dir)
    capture_io { Hive::Commands::Init.new(dir).call }
  end

  def snapshot_for(project)
    Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-13T00:00:00Z",
      "projects" => [ { "name" => project, "tasks" => [] } ]
    )
  end

  def model_for(project:, buffer:, attachments:, staging_dir:)
    Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        mode: :new_idea,
        snapshot: snapshot_for(project),
        scope: 0,
        new_idea_project_name: project,
        new_idea_buffer: buffer,
        new_idea_cursor: buffer.length,
        new_idea_attachments: attachments,
        new_idea_staging_dir: staging_dir
      )
    )
  end

  def test_rich_submit_writes_markdown_body_assets_and_cleans_staging
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        initialize_project(dir)
        project = File.basename(dir)
        staging_dir = Dir.mktmpdir("hive-tui-composer-test-")
        first = File.join(staging_dir, "image-1.png")
        second = File.join(staging_dir, "image-2.png")
        File.binwrite(first, "one".b)
        File.binwrite(second, "two".b)
        attachments = [
          Hive::Tui::Model::Attachment.new(label: "image1", staging_path: first, ext: "png"),
          Hive::Tui::Model::Attachment.new(label: "image2", staging_path: second, ext: "png")
        ]
        bubble = model_for(
          project: project,
          buffer: "first [image1] middle [image2]",
          attachments: attachments,
          staging_dir: staging_dir
        )

        capture_io { bubble.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED) }

        assert_equal :grid, bubble.hive_model.mode
        assert_equal [], bubble.hive_model.new_idea_attachments
        assert_nil bubble.hive_model.new_idea_staging_dir
        refute File.exist?(staging_dir), "successful rich submit must clean the composer staging dir"

        glob = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "first-middle-*")]
        assert_equal 1, glob.size
        idea = File.read(File.join(glob.first, "idea.md"))
        assert_includes idea, "first ![](assets/bug-1.png) middle ![](assets/bug-2.png)"
        assert_equal "one", File.binread(File.join(glob.first, "assets", "bug-1.png"))
        assert_equal "two", File.binread(File.join(glob.first, "assets", "bug-2.png"))
      ensure
        Hive::Tui::ComposerStaging.cleanup!(staging_dir) if staging_dir && File.exist?(staging_dir)
      end
    end
  end

  def test_blocked_rich_submit_creates_no_task_then_explicit_retry_creates_one
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        initialize_project(dir)
        project = File.basename(dir)
        staging_dir = Dir.mktmpdir("hive-tui-composer-test-")
        staging_path = File.join(staging_dir, "image-1.png")
        File.binwrite(staging_path, "image".b)
        attachment = Hive::Tui::Model::Attachment.new(
          label: "image1",
          staging_path: staging_path,
          ext: "png"
        )
        bubble = model_for(
          project: project,
          buffer: "draft [image1]",
          attachments: [ attachment ],
          staging_dir: staging_dir
        )
        unhealthy = Hive::Tui::Snapshot.from_payload(
          "generated_at" => "2026-08-30T00:00:01Z",
          "projects" => [
            { "name" => project, "error" => "not_initialised", "tasks" => [] }
          ]
        )
        inbox = File.join(dir, ".hive-state", "stages", "1-inbox")

        bubble.update(Hive::Tui::Messages::SnapshotArrived.new(snapshot: unhealthy))
        capture_io { bubble.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED) }

        assert_empty Dir[File.join(inbox, "*")].select { |path| File.directory?(path) }
        assert_equal :new_idea_project, bubble.hive_model.mode
        assert_equal "draft [image1]", bubble.hive_model.new_idea_buffer
        assert_equal [ attachment ], bubble.hive_model.new_idea_attachments
        assert_equal staging_dir, bubble.hive_model.new_idea_staging_dir
        assert File.exist?(staging_path), "blocked preflight must retain staged bytes"

        bubble.update(
          Hive::Tui::Messages::SnapshotArrived.new(snapshot: snapshot_for(project))
        )
        assert_nil bubble.hive_model.new_idea_project_cursor
        bubble.update(Hive::Tui::Messages::NEW_IDEA_PROJECT_CURSOR_DOWN)
        bubble.update(Hive::Tui::Messages::NEW_IDEA_PROJECT_SELECTED)
        capture_io { bubble.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED) }

        tasks = Dir[File.join(inbox, "*")].select { |path| File.directory?(path) }
        assert_equal 1, tasks.size
        assert_equal :grid, bubble.hive_model.mode
        assert_equal [], bubble.hive_model.new_idea_attachments
        assert_nil bubble.hive_model.new_idea_staging_dir
        refute File.exist?(staging_dir), "successful retry must clean staging"
      ensure
        Hive::Tui::ComposerStaging.cleanup!(staging_dir) if staging_dir && File.exist?(staging_dir)
      end
    end
  end

  def test_placeholder_only_title_falls_back_to_task_slug
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        initialize_project(dir)
        project = File.basename(dir)
        staging_dir = Dir.mktmpdir("hive-tui-composer-test-")
        path = File.join(staging_dir, "image-1.png")
        File.binwrite(path, "image".b)
        attachments = [
          Hive::Tui::Model::Attachment.new(label: "image1", staging_path: path, ext: "png")
        ]
        bubble = model_for(project: project, buffer: "[image1]", attachments: attachments, staging_dir: staging_dir)

        capture_io { bubble.update(Hive::Tui::Messages::NEW_IDEA_SUBMITTED) }

        glob = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "task-*")]
        assert_equal 1, glob.size
        idea = File.read(File.join(glob.first, "idea.md"))
        assert_includes idea, "![](assets/bug-1.png)"
      ensure
        Hive::Tui::ComposerStaging.cleanup!(staging_dir) if staging_dir && File.exist?(staging_dir)
      end
    end
  end
end
