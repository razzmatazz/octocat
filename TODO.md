# TODO items

## Some form of caching is needed to long load of dashboard for large repos

I.e. perform refresh in background and/or on request.

## It is not clear that last item shows on PR list indicates c/i status

Hide it or show text

## ~~Cannot open dashboard when repo has PRs or issues or actions disabled~~

Each section now handles errors independently — a disabled feature shows a
dimmed inline note and the rest of the dashboard renders normally.

## ~~Better defaults for the dashboard~~

Both `octocat--list-prs` and `octocat--list-issues` now use `--state open`.
Header counts updated to say "N open PR(s) / N open issue(s)".
Both list functions now live in their respective `-pr.el` / `-issue.el` files.

## A way to view the entire diff for PR

Currently I need to view this commit-by-commit

## PR: We need a way to view reviews

Probably show the entire diff, file sections, with subsections where review comments are shown?

## ~~PR/issue body rendering~~

Fixed by stripping `\r` from body and comment text in both `octocat-pr.el` and `octocat-issue.el` at the binding site, before any rendering or splitting.
