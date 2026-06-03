require "test_helper"
require "hive/bot/idea_attachment_policy"
require "hive/bot/telegram"

class HiveBotIdeaAttachmentPolicyTest < Minitest::Test
  Draft = Struct.new(:attachments, keyword_init: true)

  def classify(update, draft: Draft.new(attachments: []), max_bytes: 20 * 1024 * 1024, max_count: 10)
    Hive::Bot::IdeaAttachmentPolicy.classify(update, draft, max_bytes: max_bytes, max_count: max_count)
  end

  def update(photo: nil, document: nil)
    Hive::Bot::Telegram::Update.new(
      update_id: 1,
      chat_id: 123,
      photo: photo,
      document: document
    )
  end

  def test_oversize_document_is_rejected_before_download
    result = classify(update(document: {
      file_id: "doc",
      file_name: "big.pdf",
      mime_type: "application/pdf",
      file_size: 35 * 1024 * 1024
    }))

    assert_equal :too_large, result.status
  end

  def test_disallowed_document_extension_is_rejected
    result = classify(update(document: {
      file_id: "doc",
      file_name: "run.exe",
      mime_type: "application/octet-stream",
      file_size: 1
    }))

    assert_equal :disallowed_type, result.status
  end

  def test_cap_reached_is_rejected
    draft = Draft.new(attachments: Array.new(10) { {} })

    result = classify(update(photo: { file_id: "photo", file_size: 1 }), draft: draft)

    assert_equal :cap_reached, result.status
  end

  def test_photo_is_allowed_as_jpg
    result = classify(update(photo: { file_id: "photo", file_size: 123 }))

    assert_equal :ok, result.status
    assert_equal "photo", result.file_id
    assert_equal "jpg", result.ext
  end

  def test_allowed_documents_resolve_extensions
    cases = {
      "notes.pdf" => "pdf",
      "notes.txt" => "txt",
      "notes.md" => "md",
      "notes.docx" => "docx"
    }

    cases.each do |name, ext|
      result = classify(update(document: {
        file_id: name,
        file_name: name,
        file_size: 1
      }))

      assert_equal :ok, result.status, name
      assert_equal ext, result.ext
    end
  end

  def test_extensionless_unknown_mime_document_is_rejected_not_coerced_to_png
    # No filename extension AND an unrecognized mime_type resolves ext=nil.
    # The png DEFAULT_EXTENSION must not silently rescue it onto the allowlist.
    result = classify(update(document: {
      file_id: "doc",
      file_name: "archive",
      mime_type: "application/zip",
      file_size: 1
    }))

    assert_equal :disallowed_type, result.status
  end

  def test_extensionless_no_mime_document_is_rejected
    result = classify(update(document: {
      file_id: "doc",
      file_name: "",
      file_size: 1
    }))

    assert_equal :disallowed_type, result.status
  end

  def test_document_extension_can_fall_back_to_mime_type
    result = classify(update(document: {
      file_id: "doc",
      file_name: "README",
      mime_type: "text/markdown",
      file_size: 1
    }))

    assert_equal :ok, result.status
    assert_equal "md", result.ext
  end
end
