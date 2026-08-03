require "test_helper"

class IdeasTest < ActionDispatch::IntegrationTest
  setup do
    @project = create_hive_project!
    sign_in!
  end

  test "creating an idea lands a task in 1-inbox" do
    post "/ideas", params: { project: @project, text: "Ship the onboarding flow" }

    assert_redirected_to "/"
    follow_redirect!
    assert_match "Idea added", response.body
    slug = stage_dir(@project, "1-inbox").children.map { |c| c.basename.to_s }
                                         .find { |s| s.start_with?("ship-the-onboarding") }
    assert slug, "the idea must become a 1-inbox task folder"
  end

  test "idea creation returns to the same-origin status view only" do
    destination = grid_url(project: @project)
    post ideas_path,
         params: { project: @project, text: "Stay on the explicit grid" },
         headers: { "HTTP_REFERER" => destination }
    assert_redirected_to destination

    post ideas_path,
         params: { project: @project, text: "Reject an external return" },
         headers: { "HTTP_REFERER" => "https://attacker.example/grid" }
    assert_redirected_to root_path
  end

  test "attached images land in the task's assets dir, TUI contract" do
    png = Rack::Test::UploadedFile.new(
      StringIO.new("\x89PNG\r\n\x1a\nfake".b), "image/png", original_filename: "image1.png"
    )

    post "/ideas", params: { project: @project, text: "Bug report [image1]", images: [ png ] }

    assert_redirected_to "/"
    folder = stage_dir(@project, "1-inbox").children
                                           .find { |c| c.basename.to_s.start_with?("bug-report") }
    assert folder, "the idea must create a task folder"
    asset = folder.join("assets", "image1.png")
    assert asset.file?, "the upload must be copied to assets/image1.png like the TUI does"
    assert_match "[image1]", folder.join("idea.md").read, "the placeholder must survive into idea.md"
  end

  test "a forged placeholder name cannot escape the assets dir" do
    evil = Rack::Test::UploadedFile.new(
      StringIO.new("x"), "image/png", original_filename: "../../escape.png"
    )

    post "/ideas", params: { project: @project, text: "Sneaky", images: [ evil ] }

    assert_redirected_to "/", "a non-placeholder filename is renamed, not rejected"
    folder = stage_dir(@project, "1-inbox").children
                                           .find { |c| c.basename.to_s.start_with?("sneaky") }
    assert folder.join("assets", "image1.png").file?,
           "the upload must be renamed to a safe imageN name inside assets/"
    refute File.exist?(File.join(ENV["HIVE_TEST_HOME_ROOT"], "escape.png")),
           "nothing may be written outside the task folder"
  end

  test "image count and size limits reject invalid parsed uploads" do
    inbox = stage_dir(@project, "1-inbox")
    existing_entries = inbox.children.map { |entry| entry.basename.to_s }.sort
    too_many = Array.new(IdeasController::MAX_IMAGES + 1) do |index|
      Rack::Test::UploadedFile.new(
        StringIO.new("x"), "image/png", original_filename: "image#{index + 1}.png"
      )
    end

    post "/ideas", params: { project: @project, text: "Too many", images: too_many }
    assert_response :unprocessable_entity
    assert_match "too many images (max 8)", response.body

    oversized_file = Tempfile.new([ "oversized", ".png" ])
    oversized_file.truncate(IdeasController::MAX_IMAGE_BYTES + 1)
    oversized = Rack::Test::UploadedFile.new(
      oversized_file.path, "image/png", original_filename: "image1.png"
    )
    post "/ideas", params: { project: @project, text: "Too large", images: [ oversized ] }
    assert_response :unprocessable_entity
    assert_match "image 1 is too large (max 10 MB)", response.body
    assert_equal existing_entries, inbox.children.map { |entry| entry.basename.to_s }.sort,
                 "rejected multipart requests must not create a task"
  ensure
    oversized_file&.close!
  end

  test "unknown project is a 404, empty text a 422" do
    post "/ideas", params: { project: "nope", text: "hi" }
    assert_response :not_found

    post "/ideas", params: { project: @project, text: "   " }
    assert_response :unprocessable_entity
    assert_match(/idea text is empty|param is missing/, response.body,
                 "blank idea text must surface a readable error, not a blank 500")
  end

  test "project storage failures render a typed error without leaking paths" do
    inbox = stage_dir(@project, "1-inbox")
    existing_entries = inbox.children.map { |entry| entry.basename.to_s }.sort
    original_mode = inbox.stat.mode & 0o777
    File.chmod(0o500, inbox)

    post "/ideas", params: { project: @project, text: "Permission failure" }

    assert_response :unprocessable_entity
    assert_match "Action failed", response.body
    assert_match "could not add idea because an I/O operation failed (Errno::EACCES)", response.body
    refute_match Regexp.escape(ENV.fetch("HIVE_TEST_HOME_ROOT")), response.body
    assert_equal existing_entries, inbox.children.map { |entry| entry.basename.to_s }.sort,
                 "a failed Web capture must not leave a partial task"
  ensure
    File.chmod(original_mode, inbox) if original_mode && inbox&.exist?
  end
end
