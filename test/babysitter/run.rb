$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
$LOAD_PATH.unshift(File.expand_path("..", __dir__))

Dir[File.expand_path("acceptance/*_test.rb", __dir__)].sort.each do |file|
  require file
end
