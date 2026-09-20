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
    @page = clamp_page(params[:page])
    @repos, @next_page = self.class.fetch_repos(github, @page)
    @pinned, @unpinned = PinnedRepo.partition(@repos, current_user)
  end

  # Pulled out as a class method so PinnedReposController can rebuild the same
  # two panels after a pin toggle without duplicating the pagination rules —
  # "load everything up to the page the visitor already had open" is one idea
  # and should have one implementation.
  def self.fetch_repos(github, page)
    pages = (1..page).map { |p| github.repos(page: p) }
    repos = pages.flatten
    next_page = (page + 1 if pages.last.size >= Github::Client::PER_PAGE && page < MAX_PAGES)
    [ repos, next_page ]
  end

  def self.clamp_page(raw)
    page = raw.to_i.clamp(1, MAX_PAGES)
    page.zero? ? 1 : page
  end

  private

  def clamp_page(raw) = self.class.clamp_page(raw)
end
