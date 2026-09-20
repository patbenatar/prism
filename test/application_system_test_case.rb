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

  # The window size every test starts at. Laptop-shaped, because Prism is
  # desktop-first and the reading column, gutter and side rail only exist
  # above the `lg` breakpoint.
  DEFAULT_WINDOW = [ 1440, 900 ].freeze

  # Enqueued jobs run synchronously so the browser observes their results
  # within the test.
  setup { ActiveJob::Base.queue_adapter = :inline }

  # One browser is shared across the whole suite (`parallelize(workers: 1)`),
  # so a test that resizes to phone width leaks that width into whatever runs
  # next — which shows up as an unrelated test failing on a layout it never
  # asked for. Restore the default after every test rather than making each
  # test defend itself in setup.
  teardown { resize_window(*DEFAULT_WINDOW) }

  def resize_window(width, height)
    page.driver.browser.manage.window.resize_to(width, height)
  rescue StandardError
    # No browser was started (the test never visited a page), or it has already
    # gone away. Nothing to restore either way.
    nil
  end
end
