# frozen_string_literal: true

require "application_system_test_case"

# Renders each browsing screen at laptop and phone width and saves a screenshot.
#
# This is a design check, not an assertion suite: the point is to look at the
# PNGs in tmp/screenshots after changing the theme or a component class. It
# still asserts each screen rendered, so a broken partial fails here too.
class DesignScreenshotsTest < ApplicationSystemTestCase
  OWNER = "acme"
  REPO  = "docs-site"
  NUMBER = 42

  LAPTOP = [ 1440, 950 ].freeze
  PHONE  = [ 390, 844 ].freeze

  setup do
    @user = users(:prism_dev)
    stub_github_get("/user/repos", fixture: :repos)
    stub_github_get("/repos/#{OWNER}/#{REPO}", fixture: :repo)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls", fixture: :pulls)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/files", fixture: :pull_files)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)
    stub_github_markdown(fixture: "markdown.html")
  end

  test "every browsing screen renders at laptop and phone width" do
    sign_in_as(@user)

    screens = {
      "repos" => repos_path,
      "pulls" => repo_pulls_path(owner: OWNER, repo: REPO),
      "pull-overview" => repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
    }

    [ [ "1440", LAPTOP ], [ "390", PHONE ] ].each do |label, (width, height)|
      resize_to(width, height)

      screens.each do |name, path|
        visit path
        assert_selector "[data-testid=top-bar]"
        save_screenshot(Rails.root.join("tmp/screenshots/design-#{name}-#{label}.png"))
      end
    end
  end

  test "the sign-in screen renders at laptop and phone width" do
    [ [ "1440", LAPTOP ], [ "390", PHONE ] ].each do |label, (width, height)|
      resize_to(width, height)
      visit sign_in_path
      assert_selector "[data-testid=sign-in]"
      save_screenshot(Rails.root.join("tmp/screenshots/design-sign-in-#{label}.png"))
    end
  end

  private

  def resize_to(width, height)
    page.driver.browser.manage.window.resize_to(width, height)
  end
end
