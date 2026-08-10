require "test_helper"
require "open3"
require "rbconfig"

class ProductionCaptureAssetsTest < ActiveSupport::TestCase
  test "private production capture serves its isolated assets" do
    Dir.mktmpdir("hive-capture-assets") do |assets|
      script = <<~'RUBY'
        require "rack/mock"
        asset = Rails.application.assets.load_path.find("application.css")
        path = "#{Rails.application.config.assets.prefix}/#{asset.digested_path}"
        response = Rack::MockRequest.new(Rails.application).get(path)
        puts "server=#{Rails.application.config.assets.server}"
        puts "output_path=#{Rails.application.config.assets.output_path}"
        puts "asset=#{response.status},#{response.content_type},#{response.body.bytesize}"
      RUBY
      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_ENV" => "production",
          "SECRET_KEY_BASE_DUMMY" => "1",
          "HIVE_WEB_LOCAL_LOOPBACK" => "1",
          "HIVE_WEB_ASSETS_DIR" => assets
        },
        RbConfig.ruby, "bin/rails", "runner", script,
        chdir: Rails.root
      )

      assert status.success?, stderr
      assert_includes stdout, "server=true"
      assert_includes stdout, "output_path=#{assets}"
      assert_match(/asset=200,text\/css(?:;[^,]+)?,\d+/, stdout)
    end
  end
end
