# frozen_string_literal: true

require "application_system_test_case"

# The commenting components repeat — once per comment, once per thread, once
# per file, plus a cloned composer for every one a reviewer opens — and the
# Markdown tab puts every file in the pull request on a single page. So an id
# that is unique in one comment card is a duplicate the moment there are two.
#
# `form_with` names its fields for you (`id="path"`, `id="thread_id"`,
# `id="body"`), which is exactly the trap: nothing in Prism reads them, so
# duplicates are inert right up until the first `getElementById` — and by then
# the page has been invalid HTML for months. The partials pass `id: nil`; this
# is what keeps them doing it.
#
# Written against the whole document rather than the components, because a
# duplicate is a property of the page: a second file, a second thread or a
# second open composer is what creates one.
class CommentComponentIdsTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  PATH = "docs/guide.md"
  OTHER_PATH = "docs/appendix.md"
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA

  HEAD = <<~MARKDOWN
    # Guide

    This paragraph is brand new.
  MARKDOWN

  OTHER_HEAD = <<~MARKDOWN
    # Appendix

    Another new paragraph, in a second file.
  MARKDOWN

  PATCH = [ "@@ -1,1 +1,3 @@", " # Guide", "+", "+This paragraph is brand new." ].join("\n")
  OTHER_PATCH = [ "@@ -0,0 +1,3 @@", "+# Appendix", "+", "+Another new paragraph, in a second file." ].join("\n")

  setup do
    @user = users(:prism_dev)

    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER, files_body: files_json,
                              reviews_body: [])
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_contents(PATH, HEAD_SHA, HEAD, owner: OWNER, repo: REPO)
    stub_feature_contents(OTHER_PATH, HEAD_SHA, OTHER_HEAD, owner: OWNER, repo: REPO)

    # A thread on each file, so the page carries two reply boxes and two edit
    # forms (both panes of a comment render up front) before anything is even
    # clicked.
    stub_feature_review_threads([ thread_on(PATH, "PRRT_guide", "PRRC_guide"),
                                  thread_on(OTHER_PATH, "PRRT_appendix", "PRRC_appendix") ])

    sign_in_for_feature(@user)
  end

  test "no element id repeats, with two files, two threads and two open composers" do
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=thread]", count: 2

    assert_no_duplicate_ids "on load"

    # One composer per file. `composer_controller` closes the previous
    # composer within its own scope, and each file's section is its own
    # scope, so these two stay open together — which is the case that first
    # turned the template's ids into duplicates.
    blocks = all("[data-testid=md-block][data-commentable=true]")
    opened = blocks.filter_map do |block|
      section = block.find(:xpath, "ancestor::section[1]")["id"]
      next if @seen_sections&.include?(section)

      (@seen_sections ||= []) << section
      open_composer_for(block)
    end

    assert_operator opened.size, :>=, 2, "expected a commentable block in each of the two files"
    assert_selector "[data-testid=composer]", count: opened.size

    assert_no_duplicate_ids "with #{opened.size} composers open"

    # And with an edit form swapped in for a comment's body, which is the
    # third copy of the same field names.
    find("[data-testid=comment-edit]", match: :first).click
    assert_selector "[data-testid=comment-edit-textarea]"

    assert_no_duplicate_ids "while editing a comment"
  end

  private

  # Reports every repeated id with its count, so a failure names the field
  # rather than just the fact.
  def assert_no_duplicate_ids(context)
    duplicates = page.evaluate_script(<<~JS)
      (() => {
        const counts = {};
        document.querySelectorAll("[id]").forEach((el) => {
          counts[el.id] = (counts[el.id] || 0) + 1;
        });
        return Object.entries(counts)
          .filter(([, count]) => count > 1)
          .map(([id, count]) => `${id} (${count})`);
      })()
    JS

    assert_empty duplicates,
                 "duplicate element ids #{context}: #{duplicates.join(', ')}"
  end

  def thread_on(path, thread_node_id, comment_node_id)
    feature_thread(node_id: thread_node_id, path: path, line: 3,
                   comments: [ feature_comment(node_id: comment_node_id, body: "A comment on #{path}.",
                                                author_login: "prism-dev",
                                                viewer_can_update: true, viewer_can_delete: true) ])
  end

  def files_json
    [ { "filename" => PATH, "status" => "modified", "additions" => 2, "deletions" => 0, "changes" => 2,
        "patch" => PATCH,
        "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" },
      { "filename" => OTHER_PATH, "status" => "added", "additions" => 3, "deletions" => 0, "changes" => 3,
        "patch" => OTHER_PATCH,
        "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{OTHER_PATH}" } ].to_json
  end
end
