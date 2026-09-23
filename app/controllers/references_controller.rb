# frozen_string_literal: true

# JSON for the `#` autocomplete: the repository's issues and pull requests.
# Sibling of MentionablesController, and deliberately shaped like it — same
# degradation, same absence of jbuilder (skipped at scaffold time), so
# `render json:` builds the payload by hand.
class ReferencesController < ApplicationController
  # Deliberately not Github::Unauthorized: a dead token must still sign the
  # user out through Authentication#handle_revoked_token, not disappear into
  # an empty list.
  rescue_from Github::Forbidden, Github::NotFound, Github::RateLimited,
              Github::GraphQLError, Github::Unavailable, Github::Unprocessable,
              with: :render_empty

  def index
    items = github.references(params[:owner], params[:repo])

    render json: items.map { |item|
      { number: item.number, title: item.title, kind: item.kind, status: item.status }
    }
  end

  private

  # Same reasoning as MentionablesController#render_empty: `#123` is resolved
  # by GitHub when it renders the comment, not by us when we suggest it, so a
  # rate limit or a repository with issues disabled costs the reviewer a menu,
  # never the reference.
  def render_empty(_error)
    render json: []
  end
end
