# frozen_string_literal: true

require "application_system_test_case"

# The two autocomplete menus, open, at laptop and phone width in both colour
# schemes — saved to tmp/screenshots so the pair can be looked at side by side.
#
# Same job as ThemeScreenshotsTest, for the one piece of UI that only exists
# while a key is held down and so never appears in a screen-level shot. It
# still asserts the menu rendered, so a broken listbox fails here too, but the
# point is the PNGs: a contrast table cannot say whether a row of avatar,
# login and real name reads as one line at 390px.
#
# Named `autocomplete-<trigger>-<width>-<light|dark>.png`.
class AutocompleteScreenshotsTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  PATH = "docs/guide.md"
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA

  LAPTOP = [ 1440, 1000 ].freeze
  PHONE = [ 390, 844 ].freeze

  HEAD = <<~MARKDOWN
    # Guide

    This paragraph is brand new.
  MARKDOWN

  PATCH = [ "@@ -1,1 +1,3 @@", " # Guide", "+", "+This paragraph is brand new." ].join("\n")

  setup do
    @user = users(:prism_dev)

    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER, files_body: files_json,
                              reviews_body: [])
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_feature_references(owner: OWNER, repo: REPO)
    stub_feature_contents(PATH, HEAD_SHA, HEAD, owner: OWNER, repo: REPO)
    stub_feature_review_threads([])

    sign_in_for_feature(@user)
  end

  test "both autocomplete menus at 1440 and 390, light and dark" do
    { "laptop" => LAPTOP, "phone" => PHONE }.each do |width_name, size|
      each_theme do |theme|
        resize_window(*size)
        open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
        block_id = open_first_composer

        within "#composer_#{block_id}" do
          area = find("textarea", match: :first)

          area.click
          area.send_keys("Nice work @o")
          assert_selector "[role=listbox] [role=option]", wait: 5
          shoot("mention-#{width_name}", theme)

          area.send_keys([ :control, "a" ], "Superseded by #")
          assert_selector "[role=listbox] [role=option]", minimum: 4, wait: 5
          shoot("reference-#{width_name}", theme)
        end
      end
    end
  end

  private

  # This test loads the same page four times over, and a Turbo navigation can
  # leave the outgoing page's blocks on screen for a moment — long enough for
  # the "+" to be clicked on a block that is about to be replaced, which opens
  # nothing. Retry until the composer the click was meant to open is real.
  def open_first_composer
    3.times do
      block = find("[data-testid=md-block][data-commentable=true]", match: :first)
      block_id = block["data-block-id"]
      block.hover
      block.find(".md-add", match: :first).click

      return block_id if has_selector?("#composer_#{block_id} textarea", wait: 3)
    end

    flunk "the composer never opened"
  end

  def each_theme
    yield "light"
    with_color_scheme(:dark) { yield "dark" }
  end

  def shoot(name, theme)
    save_screenshot(Rails.root.join("tmp/screenshots/autocomplete-#{name}-#{theme}.png"))
  end

  def files_json
    [ { "filename" => PATH, "status" => "modified", "additions" => 2, "deletions" => 0, "changes" => 2,
        "patch" => PATCH, "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" } ].to_json
  end
end
