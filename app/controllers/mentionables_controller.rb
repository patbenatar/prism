# frozen_string_literal: true

# JSON for the @-mention autocomplete. No jbuilder in this app (skipped at
# scaffold time), so this renders `render json:` directly.
class MentionablesController < ApplicationController
  # Deliberately not Github::Unauthorized: a dead token must still sign the
  # user out through Authentication#handle_revoked_token, not disappear into
  # an empty list.
  rescue_from Github::Forbidden, Github::NotFound, Github::RateLimited,
              Github::GraphQLError, Github::Unavailable, Github::Unprocessable,
              with: :render_empty

  def index
    owner = params[:owner]
    repo = params[:repo]

    people = github.mentionables(owner, repo)

    render json: people.map { |person| { login: person.login, name: person.name, avatar_url: person.avatar_url } }
  end

  private

  # The autocomplete is a convenience, not a correctness surface (GitHub does
  # not validate mentions on write) — a rate limit or transient GitHub failure
  # should not break typing a comment, so this degrades to an empty list
  # instead of a 500.
  def render_empty(_error)
    render json: []
  end
end
