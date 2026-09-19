require "test_helper"

# Browser-driven tests. Headless Chromium is installed in Dockerfile.dev at
# /usr/bin/chromium (with chromium-driver on PATH).
#
# The window is laptop-sized, not phone-sized: Prism is desktop-first, and the
# reading column, gutter and side rail only exist above the `lg` breakpoint. A
# test that needs to check the phone layout resizes the window itself with
# `page.driver.browser.manage.window.resize_to(390, 844)`.
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Capybara + a single browser don't play well with parallel workers.
  parallelize(workers: 1)

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1440, 900 ] do |options|
    options.binary = "/usr/bin/chromium" if File.exist?("/usr/bin/chromium")
    options.add_argument("--headless=new")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--disable-gpu")
    options.add_argument("--window-size=1440,900")

    # Surface the browser console to the test process. A Content Security
    # Policy violation is reported there and nowhere else: the page still
    # renders, the blocked thing simply never runs, so without this a CSP
    # mistake looks like a passing test. See `assert_no_csp_violations`.
    options.add_option("goog:loggingPrefs", { browser: "ALL" })
  end

  # Fails with the offending messages if the browser reported a CSP violation
  # since the last call. Reading the log drains it, so call it at the end of
  # whatever you want covered.
  def assert_no_csp_violations
    entries = page.driver.browser.logs.get(:browser)
    violations = entries.map(&:message).grep(/Content Security Policy/i)

    assert_empty violations, "the browser blocked something:\n#{violations.join("\n")}"
  end

  # Enqueued jobs run synchronously so the browser observes their results
  # within the test.
  setup { ActiveJob::Base.queue_adapter = :inline }

  # One browser is shared across the whole run, so a test that resized the
  # window to check the phone layout must not leak that viewport into the next.
  teardown { page.driver.browser.manage.window.resize_to(1440, 900) if page.driver.respond_to?(:browser) }
end
