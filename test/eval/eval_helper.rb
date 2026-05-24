require "test_helper"

Dir[File.expand_path("support/**/*.rb", __dir__)]
  .reject { |path| path.end_with?("_test.rb") }
  .sort
  .each { |path| require path }
