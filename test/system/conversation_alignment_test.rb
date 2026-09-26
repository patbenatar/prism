# frozen_string_literal: true

require "application_system_test_case"

# Every conversation on a page starts at the same left edge.
#
# A thread renders inside the thing it is about — a list item's own `<li>`, a
# table row's continuation `<tr>` — which is what makes it unambiguous which
# bullet or which row it belongs to, and is not changing. Until 2026-09-26 it
# also meant the conversation inherited that element's indentation, so a
# comment on a nested bullet started 48px right of a comment on the paragraph
# above it, a comment on a table row started inside the table's first-cell
# padding, and no two conversations on a page lined up.
#
# `.md-body` is a container query container now and `.md-child-slots` steps
# back out by `100% - 100cqw` — the accumulated indent, negated, at any depth
# and without anyone counting levels. This measures the real edges in a real
# browser, which is the only place that formula can be wrong.
#
# The outdated thread is measured alongside the anchored ones even though it
# is not in a channel at all. It sits in its own bordered panel, because it
# has no block to be connected to — but a reader does not know that, and a
# conversation 40px left of every other one reads as a bug rather than as
# "this one has no anchor", so the panel takes the channel's geometry.
class ConversationAlignmentTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  PATH = "docs/guide.md"
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA

  # One conversation of every kind the app renders. Five are anchored to a
  # line in this document; the sixth is file-level and the seventh is outdated,
  # which has no line left to be anchored to.
  #   3      paragraph
  #   5      heading
  #  10      a list item two levels deep
  #  16      a table row
  #  18-19   a multi-line block
  DOC = <<~MD
    # Release notes

    Intro paragraph that a reviewer has already commented on.

    ## A heading

    - First item
    - Second item
      - Nested item A
      - Nested item B
    - Third item

    | Col A | Col B |
    | --- | --- |
    | Row one | value one |
    | Row two | value two |

    > A quoted passage
    > across two lines.
  MD

  PATCH = ([ "@@ -1,1 +1,19 @@", " # Release notes" ] + (1..18).map { "+" }).join("\n")

  setup do
    @user = users(:prism_dev)
    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER, files_body: files_json)
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_contents(PATH, HEAD_SHA, DOC, owner: OWNER, repo: REPO)
    stub_feature_reviews_sequence([])
    stub_feature_review_threads(threads)
    sign_in_for_feature(@user)
  end

  test "every conversation shares one left and right edge, whatever it is anchored to" do
    [ [ 1440, 900 ], [ 390, 844 ] ].each do |width, height|
      resize_window(width, height)
      open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
      # The outdated panel is a closed <details>, so its thread has no layout
      # box until it is opened.
      first("[data-testid=outdated-threads] summary").click

      edges = thread_edges

      assert_equal 7, edges.size,
                   "expected one conversation of each anchor kind at #{width}px, got " \
                   "#{edges.size}: #{edges.inspect}"
      assert_equal 1, edges.values.map { |e| e["left"] }.uniq.size,
                   "at #{width}px the conversations start at different left edges: #{edges.inspect}"
      assert_equal 1, edges.values.map { |e| e["right"] }.uniq.size,
                   "at #{width}px the conversations end at different right edges: #{edges.inspect}"
    end
  end

  # The one that would silently come back: a thread still has to be inside the
  # element it is about, or the reader loses which bullet or which row it
  # belongs to. The alignment is done with margins, not by moving the DOM.
  test "a nested list item's conversation is still inside that list item" do
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    anchor = page.evaluate_script(<<~JS)
      (function () {
        var thread = document.querySelector("#thread_PRRT_nested");
        var item = thread.closest("li[data-block-id]");
        var row = document.querySelector("#thread_PRRT_row").closest("tr");
        return {
          item: item ? item.textContent.replace(/\\s+/g, " ").trim() : null,
          depth: item ? item.querySelectorAll("li").length : null,
          rowIsThreadRow: !!(row && row.classList.contains("md-thread-row")),
          rowFollows: !!(row && row.previousElementSibling &&
                         row.previousElementSibling.textContent.indexOf("Row two") !== -1)
        };
      })()
    JS

    assert_includes anchor["item"].to_s, "Nested item B",
                    "the nested item's conversation is no longer inside its own <li>"
    assert_equal 0, anchor["depth"], "it landed in the outer list item, not the nested one"
    assert anchor["rowIsThreadRow"], "the table row's conversation left its continuation row"
    assert anchor["rowFollows"], "the table row's conversation is not directly under Row two"
  end

  private

  # The `.thread` element's own box, not its container's.
  #
  # Measuring the container would compare a channel's *border* against the
  # outdated panel's *content*, which are 17px apart — an apples-to-oranges
  # comparison that hid a 40px mismatch until 2026-09-26. The thread's own box
  # is what a reader sees the comment start at, and every conversation on the
  # page has one whether or not it sits in a channel.
  def thread_edges
    page.evaluate_script(<<~JS)
      (function () {
        var edges = {};
        document.querySelectorAll("[data-testid=thread]").forEach(function (thread) {
          var r = thread.getBoundingClientRect();
          edges[thread.id] = { left: Math.round(r.left), right: Math.round(r.right) };
        });
        return edges;
      })()
    JS
  end

  def threads
    [
      feature_thread(node_id: "PRRT_para", path: PATH, line: 3,
                     comments: [ feature_comment(node_id: "PRRC_p", body: "On the paragraph.") ]),
      feature_thread(node_id: "PRRT_heading", path: PATH, line: 5,
                     comments: [ feature_comment(node_id: "PRRC_h", body: "On the heading.") ]),
      feature_thread(node_id: "PRRT_nested", path: PATH, line: 10,
                     comments: [ feature_comment(node_id: "PRRC_n", body: "On a nested bullet.") ]),
      feature_thread(node_id: "PRRT_row", path: PATH, line: 16,
                     comments: [ feature_comment(node_id: "PRRC_r", body: "On a table row.") ]),
      feature_thread(node_id: "PRRT_multi", path: PATH, line: 19, start_line: 18,
                     comments: [ feature_comment(node_id: "PRRC_m", body: "On both quoted lines.") ]),
      feature_thread(node_id: "PRRT_file", path: PATH, subject_type: "FILE",
                     comments: [ feature_comment(node_id: "PRRC_f", body: "On the file.") ]),
      # Not anchored to anything on the page, so it renders in the outdated
      # panel rather than in a channel. It is in this list because a reader
      # cannot tell that from looking: a conversation 40px left of every other
      # one reads as a bug, not as "this one has no anchor".
      feature_thread(node_id: "PRRT_outdated", path: PATH, line: nil, original_line: 42,
                     outdated: true,
                     comments: [ feature_comment(node_id: "PRRC_o", body: "No longer applies.",
                                                 diff_hunk: "@@ -40,3 +40,3 @@\n-old\n+new") ])
    ]
  end

  def files_json
    [ { "filename" => PATH, "status" => "modified", "additions" => 18, "deletions" => 0,
        "patch" => PATCH,
        "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" } ]
  end
end
