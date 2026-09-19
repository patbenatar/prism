# Add your own tasks in files placed in lib/tasks ending in .rake,
# for example lib/tasks/capistrano.rake, and they will automatically be available to Rake.

require_relative "config/application"

Rails.application.load_tasks

# `bin/rails test` (no paths) discovers every test/**/*_test.rb except
# Rails::TestUnit::Runner's own default exclusion (test/{system,dummy,fixtures}).
# test/e2e/*_test.rb is Prism's opt-in live-GitHub tier (test/e2e/e2e_helper.rb,
# docs/testing.md): it `skip`s itself without E2E_GITHUB_TOKEN/E2E_REPO/E2E_PR,
# but it must never even load by accident from a bare `bin/rails test`, so it is
# folded into the same default-exclude glob here. `bin/rails test test/e2e`
# still runs it: passing an explicit path bypasses the exclude glob entirely
# (see Rails::TestUnit::Runner#list_tests). This has to happen this early
# (Rakefile, loaded by `test:prepare` before Minitest's Rails plugin resolves
# the test file list) because ENV is read lazily, and config/environment.rb
# itself hasn't loaded yet at that point — an initializer would be too late.
ENV["DEFAULT_TEST_EXCLUDE"] ||= "test/{system,dummy,fixtures,e2e}/**/*_test.rb"
