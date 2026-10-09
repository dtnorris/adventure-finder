# Coverage is opt-in for the directly invoked fast test task.
SimpleCov.configure do
  command_name "AdventureFinder Tests"
  cover "lib/**/*.rb"
  enable_coverage :branch
end
