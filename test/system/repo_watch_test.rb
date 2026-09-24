# frozen_string_literal: true

require "application_system_test_case"

# Watching a repository from the repository's own page — the screen someone
# is actually on when they decide they want it.
#
# Driven through the browser because the whole point of the control is that
# it flips in place: a Turbo Stream aimed at an id that isn't there, or a
# failure that redirects away instead of explaining itself where it happened,
# both look fine in an integration test. The confirmation dialog is the other
# half — `showModal()`, focus and Escape only exist in a real browser.
class RepoWatchSystemTest < ApplicationSystemTestCase
  OWNER = "acme"
  REPO  = "docs-site"
  CALLBACK = "https://prism.test/webhooks/github"

  setup do
    @user = users(:prism_dev)
    ENV["PRISM_PUBLIC_URL"] = "https://prism.test"
    # Signing in lands on /repos before any test navigates anywhere.
    stub_github_get("/user/repos", fixture: :repos)
    sign_in_as @user
  end

  teardown { ENV.delete("PRISM_PUBLIC_URL") }

  test "watching a repository from its pull request list flips the control in place" do
    stub_pulls("acme", "new-docs")
    stub_github_post("/repos/acme/new-docs/hooks", body: hook_payload(id: 9001))

    visit repo_pulls_path(owner: "acme", repo: "new-docs")
    mark_page

    # The consent is said before anything happens, and it names the
    # repository: Prism is about to write into its pull requests under this
    # person's name.
    open_watch_dialog

    within "[data-testid=watch-dialog]" do
      assert_selector "h2", text: "Watch acme/new-docs?"
      assert_text "Prism edits the pull request's description"
      assert_text "coming from your account, @prism-dev"
      assert_text "deleting the block"
      assert_text "admin access"
    end

    find("[data-testid=watch-confirm]").click

    within "[data-testid=repo-watch]" do
      assert_selector "[data-testid=repo-watch-state]", text: "Watching"
      assert_no_selector "[data-testid=repo-watch-button]"
    end

    assert page_never_reloaded?, "the control should have been streamed in, not the whole page"
    assert_equal CALLBACK, github_request_body(:post, "/repos/acme/new-docs/hooks").dig("config", "url")
    assert_no_csp_violations
  end

  test "the confirmation cancels on Escape, on Cancel and on the backdrop, and nothing is watched" do
    stub_pulls("acme", "new-docs")

    visit repo_pulls_path(owner: "acme", repo: "new-docs")

    # Escape.
    open_watch_dialog

    assert focus_inside_dialog?, "focus should land inside the dialog, on the button that commits"
    assert_equal "watch-confirm", focused_testid

    page.send_keys(:escape)
    assert_dialog_closed
    assert_equal "repo-watch-button", focused_testid, "focus should come back to the trigger"

    # Cancel.
    open_watch_dialog
    find("[data-testid=watch-cancel]").click
    assert_dialog_closed
    assert_equal "repo-watch-button", focused_testid, "focus should come back to the trigger"

    # The backdrop — a click outside the panel, which the browser reports as
    # a click on the dialog itself.
    open_watch_dialog
    click_top_left_corner
    assert_dialog_closed

    assert_selector "[data-testid=repo-watch-button]"
    assert_empty WebhookSubscription.named("acme", "new-docs")
    assert_not_requested :post, /api\.github\.com/
    assert_no_csp_violations
  end

  test "the consent copy is not on the page until the dialog is opened" do
    stub_pulls("acme", "new-docs")

    visit repo_pulls_path(owner: "acme", repo: "new-docs")

    # Capybara only sees what a screen reader would: a closed <dialog> is
    # `display: none`, so none of this is exposed until it is asked for.
    assert_no_selector "[data-testid=watch-dialog]"
    assert_no_text "coming from your account"
    assert_no_text "Watch acme/new-docs?"

    open_watch_dialog

    assert_text "coming from your account"
  end

  test "a repository already being watched says so on arrival, and can be stopped from here" do
    stub_pulls
    stub_github_delete("/repos/#{OWNER}/#{REPO}/hooks/555")

    visit repo_pulls_path(owner: OWNER, repo: REPO)

    # The state is the control: one button, saying what Prism is doing.
    assert_selector "[data-testid=repo-watch-state]", text: "Watching"
    assert_no_selector "[data-testid=repo-unwatch-button]", visible: true

    mark_page
    open_watch_menu

    within "[data-testid=repo-watch-menu-panel]" do
      assert_text "Adds a review link to the description of new pull requests that change Markdown"
      assert_text "as @prism-dev"
      assert_text "Prism leaves that one alone"
    end

    # Unwatching is the reversible direction and keeps the browser's own
    # confirm — no dialog of its own.
    accept_confirm { click_on "Stop watching" }

    within "[data-testid=repo-watch]" do
      assert_selector "[data-testid=repo-watch-button]"
      assert_no_text "Watching"
    end

    assert page_never_reloaded?
    assert_requested :delete, "https://api.github.com/repos/#{OWNER}/#{REPO}/hooks/555"
    assert_nil WebhookSubscription.find_by(name: REPO)
  end

  test "watching a repository this account does not administer explains itself next to the button" do
    stub_pulls("acme", "new-docs")
    stub_github_error(:post, "/repos/acme/new-docs/hooks", status: 404, message: "Not Found")

    visit repo_pulls_path(owner: "acme", repo: "new-docs")
    confirm_watch

    within "[data-testid=repo-watch]" do
      assert_selector "[data-testid=repo-watch-error]", text: "You need admin access to acme/new-docs"
      # Still offering the thing that failed — access can be granted and the
      # button tried again.
      assert_selector "[data-testid=repo-watch-button]"
    end

    # The failed attempt replaced the control, dialog and all, so nothing is
    # left open over the page.
    assert_no_selector "[data-testid=watch-dialog]"
    assert_no_selector "[data-testid=flash]"
    assert_no_csp_violations
  end

  test "watching with no public URL configured says which variable is missing" do
    ENV.delete("PRISM_PUBLIC_URL")
    stub_pulls("acme", "new-docs")

    visit repo_pulls_path(owner: "acme", repo: "new-docs")
    confirm_watch

    within "[data-testid=repo-watch]" do
      assert_selector "[data-testid=repo-watch-error]", text: "PRISM_PUBLIC_URL"
      assert_selector "[data-testid=repo-watch-button]"
    end

    assert_not_requested :post, /api\.github\.com/
  end

  test "a moved tunnel is visible here too, and re-registering fixes it in place" do
    ENV["PRISM_PUBLIC_URL"] = "https://a-new-tunnel.ngrok-free.app"
    stub_pulls
    stub_github_patch("/repos/#{OWNER}/#{REPO}/hooks/555",
                      body: hook_payload(id: 555).merge(
                        "config" => { "url" => "https://a-new-tunnel.ngrok-free.app/webhooks/github" }
                      ))

    visit repo_pulls_path(owner: OWNER, repo: REPO)

    within "[data-testid=repo-watch]" do
      assert_selector "[data-testid=repo-watch-state]", text: "Wrong address"
      assert_text "Nothing is arriving"
    end

    open_watch_menu
    click_on "Re-register"

    within "[data-testid=repo-watch]" do
      assert_selector "[data-testid=repo-watch-state]", text: "Watching"
      assert_no_text "Wrong address"
    end
  end

  # Every state the header can be in, at both widths and in both schemes.
  # The four are meant to be one control changing state, so this both looks
  # at them and measures the two things that make them one: they are the
  # same height, and they sit on one row (or, at phone width, wrap into a
  # column whose right edges line up).
  test "the header reads as one row in every state, at 1440 and at 390, light and dark" do
    stub_pulls
    stub_pulls("acme", "new-docs")

    [ [ 1440, 900 ], [ 390, 844 ] ].each do |width, height|
      resize_window(width, height)

      %i[light dark].each do |scheme|
        with_color_scheme(scheme) do
          heights = {}

          heights[:unwatched] = state_shot(width, "unwatched") do
            visit repo_pulls_path(owner: "acme", repo: "new-docs")
            assert_selector "[data-testid=repo-watch-button]"
          end

          heights[:watching] = state_shot(width, "watching") do
            visit repo_pulls_path(owner: OWNER, repo: REPO)
            assert_selector "[data-testid=repo-watch-state]", text: "Watching"
          end

          # Stopping lives inside the state rather than beside it, under a
          # line saying what watching is doing meanwhile.
          open_watch_menu
          assert_text "Adds a review link"
          assert_no_horizontal_overflow
          assert_fully_on_screen("repo-watch-menu-panel", "the watching menu", width)
          take_screenshot

          heights[:broken] = state_shot(width, "not working") do
            webhook_subscriptions(:docs_site).abandon!("GitHub rejected the token")
            visit repo_pulls_path(owner: OWNER, repo: REPO)
            assert_selector "[data-testid=repo-watch-state]", text: "Not working"
          end
          webhook_subscriptions(:docs_site).mark_active!

          heights[:stale] = state_shot(width, "wrong address") do
            ENV["PRISM_PUBLIC_URL"] = "https://a-new-tunnel.ngrok-free.app"
            visit repo_pulls_path(owner: OWNER, repo: REPO)
            assert_selector "[data-testid=repo-watch-state]", text: "Wrong address"
          end

          # An exceptional state's menu is actions only: the reason under the
          # control has already said what is wrong, and repeating what
          # watching does when it works would be padding.
          open_watch_menu
          within "[data-testid=repo-watch-menu-panel]" do
            assert_no_text "Adds a review link"
            assert_selector "[data-testid=repo-re-register-button]"
            assert_selector "[data-testid=repo-unwatch-button]"
          end
          assert_fully_on_screen("repo-watch-menu-panel", "the wrong-address menu", width)
          take_screenshot
          ENV["PRISM_PUBLIC_URL"] = CALLBACK.sub("/webhooks/github", "")

          assert_equal 1, heights.values.uniq.size,
                       "at #{width}px in #{scheme}: the control changes height between states, " \
                       "so the header jumps when someone watches or unwatches — #{heights.inspect}"
        end
      end
    end
  end

  test "the confirmation dialog reads at 1440 and at 390, light and dark" do
    stub_pulls("acme", "new-docs")

    [ [ 1440, 900 ], [ 390, 844 ] ].each do |width, height|
      resize_window(width, height)

      %i[light dark].each do |scheme|
        with_color_scheme(scheme) do
          visit repo_pulls_path(owner: "acme", repo: "new-docs")
          open_watch_dialog
          assert_no_horizontal_overflow
          assert_fully_on_screen("watch-dialog", "the dialog", width)
          take_screenshot
        end
      end
    end
  end

  # DarkModeTest#"no screen paints a pale panel on the dark canvas" already
  # sweeps this screen for hardcoded colours, and the sweep above is the
  # picture of every healthy state. This is the one neither reaches.
  test "a failed attempt reads in dark mode" do
    stub_pulls("acme", "new-docs")
    stub_github_error(:post, "/repos/acme/new-docs/hooks", status: 404, message: "Not Found")

    with_color_scheme(:dark) do
      visit repo_pulls_path(owner: "acme", repo: "new-docs")
      confirm_watch

      assert_selector "[data-testid=repo-watch-error]"
      take_screenshot
    end
  end

  private

  def open_watch_menu
    find("[data-testid=repo-watch-state]").click

    assert_selector "[data-testid=repo-watch-menu-panel]"
  end

  def open_watch_dialog
    find("[data-testid=repo-watch-button]").click

    assert_selector "[data-testid=watch-dialog][open]", text: "coming from your account"
  end

  def confirm_watch
    open_watch_dialog
    find("[data-testid=watch-confirm]").click
  end

  def assert_dialog_closed
    assert_no_selector "[data-testid=watch-dialog]"
    assert_not page.evaluate_script("document.querySelector('[data-testid=watch-dialog]').open")
  end

  def focused_testid = page.evaluate_script("document.activeElement && document.activeElement.dataset.testid")

  def focus_inside_dialog?
    page.evaluate_script(
      "document.querySelector('[data-testid=watch-dialog]').contains(document.activeElement)"
    )
  end

  # The backdrop is not part of the dialog's box, so it cannot be clicked
  # through an element handle — it is a point on the viewport outside the
  # panel. The browser reports the click as landing on the dialog itself,
  # which is what the controller keys on.
  def click_top_left_corner
    page.driver.browser.action.move_to_location(6, 6).click.perform
  end

  # "On screen" is the whole of it, and `elementFromPoint` catches anything
  # painted over it. Used for the modal, which the browser centres, and for
  # the watching menu, which hangs off the control and grew a paragraph.
  def assert_fully_on_screen(testid, label, width)
    box = page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector('[data-testid=#{testid}]');
        const r = el.getBoundingClientRect();
        const topmost = document.elementFromPoint(r.left + r.width / 2, r.top + 8);
        return { left: r.left, right: r.right, top: r.top, bottom: r.bottom,
                 viewportWidth: document.documentElement.clientWidth,
                 viewportHeight: document.documentElement.clientHeight,
                 covered: !el.contains(topmost) };
      })()
    JS

    where = "#{label} at #{width}px"

    assert_operator box["left"], :>=, 0, "#{where}: hangs off the left of the screen"
    assert_operator box["right"], :<=, box["viewportWidth"] + 0.5, "#{where}: hangs off the right of the screen"
    assert_operator box["top"], :>=, 0, "#{where}: runs off the top of the screen"
    assert_operator box["bottom"], :<=, box["viewportHeight"] + 0.5, "#{where}: runs off the bottom of the screen"
    assert_not box["covered"], "#{where}: something is painted over it"
  end

  # Runs the block, checks the header still reads as one row, photographs it,
  # and hands back the height of the control so the states can be compared
  # against each other.
  def state_shot(width, label)
    yield
    assert_no_horizontal_overflow
    assert_header_is_one_row(width, label)
    take_screenshot
    control_height
  end

  # The header's actions are "Open on GitHub" and the watch control, whatever
  # state it is in. One row means they share a top edge. At phone width they
  # are allowed to stack instead — but then their right edges have to line
  # up, or the group reads as debris rather than a column.
  def assert_header_is_one_row(width, label)
    boxes = page.evaluate_script(<<~JS)
      (() => {
        const header = document.querySelector('[data-testid=repo-watch]').closest('header');
        const items = header.querySelectorAll(
          'a.btn-secondary, [data-testid=repo-watch-button], [data-testid=repo-watch-state]'
        );
        return [...items].map(el => {
          const r = el.getBoundingClientRect();
          return { top: r.top, right: r.right };
        });
      })()
    JS

    assert_equal 2, boxes.size, "#{label} at #{width}px: expected Open on GitHub and one watch control"

    tops = boxes.map { |box| box["top"] }
    rights = boxes.map { |box| box["right"] }
    one_row = (tops.max - tops.min) <= 0.5
    aligned_column = (rights.max - rights.min) <= 0.5

    if width >= 640
      assert one_row,
             "#{label} at #{width}px: the header's controls are on #{tops.uniq.size} different lines"
    else
      assert one_row || aligned_column,
             "#{label} at #{width}px: the controls neither share a line nor line up on the right"
    end
  end

  # The control is the form (unwatched) or the <details> (watching): the one
  # element the header holds either way.
  def control_height
    page.evaluate_script(<<~JS).round(1)
      document.querySelector('[data-testid=repo-watch]').firstElementChild.getBoundingClientRect().height
    JS
  end

  def assert_no_horizontal_overflow
    overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")

    assert_operator overflow, :<=, 1, "the page scrolls sideways by #{overflow}px"
  end

  # Turbo replaces one element; a full navigation would throw this away.
  def mark_page = page.execute_script("window.__prismStayed = true")

  def page_never_reloaded? = page.evaluate_script("window.__prismStayed === true")

  def stub_pulls(owner = OWNER, repo = REPO)
    stub_github_get("/repos/#{owner}/#{repo}", body: repo_payload(owner, repo))
    stub_github_get("/repos/#{owner}/#{repo}/pulls", body: [])
  end

  def repo_payload(owner, name, id: 555_001)
    { "id" => id, "name" => name, "full_name" => "#{owner}/#{name}", "private" => false,
      "description" => "Product documentation, written in Markdown.", "default_branch" => "main",
      "pushed_at" => "2026-09-18T16:30:00Z", "open_issues_count" => 0,
      "html_url" => "https://github.com/#{owner}/#{name}",
      "owner" => { "login" => owner, "avatar_url" => "https://example.test/a.png", "type" => "User" } }
  end

  def hook_payload(id:)
    { "id" => id, "type" => "Repository", "name" => "web", "active" => true,
      "events" => [ "pull_request" ],
      "config" => { "url" => CALLBACK, "content_type" => "json", "insecure_ssl" => "0" } }
  end
end
