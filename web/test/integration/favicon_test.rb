require "test_helper"

# Guards the favicon assets the layout links. The box previously had only a
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

    get "/icon.png"
    assert_response :success
    assert_equal "image/png", response.media_type
  end
end
