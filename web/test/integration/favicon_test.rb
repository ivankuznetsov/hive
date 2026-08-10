require "test_helper"

# Guards the favicon assets the layout links. Hive web previously had only a
# placeholder icon and no favicon.ico, so every page load logged a
# `/favicon.ico` 404 (browsers request it from the root unconditionally).
class FaviconTest < ActionDispatch::IntegrationTest
  test "favicon assets are served from the root, no /favicon.ico 404" do
    get "/favicon.ico"
    assert_response :success
    assert_equal "image/vnd.microsoft.icon", response.media_type

    get "/icon.svg"
    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_includes response.body, "<title id=\"title\">Hive web</title>"
    assert_includes response.body, '<rect width="96" height="96" fill="#0d1117"/>'
    assert_includes response.body, 'stroke="#f0b429"'
    assert_includes response.body, "M48 8 82 28v40L48 88 14 68V28z"
    refute_includes response.body, "#c96442"
    refute_includes response.body, "rx="

    get "/icon.png"
    assert_response :success
    assert_equal "image/png", response.media_type

    png = Rails.root.join("public/icon.png").binread(26)
    assert_equal "\x89PNG\r\n\x1A\n".b, png.byteslice(0, 8)
    assert_equal [ 512, 512 ], png.byteslice(16, 8).unpack("NN")
    assert_equal 2, png.getbyte(25), "icon.png must be opaque RGB so launchers cannot render white corners"
  end
end
