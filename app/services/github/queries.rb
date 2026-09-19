# frozen_string_literal: true

module Github
  # The GraphQL documents Github::Client sends, kept out of the client so the
  # client reads as a list of operations rather than a wall of query text.
  #
  # Every mutation takes its whole input object as a single `$input` variable
  # rather than one variable per field. That is what lets an anchor omit keys it
  # does not have: GitHub applies the schema defaults for `side`, `startSide`
  # and `subjectType` only when the field is absent, and passing an explicit
  # null instead would override the default with null.
  module Queries
    # Everything the UI needs about one comment. `databaseId` is the REST id,
    # which replies and reactions over REST would need; `bodyHTML` is GitHub's
    # own rendering with @-mentions and issue references already linked, which
    # saves a POST /markdown per comment.
    COMMENT_FIELDS = <<~GRAPHQL
      fragment CommentFields on PullRequestReviewComment {
        id
        databaseId
        body
        bodyHTML
        state
        createdAt
        url
        diffHunk
        outdated
        viewerCanUpdate
        viewerCanDelete
        viewerCanReact
        author { login avatarUrl url }
        replyTo { id }
        reactionGroups {
          content
          viewerHasReacted
          reactors { totalCount }
        }
      }
    GRAPHQL

    THREAD_FIELDS = <<~GRAPHQL
      fragment ThreadFields on PullRequestReviewThread {
        id
        path
        line
        originalLine
        startLine
        originalStartLine
        diffSide
        startDiffSide
        subjectType
        isResolved
        isOutdated
        viewerCanResolve
        viewerCanUnresolve
        viewerCanReply
        resolvedBy { login }
        comments(first: 100) {
          pageInfo { hasNextPage endCursor }
          nodes { ...CommentFields }
        }
      }
    GRAPHQL

    # One call gives us the pull request's node id (needed by every write) and a
    # page of threads with their comments.
    REVIEW_THREADS = <<~GRAPHQL + THREAD_FIELDS + COMMENT_FIELDS
      query ReviewThreads($owner: String!, $name: String!, $number: Int!, $cursor: String) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            id
            reviewThreads(first: 50, after: $cursor) {
              pageInfo { hasNextPage endCursor }
              nodes { ...ThreadFields }
            }
          }
        }
      }
    GRAPHQL

    # Follow-up for the rare thread with more than 100 comments.
    THREAD_COMMENTS = <<~GRAPHQL + COMMENT_FIELDS
      query ThreadComments($threadId: ID!, $cursor: String) {
        node(id: $threadId) {
          ... on PullRequestReviewThread {
            id
            comments(first: 100, after: $cursor) {
              pageInfo { hasNextPage endCursor }
              nodes { ...CommentFields }
            }
          }
        }
      }
    GRAPHQL

    # Used both for a comment posted immediately (input carries pullRequestId)
    # and for a draft added to a pending review (input carries
    # pullRequestReviewId). Passing both would be ambiguous, so the client sets
    # exactly one.
    ADD_THREAD = <<~GRAPHQL + THREAD_FIELDS + COMMENT_FIELDS
      mutation AddThread($input: AddPullRequestReviewThreadInput!) {
        addPullRequestReviewThread(input: $input) {
          thread { ...ThreadFields }
        }
      }
    GRAPHQL

    ADD_THREAD_REPLY = <<~GRAPHQL + COMMENT_FIELDS
      mutation AddThreadReply($input: AddPullRequestReviewThreadReplyInput!) {
        addPullRequestReviewThreadReply(input: $input) {
          comment { ...CommentFields }
        }
      }
    GRAPHQL

    # Works on a submitted comment and on a pending draft alike, which the REST
    # PATCH does not reliably do.
    UPDATE_COMMENT = <<~GRAPHQL + COMMENT_FIELDS
      mutation UpdateComment($input: UpdatePullRequestReviewCommentInput!) {
        updatePullRequestReviewComment(input: $input) {
          pullRequestReviewComment { ...CommentFields }
        }
      }
    GRAPHQL

    DELETE_COMMENT = <<~GRAPHQL
      mutation DeleteComment($input: DeletePullRequestReviewCommentInput!) {
        deletePullRequestReviewComment(input: $input) {
          pullRequestReviewComment { id }
        }
      }
    GRAPHQL

    RESOLVE_THREAD = <<~GRAPHQL + THREAD_FIELDS + COMMENT_FIELDS
      mutation ResolveThread($input: ResolveReviewThreadInput!) {
        resolveReviewThread(input: $input) {
          thread { ...ThreadFields }
        }
      }
    GRAPHQL

    UNRESOLVE_THREAD = <<~GRAPHQL + THREAD_FIELDS + COMMENT_FIELDS
      mutation UnresolveThread($input: UnresolveReviewThreadInput!) {
        unresolveReviewThread(input: $input) {
          thread { ...ThreadFields }
        }
      }
    GRAPHQL

    # Returning the whole comment means the caller can re-render the reaction row
    # from the mutation's own response instead of refetching the thread.
    ADD_REACTION = <<~GRAPHQL + COMMENT_FIELDS
      mutation AddReaction($input: AddReactionInput!) {
        addReaction(input: $input) {
          subject { ...CommentFields }
        }
      }
    GRAPHQL

    REMOVE_REACTION = <<~GRAPHQL + COMMENT_FIELDS
      mutation RemoveReaction($input: RemoveReactionInput!) {
        removeReaction(input: $input) {
          subject { ...CommentFields }
        }
      }
    GRAPHQL
  end
end
