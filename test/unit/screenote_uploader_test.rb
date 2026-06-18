require "test_helper"
require "hive/screenote_uploader"
require "net/http"

class ScreenoteUploaderTest < Minitest::Test
  include HiveTestHelper

  Response = Struct.new(:code, :body, keyword_init: true)

  def test_successful_upload_returns_screenote_payload
    with_tmp_dir do |dir|
      image = File.join(dir, "shot.png")
      File.binwrite(image, "png")
      seen = {}
      response = Response.new(code: "201", body: JSON.generate("annotate_url" => "https://screenote.test/s/1",
                                                               "screenshot_id" => 1))
      uploader = Hive::ScreenoteUploader.new(
        base_url: "https://screenote.test",
        api_token: "secret",
        http: ->(uri, request, open_timeout:, read_timeout:) {
          seen[:uri] = uri
          seen[:request] = request
          seen[:open_timeout] = open_timeout
          seen[:read_timeout] = read_timeout
          response
        }
      )

      result = uploader.upload(path: image, title: "Home")

      assert_equal "https://screenote.test/s/1", result["annotate_url"]
      assert_equal 1, result["screenshot_id"]
      assert_equal URI("https://screenote.test/api/v1/screenshots"), seen[:uri]
      assert_equal "Bearer secret", seen[:request]["Authorization"]
      assert_match(/multipart\/form-data; boundary=/, seen[:request]["Content-Type"])
      assert_includes seen[:request].body, %(name="title")
      assert_includes seen[:request].body, "Home"
      assert_includes seen[:request].body, %(name="image"; filename="shot.png")
      assert_equal Hive::ScreenoteUploader::DEFAULT_OPEN_TIMEOUT, seen[:open_timeout]
      assert_equal Hive::ScreenoteUploader::DEFAULT_READ_TIMEOUT, seen[:read_timeout]
    end
  end

  def test_non_success_response_returns_nil
    with_tmp_dir do |dir|
      image = File.join(dir, "shot.png")
      File.binwrite(image, "png")
      uploader = Hive::ScreenoteUploader.new(
        base_url: "https://screenote.test",
        api_token: "secret",
        http: ->(*) { Response.new(code: "500", body: "{}") }
      )

      _out, err = capture_io do
        assert_nil uploader.upload(path: image, title: "Home")
      end
      assert_includes err, "screenote upload failed"
    end
  end

  def test_timeout_or_exception_returns_nil
    with_tmp_dir do |dir|
      image = File.join(dir, "shot.png")
      File.binwrite(image, "png")
      uploader = Hive::ScreenoteUploader.new(
        base_url: "https://screenote.test",
        api_token: "secret",
        http: ->(*) { raise Net::ReadTimeout }
      )

      _out, err = capture_io do
        assert_nil uploader.upload(path: image, title: "Home")
      end
      assert_includes err, "Net::ReadTimeout"
    end
  end

  def test_non_object_success_body_returns_nil_with_diagnostic
    with_tmp_dir do |dir|
      image = File.join(dir, "shot.png")
      File.binwrite(image, "png")
      uploader = Hive::ScreenoteUploader.new(
        base_url: "https://screenote.test",
        api_token: "secret",
        http: ->(*) { Response.new(code: "201", body: JSON.generate([ 1, 2, 3 ])) }
      )

      _out, err = capture_io do
        assert_nil uploader.upload(path: image, title: "Home")
      end
      assert_includes err, "non-object response body",
                      "a valid-but-non-object 201 body must surface an accurate diagnostic"
    end
  end

  def test_relative_annotate_url_is_rejected
    with_tmp_dir do |dir|
      image = File.join(dir, "shot.png")
      File.binwrite(image, "png")
      uploader = Hive::ScreenoteUploader.new(
        base_url: "https://screenote.test",
        api_token: "secret",
        http: ->(*) { Response.new(code: "201", body: JSON.generate("annotate_url" => "/s/123")) }
      )

      _out, err = capture_io do
        assert_nil uploader.upload(path: image, title: "Home")
      end
      assert_includes err, "non-http annotate_url",
                      "a scheme-less annotate_url must be rejected at the uploader source"
    end
  end

  def test_missing_credentials_skip_without_transport
    called = false
    uploader = Hive::ScreenoteUploader.new(
      base_url: "",
      api_token: "",
      http: ->(*) { called = true }
    )

    assert_nil uploader.upload(path: __FILE__, title: "No credentials")
    refute called
  end

  # The @http seam is stubbed in every test, so no real server ever parses the
  # body — pin the exact wire format here. A framing regression (a dropped CRLF,
  # a missing file Content-Type, re-encoded image bytes, an absent closing
  # boundary) passes every substring assertion but breaks every real upload.
  def test_multipart_body_frames_each_part_with_exact_wire_format
    with_tmp_dir do |dir|
      image = File.join(dir, "shot.png")
      # Embed CRLF/binary bytes the multipart framing must carry verbatim.
      png = "\x89PNG\r\n\x1a\n\x00body".b
      File.binwrite(image, png)
      seen = {}
      uploader = Hive::ScreenoteUploader.new(
        base_url: "https://screenote.test",
        api_token: "secret",
        http: ->(_uri, request, open_timeout:, read_timeout:) {
          seen[:request] = request
          Response.new(code: "201", body: JSON.generate("annotate_url" => "https://screenote.test/s/1"))
        }
      )

      uploader.upload(path: image, title: "Home")

      boundary = seen[:request]["Content-Type"][/boundary=(.+)\z/, 1]
      refute_nil boundary, "the Content-Type header must carry the multipart boundary"
      expected = +""
      expected << "--#{boundary}\r\n"
      expected << %(Content-Disposition: form-data; name="title"\r\n)
      expected << "\r\n"
      expected << "Home\r\n"
      expected << "--#{boundary}\r\n"
      expected << %(Content-Disposition: form-data; name="image"; filename="shot.png"\r\n)
      expected << "Content-Type: image/png\r\n"
      expected << "\r\n"
      expected.force_encoding(Encoding::BINARY)
      expected << png
      expected << "\r\n"
      expected << "--#{boundary}--\r\n"

      assert_equal expected, seen[:request].body.b,
                   "the multipart body must frame each part with exact CRLFs, a file " \
                   "Content-Type, verbatim image bytes, and the closing --boundary-- line"
    end
  end

  # A non-ASCII caption (em-dash, Cyrillic, emoji — realistic for this
  # Russian-context project) appended into the BINARY multipart buffer used to
  # flip its encoding to UTF-8 and then raise Encoding::CompatibilityError when
  # the binary image bytes were appended, silently returning nil.
  def test_non_ascii_title_uploads_without_encoding_error
    with_tmp_dir do |dir|
      image = File.join(dir, "shot.png")
      File.binwrite(image, "\x89PNG\r\n\x1a\nbody".b)
      seen = {}
      uploader = Hive::ScreenoteUploader.new(
        base_url: "https://screenote.test",
        api_token: "secret",
        http: ->(_uri, request, open_timeout:, read_timeout:) {
          seen[:request] = request
          Response.new(code: "201", body: JSON.generate("annotate_url" => "https://screenote.test/s/1"))
        }
      )

      title = "Главная — тёмная тема 😀"
      result = uploader.upload(path: image, title: title)

      refute_nil result, "a UTF-8 caption must not raise Encoding::CompatibilityError and yield nil"
      assert_equal "https://screenote.test/s/1", result["annotate_url"]
      assert_includes seen[:request].body.b, title.b,
                      "the caption's UTF-8 bytes must survive into the binary multipart body"
    end
  end

  def test_content_type_selects_jpeg_for_jpg_jpeg_and_uppercase
    %w[shot.jpg shot.jpeg shot.JPG].each do |name|
      with_tmp_dir do |dir|
        image = File.join(dir, name)
        File.binwrite(image, "jpg")
        seen = {}
        uploader = Hive::ScreenoteUploader.new(
          base_url: "https://screenote.test",
          api_token: "secret",
          http: ->(_uri, request, open_timeout:, read_timeout:) {
            seen[:body] = request.body
            Response.new(code: "201", body: JSON.generate("annotate_url" => "https://screenote.test/s/1"))
          }
        )

        uploader.upload(path: image, title: "Home")

        assert_includes seen[:body], "Content-Type: image/jpeg",
                        "#{name} must declare image/jpeg (the extension match is case-insensitive)"
      end
    end
  end

  def test_content_type_defaults_to_png_for_other_extensions
    with_tmp_dir do |dir|
      image = File.join(dir, "shot.png")
      File.binwrite(image, "png")
      seen = {}
      uploader = Hive::ScreenoteUploader.new(
        base_url: "https://screenote.test",
        api_token: "secret",
        http: ->(_uri, request, open_timeout:, read_timeout:) {
          seen[:body] = request.body
          Response.new(code: "201", body: JSON.generate("annotate_url" => "https://screenote.test/s/1"))
        }
      )

      uploader.upload(path: image, title: "Home")

      assert_includes seen[:body], "Content-Type: image/png",
                      "a non-jpeg still must fall through to image/png"
    end
  end

  def test_quote_backslash_escapes_special_filename_characters
    with_tmp_dir do |dir|
      # A filename carrying a double-quote and a backslash must be escaped so it
      # can't break out of the Content-Disposition value.
      image = File.join(dir, %(a"b\\c.png))
      File.binwrite(image, "png")
      seen = {}
      uploader = Hive::ScreenoteUploader.new(
        base_url: "https://screenote.test",
        api_token: "secret",
        http: ->(_uri, request, open_timeout:, read_timeout:) {
          seen[:body] = request.body
          Response.new(code: "201", body: JSON.generate("annotate_url" => "https://screenote.test/s/1"))
        }
      )

      uploader.upload(path: image, title: "Home")

      assert_includes seen[:body], 'filename="a\"b\\\\c.png"',
                      "both the quote and the backslash must be backslash-escaped, not passed raw"
    end
  end

  def test_empty_annotate_url_returns_nil_with_diagnostic
    with_tmp_dir do |dir|
      image = File.join(dir, "shot.png")
      File.binwrite(image, "png")
      uploader = Hive::ScreenoteUploader.new(
        base_url: "https://screenote.test",
        api_token: "secret",
        http: ->(*) { Response.new(code: "201", body: JSON.generate("annotate_url" => "")) }
      )

      _out, err = capture_io do
        assert_nil uploader.upload(path: image, title: "Home")
      end
      assert_includes err, "blank annotate_url",
                      "a 201 with no annotate_url is a screenote contract break, not a silent miss " \
                      "indistinguishable from screenote being disabled"
    end
  end

  def test_screenshot_id_passes_through_verbatim
    with_tmp_dir do |dir|
      image = File.join(dir, "shot.png")
      File.binwrite(image, "png")
      uploader = Hive::ScreenoteUploader.new(
        base_url: "https://screenote.test",
        api_token: "secret",
        http: ->(*) {
          Response.new(code: "201", body: JSON.generate("annotate_url" => "https://screenote.test/s/9",
                                                         "screenshot_id" => "abc-123"))
        }
      )

      result = uploader.upload(path: image, title: "Home")

      assert_equal "abc-123", result["screenshot_id"],
                   "the screenshot_id is passed through untouched for the manifest"
    end
  end
end
