require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.libs << "lib"
  task.test_files = FileList["test/**/*_test.rb"]
  task.warning = false
end

desc "Build agent-cli-runtime"
task :build do
  sh "gem", "build", "agent-cli-runtime.gemspec"
end

task default: :test
