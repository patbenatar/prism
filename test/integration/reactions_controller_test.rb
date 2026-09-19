# frozen_string_literal: true

require "test_helper"

# ReactionsController: add / remove a reaction, entirely over GraphQL.
class ReactionsControllerTest < ActionDispatch::IntegrationTest
  OWNER = "acme"
  REPO = "docs-site"
  NUMBER = 42
  COMMENT_ID = "PRRC_kwDOABCD12MAAAABc9AA"

  setup { @user = users(:prism_dev) }

  test "signed out, create redirects to sign in" do
    post repo_pull_comment_reactions_path(owner: OWNER, repo: REPO, number: NUMBER, id: COMMENT_ID),
         params: { content: "+1" }

    assert_redirected_to sign_in_path
  end

  test "create adds a reaction via addReaction, mapping REST content to the GraphQL enum" do
    sign_in_as(@user)
    stub_github_graphql(:AddReaction, data: { addReaction: { subject: comment_data(reacted: true) } })

    post repo_pull_comment_reactions_path(owner: OWNER, repo: REPO, number: NUMBER, id: COMMENT_ID),
         params: { content: "+1", thread_id: "PRRT_1" }, as: :turbo_stream

    assert_response :success
    assert_github_graphql(:AddReaction) do |variables|
      variables["input"]["subjectId"] == COMMENT_ID && variables["input"]["content"] == "THUMBS_UP"
    end
    assert_match(/turbo-stream action="replace" target="comment_#{COMMENT_ID}"/, response.body)
  end

  test "destroy removes a reaction via removeReaction" do
    sign_in_as(@user)
    stub_github_graphql(:RemoveReaction, data: { removeReaction: { subject: comment_data(reacted: false) } })

    delete repo_pull_comment_reaction_path(owner: OWNER, repo: REPO, number: NUMBER, id: COMMENT_ID, reaction_id: "ignored"),
           params: { content: "heart", thread_id: "PRRT_1" }, as: :turbo_stream

    assert_response :success
    assert_github_graphql(:RemoveReaction) do |variables|
      variables["input"]["subjectId"] == COMMENT_ID && variables["input"]["content"] == "HEART"
    end
  end

  test "reacting to a comment GitHub can no longer find replaces that comment, not the whole page" do
    sign_in_as(@user)
    stub_github_graphql(:AddReaction, errors: [ { "message" => "Could not resolve to a node.", "type" => "NOT_FOUND" } ])

    post repo_pull_comment_reactions_path(owner: OWNER, repo: REPO, number: NUMBER, id: COMMENT_ID),
         params: { content: "+1", thread_id: "PRRT_1" }, as: :turbo_stream

    assert_response :not_found
    assert_match(/turbo-stream action="replace" target="comment_#{COMMENT_ID}"/, response.body)
  end

  test "reacting on a repository GitHub forbids replaces that comment with the reason" do
    sign_in_as(@user)
    stub_github_graphql(:AddReaction, errors: [ { "message" => "Resource not accessible", "type" => "FORBIDDEN" } ])

    post repo_pull_comment_reactions_path(owner: OWNER, repo: REPO, number: NUMBER, id: COMMENT_ID),
         params: { content: "+1", thread_id: "PRRT_1" }, as: :turbo_stream

    assert_response :forbidden
    assert_match(/turbo-stream action="replace" target="comment_#{COMMENT_ID}"/, response.body)
  end

  private

  def comment_data(reacted:)
    {
      id: COMMENT_ID, databaseId: 900001, body: "Hi", bodyHTML: "<p>Hi</p>", state: "SUBMITTED",
      createdAt: "2026-09-17T11:00:00Z", url: "https://github.com/x", diffHunk: "", outdated: false,
      viewerCanUpdate: false, viewerCanDelete: false, viewerCanReact: true,
      author: { login: "octocat", avatarUrl: "https://x", url: "https://github.com/octocat" },
      replyTo: nil,
      reactionGroups: [ { content: "THUMBS_UP", viewerHasReacted: reacted, reactors: { totalCount: reacted ? 1 : 0 } } ]
    }
  end
end
