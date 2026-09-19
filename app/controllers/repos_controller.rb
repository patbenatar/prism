# frozen_string_literal: true

# The repository list — the first screen after signing in.
class ReposController < ApplicationController
  include GithubErrorHandling

  # GitHub returns 100 repositories per page, sorted by most recent push. One
  # page is enough for almost everyone, and it is small enough to search in the
  # browser (see the `filter` Stimulus controller) with no round trip.
  #
  # "Load more" raises `?page=`, and we re-fetch every page up to it so the list
  # grows instead of jumping. The pages are cached for a minute each, so the
  # extra requests cost nothing on a second click. The ceiling keeps a runaway
  # URL from turning into an unbounded fan-out of GitHub calls.
  MAX_PAGES = 5

  def index
    @page = params[:page].to_i.clamp(1, MAX_PAGES)
    @page = 1 if @page.zero?

    pages = (1..@page).map { |page| github.repos(page: page) }
    @repos = pages.flatten
    @next_page = (@page + 1 if pages.last.size >= Github::Client::PER_PAGE && @page < MAX_PAGES)
  end
end
