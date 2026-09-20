# frozen_string_literal: true

require "application_system_test_case"

# The two layout primitives that only misbehave in a real browser: the fixed
# pending-review tray and the width of a composer or thread inside the reading
# column. Both are pure CSS, both were wrong in ways every assertion passed
# through, so these measure geometry rather than presence.
class TrayLayoutTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  PATH = "docs/guide.md"
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA

  # Long enough that the page scrolls at a laptop height, which is the only
  # state where a fixed tray can hide the end of the document.
  HEAD = ([ "# Guide", "" ] + (1..40).flat_map { |i| [ "Paragraph #{i} of a deliberately long file.", "" ] }).join("\n")
  PATCH = ([ "@@ -1,1 +1,82 @@", " # Guide" ] + (1..81).map { "+" }).join("\n")

  setup do
    @user = users(:prism_dev)

    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER, files_body: files_json)
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_contents(PATH, HEAD_SHA, HEAD, owner: OWNER, repo: REPO)

    # A pending review already in flight, so the tray renders on first load.
    draft = feature_thread(
      node_id: "PRRT_draft", path: PATH, line: 3,
      comments: [ feature_comment(node_id: "PRRC_draft", body: "A draft comment.", state: "PENDING",
                                  author_login: "prism-dev") ]
    )
    stub_feature_reviews_sequence([ pending_review_json ])
    stub_feature_review_threads([ draft ])

    sign_in_for_feature(@user)
  end

  # The tray's height is content, not a constant, so the floor that keeps it
  # off the document has to be at least as tall as the tray actually renders.
  # `--tray-height` is hand-set; this is what stops it drifting.
  test "the page floor is at least as tall as the tray, at laptop and phone width" do
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=pending-tray]"

    [ [ 1440, 900 ], [ 390, 844 ] ].each do |width, height|
      resize_window(width, height)
      assert_selector "[data-testid=pending-tray]"

      measured = page.evaluate_script(<<~JS)
        (function () {
          var tray = document.querySelector("[data-testid=pending-tray] .tray") ||
                     document.querySelector(".tray");
          var main = document.querySelector("main");
          return {
            tray: Math.ceil(tray.getBoundingClientRect().height),
            floor: Math.round(parseFloat(getComputedStyle(main).paddingBottom)),
            position: getComputedStyle(tray).position
          };
        })()
      JS

      assert_equal "fixed", measured["position"],
                   "the tray must be fixed; sticky only pins it at the very bottom of the page"
      assert_operator measured["floor"], :>=, measured["tray"],
                      "at #{width}px the tray is #{measured['tray']}px but the page floor is " \
                      "#{measured['floor']}px — raise --tray-height, the tray covers the document"
    end
  end

  # The failure this catches is invisible: the document still ends, it just
  # ends underneath the bar.
  test "scrolled to the end of a long file, the last block clears the tray" do
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=pending-tray]"

    [ [ 1440, 900 ], [ 390, 844 ] ].each do |width, height|
      resize_window(width, height)
      page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight)")

      measured = page.evaluate_script(<<~JS)
        (function () {
          var blocks = document.querySelectorAll("[data-testid=md-block]");
          var last = blocks[blocks.length - 1];
          var tray = document.querySelector(".tray");
          return {
            scrollable: document.documentElement.scrollHeight > window.innerHeight,
            lastBottom: Math.round(last.getBoundingClientRect().bottom),
            trayTop: Math.round(tray.getBoundingClientRect().top)
          };
        })()
      JS

      assert measured["scrollable"], "the fixture file needs to be long enough to scroll at #{height}px"
      assert_operator measured["lastBottom"], :<=, measured["trayTop"],
                      "at #{width}px the last block ends #{measured['lastBottom']}px down but the " \
                      "tray starts at #{measured['trayTop']}px — the end of the file is hidden"
    end
  end

  # Everything in the body column is one width — prose, tables, threads and
  # the composer alike. Prose used to stop at a 72ch reading measure while the
  # rest ran full width, so a document rendered at two widths and a paragraph
  # visibly widened the moment a composer opened under it.
  test "prose and threads are both the full width of the body column" do
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    assert_selector ".thread"

    measured = page.evaluate_script(<<~JS)
      (function () {
        var card = document.querySelector(".thread");
        var thread = card.closest(".md-threads") || card.parentElement;
        var body = thread.closest(".md-body");
        // The prose paragraph of the block itself, not one inside the thread.
        var para = Array.prototype.find.call(body.children, function (el) {
          return el.tagName === "P";
        });
        return {
          thread: Math.round(thread.getBoundingClientRect().width),
          body: Math.round(body.clientWidth),
          paddingLeft: Math.round(parseFloat(getComputedStyle(body).paddingLeft)),
          paddingRight: Math.round(parseFloat(getComputedStyle(body).paddingRight)),
          para: para ? Math.round(para.getBoundingClientRect().width) : null,
          bodyChildren: Array.prototype.map.call(body.children, function (el) {
            return el.tagName + "." + (el.className || "");
          }).join(" ")
        };
      })()
    JS

    available = measured["body"] - measured["paddingLeft"] - measured["paddingRight"]

    assert_in_delta available, measured["thread"], 1,
                    "the thread is #{measured['thread']}px inside a #{available}px column — " \
                    "it is still capped at the reading measure"

    # And the prose beside it is the same width, not a narrower measure — this
    # is the assertion that fails if a reading cap is ever reintroduced.
    assert measured["para"].present?,
           "no paragraph in the block body to compare against: #{measured['bodyChildren']}"
    assert_in_delta available, measured["para"], 1,
                    "prose is #{measured['para']}px inside a #{available}px column — " \
                    "something is capping it again"
  end

  private

  def pending_review_json
    { "id" => 80_002, "node_id" => "PRR_pending", "state" => "PENDING", "body" => nil,
      "submitted_at" => nil, "commit_id" => HEAD_SHA,
      "html_url" => "https://github.com/#{OWNER}/#{REPO}/pull/#{NUMBER}",
      "user" => { "login" => "prism-dev", "id" => 4242,
                  "avatar_url" => "https://avatars.githubusercontent.com/u/4242?v=4",
                  "html_url" => "https://github.com/prism-dev", "type" => "User" } }
  end

  def files_json
    [ { "filename" => PATH, "status" => "modified", "additions" => 81, "deletions" => 0,
        "patch" => PATCH,
        "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" } ]
  end
end
