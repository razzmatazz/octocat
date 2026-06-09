# TODO items

## It is not clear that last item shows on PR list indicates c/i status

Hide it or show text

## ~~Cannot open dashboard when repo has PRs or issues or actions disabled~~

Each section now handles errors independently — a disabled feature shows a
dimmed inline note and the rest of the dashboard renders normally.

## Better defaults for the dashboard

List only open/active issues & PRs

## A way to view the entire diff for PR

Currently I need to view this commit-by-commit

## PR: We need a way to view reviews

Probably show the entire diff, file sections, with subsections where review comments are shown?

## ~~PR/issue body rendering~~

Fixed by stripping `\r` from body and comment text in both `octocat-pr.el` and `octocat-issue.el` at the binding site, before any rendering or splitting.
