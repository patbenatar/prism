ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

# The GitHub API must never be hit for real in tests — every request has to
# be stubbed explicitly. Localhost is allowed through for Capybara/Selenium.
WebMock.disable_net_connect!(allow_localhost: true)

# Shared helpers: GitHub stubbing/fixtures and the OmniAuth sign-in flow.
Dir[Rails.root.join("test/support/**/*.rb")].sort.each { |file| require file }

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Every test can stub GitHub; only tests that sign someone in need the auth
    # helpers, and those are mixed into the case classes that can use them.
    include GithubStubs

    # Building and signing GitHub webhook deliveries. Harmless everywhere
    # else; only the webhook tests call any of it.
    include WebhookHelpers

    # OmniAuth's mock is global state. Leaving it set would leak a signed-in
    # identity into the next test.
    teardown { reset_github_auth if respond_to?(:reset_github_auth) }
  end
end

class ActionDispatch::IntegrationTest
  include AuthenticationHelpers::Integration
end

class ActionDispatch::SystemTestCase
  include AuthenticationHelpers::System
end
