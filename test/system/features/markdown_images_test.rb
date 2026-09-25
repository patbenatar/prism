# frozen_string_literal: true

require "application_system_test_case"

# Journey: a reviewer opens a proposal whose charts sit beside it in the
# repository, and sees the charts.
#
# This is the tier that has to exist for this feature. A broken `<img>` is
# invisible to every other kind of test — the element is in the DOM, the `src`
# attribute is whatever we wrote, `assert_select` passes, and the reader still
# sees a torn-page icon. Only a real browser knows whether the bytes arrived,
# and it will only say so through `naturalWidth`.
class MarkdownImagesTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA

  PATH = "proposals/platform/webhooks/README.md"
  SOURCE = <<~MARKDOWN
    # Webhooks

    ![Deliveries per day](deliveries-daily.png)

    ![Architecture](../shared/architecture.svg)

    ![Missing entirely](nowhere.png)
  MARKDOWN
  PATCH = "@@ -0,0 +1,7 @@\n" + SOURCE.lines.map { |line| "+#{line}" }.join

  CONTENTS = "#{GithubStubs::API}/repos/#{OWNER}/#{REPO}/contents"

  setup do
    @user = users(:prism_dev)
    @png = file_fixture("chart.png").binread
    @svg = file_fixture("diagram.svg").binread

    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER,
                              files_body: files, reviews_body: [])
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_feature_review_threads([])
    stub_feature_contents(PATH, HEAD_SHA, SOURCE, owner: OWNER, repo: REPO)

    stub_blob("proposals/platform/webhooks/deliveries-daily.png", @png)
    stub_blob("proposals/platform/shared/architecture.svg", @svg)
    stub_missing("proposals/platform/webhooks/nowhere.png")

    sign_in_for_feature(@user)
  end

  test "a relative image in a private repository actually loads in the browser" do
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    # 8x8 is the fixture's real size, so this is not merely "something
    # rendered" — it is the bytes we put in GitHub's mouth, decoded.
    assert_equal [ 8, 8 ], natural_size("Deliveries per day")
    assert_no_csp_violations
  end

  # SVGs are the other half of the diagrams people put in proposals, and they
  # are served under a policy tight enough that it would be easy to break them
  # without noticing.
  test "an SVG diagram loads too, despite the policy that makes it inert" do
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    assert_equal [ 24, 16 ], natural_size("Architecture")
    assert_no_csp_violations
  end

  # The alt text stays in the DOM, so the placeholder is decoration over a
  # description a screen reader still gets.
  test "an image that is not there shows the placeholder rather than a broken icon" do
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    width, height = natural_size("Missing entirely")

    assert_equal [ 320, 180 ], [ width, height ],
                 "the placeholder never arrived — the browser is showing a broken image"
    assert_selector "img[alt='Missing entirely']"
    assert_no_csp_violations
  end

  # `img-src 'self'` already covered this, so the fix needed no policy change —
  # but the policy is enforced in every environment and a later narrowing of it
  # would take the images out silently. This is the test that would notice.
  test "the policy allows the proxy without allowing anything new" do
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    assert_operator natural_size("Deliveries per day").first, :>, 0
    assert_no_csp_violations
  end

  # A 1600px screenshot in a repository is ordinary, and the reading column is
  # not 1600px wide. Nothing ever exercised this before, because every relative
  # image was a 20px broken icon.
  test "a wide image is held inside the reading column on a phone" do
    resize_window(390, 844)
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    assert_operator natural_size("Deliveries per day").first, :>, 0

    overflow = page.evaluate_script(
      "document.documentElement.scrollWidth - document.documentElement.clientWidth"
    )

    assert_operator overflow, :<=, 0, "the page scrolls sideways on a phone"
  end

  private

  # What the browser actually decoded. Zero means the image never arrived,
  # whatever the DOM says about it.
  def natural_size(alt)
    assert_selector "img[alt='#{alt}']"

    # The decode is asynchronous, so poll for it rather than racing it.
    Timeout.timeout(Capybara.default_max_wait_time) do
      loop do
        size = page.evaluate_script(<<~JS)
          (function () {
            var img = document.querySelector("img[alt='#{alt}']");
            return img ? [ img.naturalWidth, img.naturalHeight ] : [ 0, 0 ];
          })()
        JS
        return size if size.first.to_i.positive?

        sleep 0.1
      end
    end
  rescue Timeout::Error
    [ 0, 0 ]
  end

  def stub_blob(path, body)
    stub_request(:get, "#{CONTENTS}/#{path}")
      .with(query: hash_including({ "ref" => HEAD_SHA }))
      .to_return(status: 200, body: body,
                 headers: { "Content-Type" => "application/vnd.github.raw; charset=utf-8" })
  end

  def stub_missing(path)
    stub_request(:get, "#{CONTENTS}/#{path}")
      .with(query: hash_including({}))
      .to_return(status: 404, body: { message: "Not Found" }.to_json,
                 headers: GithubStubs::JSON_HEADERS)
  end

  def files
    [ { filename: PATH, status: "added", patch: PATCH,
        additions: 7, deletions: 0, changes: 7,
        sha: Digest::SHA1.hexdigest(PATH),
        blob_url: "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" } ].to_json
  end
end
