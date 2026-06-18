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
end
