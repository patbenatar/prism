# frozen_string_literal: true

# Driving `prefers-color-scheme` from a system test.
#
# Prism's dark mode is the device's preference, not a class the app toggles,
# so there is nothing in the DOM for a test to flip — the only honest way to
# check it is to make the browser actually prefer dark. Headless Chromium has
# no OS to ask, and there is no Capybara or Selenium API for this: the media
# feature is emulated over the Chrome DevTools Protocol.
#
#   with_color_scheme(:dark) { visit repos_path; ... }
#
# `Emulation.setEmulatedMedia` overrides a media feature for the page and
# stays in force until it is cleared, so `with_color_scheme` always restores
# the previous value — one browser is shared by the whole suite
# (`parallelize(workers: 1)`), and a leaked dark preference would show up as
# an unrelated test failing on colours it never asked about.
#
# It also carries `computed_style`, the general "what did the browser actually
# resolve" reader — every assertion here is about a used value, never about the
# text of the stylesheet, and other suites (the cursor-affordance test) want the
# same thing.
#
# Lives in test/support so nothing shared has to change: the glob in
# test_helper.rb loads it and it mixes itself into the system-test case below.
module ColorSchemeHelpers
  SCHEMES = %w[light dark].freeze

  # Runs the block with the browser reporting `prefers-color-scheme: <scheme>`.
  # Without a block it just sets the preference and leaves it set, for a test
  # that wants the whole body in one mode.
  def with_color_scheme(scheme)
    scheme = scheme.to_s
    raise ArgumentError, "unknown colour scheme #{scheme.inspect}" unless SCHEMES.include?(scheme)

    previous = @emulated_color_scheme
    emulate_color_scheme(scheme)
    return scheme unless block_given?

    begin
      yield
    ensure
      previous ? emulate_color_scheme(previous) : reset_color_scheme
    end
  end

  # Drops the override, handing the page back to whatever the browser would
  # report on its own (light, headless). The system case's teardown calls this,
  # so no test has to remember.
  def reset_color_scheme
    @emulated_color_scheme = nil
    send_cdp("Emulation.setEmulatedMedia", features: [])
  end

  # What the page itself believes, read back through `matchMedia` rather than
  # trusted from the CDP call — the point of the emulation is that the page
  # sees it, and that is the only thing worth asserting.
  def page_prefers_dark?
    page.evaluate_script("window.matchMedia('(prefers-color-scheme: dark)').matches")
  end

  # A CSS custom property as declared on :root, e.g. "--tint-strength".
  #
  # Note that this is the *declared* value, not a resolved one: a colour token
  # comes back as the literal `light-dark(#f2f3f8,#0e1020)`, because
  # substitution happens where a variable is used. To see which side won, paint
  # it onto an element and read `computed_style` — see DarkModeTest#token_color.
  def root_css_variable(name)
    page.evaluate_script(
      "getComputedStyle(document.documentElement).getPropertyValue('#{name}').trim()"
    )
  end

  # The used value of a CSS property on the first element matching `selector`,
  # as the browser resolved it — "rgb(14, 16, 32)", not "light-dark(...)".
  def computed_style(selector, property)
    page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector(#{selector.to_json});
        return el ? getComputedStyle(el).getPropertyValue(#{property.to_json}) : null;
      })()
    JS
  end

  private

  def emulate_color_scheme(scheme)
    @emulated_color_scheme = scheme
    send_cdp("Emulation.setEmulatedMedia",
             features: [ { name: "prefers-color-scheme", value: scheme } ])
  end

  # `execute_cdp` exists on the Chrome/Chromium driver only. Selenium renamed
  # it once, so try both before giving up — and give up loudly, because a
  # silently ignored emulation would make a dark-mode test pass against the
  # light page.
  def send_cdp(command, **params)
    browser = page.driver.browser

    if browser.respond_to?(:execute_cdp)
      browser.execute_cdp(command, **params)
    elsif browser.respond_to?(:send_cmd)
      browser.send_cmd(command, **params)
    else
      raise "this driver (#{browser.class}) cannot emulate media features over CDP"
    end
  end
end

ActionDispatch::SystemTestCase.include(ColorSchemeHelpers)

# Every system test gets the override cleared, whether or not it set one: the
# suite shares a single browser, so a test that ended in dark would otherwise
# hand the next one a dark page.
ActionDispatch::SystemTestCase.teardown do
  reset_color_scheme if respond_to?(:reset_color_scheme)
rescue StandardError
  # No browser was started, or it has already gone away. Nothing to reset.
  nil
end
