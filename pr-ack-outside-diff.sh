#!/usr/bin/env bash
# pr-ack-outside-diff.sh — post a PR issue comment marking outside-diff
# review findings as addressed, so next pr-manager tick stops surfacing
# them to new handlers.
#
# Background (2026-04-21): outside-diff comments posted in a review body
# (especially CodeRabbit's "Outside diff range comments" + "Prompt for
# all review comments with AI agents" blocks) have NO GitHub resolve
# button. Without state tracking, every pr-manager tick would re-surface
# the same findings forever, and every handler spawn would redo the work.
#
# The ack channel is a PR-level issue comment with an HTML-comment marker
# that pr-manager greps on the next tick. The marker encodes the review
# id AND sha256 of the review body, so an EDITED review body (new
# findings added to the same review) re-surfaces despite the old ack.
#
# Usage:
#   pr-ack-outside-diff.sh <pr_key> <review_id> <body_hash> <commit_sha> <summary>
#
# Arguments:
#   pr_key       e.g. owner/repo#325
#   review_id    numeric review id from envelope.outside_diff_reviews[].review_id
#                (must match pr-manager marker parser contract: review=([0-9]+);
#                strip any GraphQL node prefix like "PRR_..." before calling)
#   body_hash    sha256 hex digest of the review body (from envelope's
#                outside_diff_reviews[].body_hash)
#   commit_sha   the commit SHA that addresses the findings (40-char hex or short)
#   summary      human-readable one-line summary of what was addressed
#
# The script posts a comment like:
#   <!-- clawdbot:outside-diff-addressed review=<id> hash=<sha256> sha=<sha> -->
#   Addressed outside-diff findings from review <id> in <sha>:
#   <summary>
#
# pr-manager.sh scans PR comments for the HTML marker on each tick and
# filters matching (review_id, body_hash) pairs out of the envelope.

set -euo pipefail

if [ $# -lt 5 ]; then
    echo "usage: $0 <pr_key> <review_id> <body_hash> <commit_sha> <summary>" >&2
    echo "  pr_key     owner/repo#N" >&2
    echo "  review_id  numeric id from envelope.outside_diff_reviews[].review_id" >&2
    echo "  body_hash  sha256 hex from envelope.outside_diff_reviews[].body_hash" >&2
    echo "  commit_sha 40-char or short commit SHA that fixes the findings" >&2
    echo "  summary    one-line human summary" >&2
    exit 2
fi

PR_KEY="$1"
REVIEW_ID="$2"
BODY_HASH="$3"
COMMIT_SHA="$4"
SUMMARY="${*:5}"

# Shape checks
if ! [[ "$PR_KEY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$ ]]; then
    echo "error: pr_key must be owner/repo#N, got: $PR_KEY" >&2
    exit 3
fi
# review_id MUST be numeric. pr-manager.sh's ack-marker parser only
# recognizes ``review=([0-9]+)`` (see pr-manager.sh line ~525), so a
# non-numeric id would post a comment successfully but never get read
# back — the review would re-surface on every tick forever.
if [[ -z "$REVIEW_ID" ]] || [[ ! "$REVIEW_ID" =~ ^[0-9]+$ ]]; then
    echo "error: review_id must be numeric (pr-manager parser contract), got: $REVIEW_ID" >&2
    exit 4
fi
if ! [[ "$BODY_HASH" =~ ^[a-f0-9]{64}$ ]]; then
    echo "error: body_hash must be 64-char lowercase sha256 hex, got: $BODY_HASH" >&2
    exit 5
fi
if ! [[ "$COMMIT_SHA" =~ ^[a-f0-9]{7,40}$ ]]; then
    echo "error: commit_sha must be 7-40 char hex, got: $COMMIT_SHA" >&2
    exit 6
fi

REPO="${PR_KEY%#*}"
PR_NUM="${PR_KEY##*#}"

BODY="<!-- clawdbot:outside-diff-addressed review=${REVIEW_ID} hash=${BODY_HASH} sha=${COMMIT_SHA} -->
Addressed outside-diff findings from review \`${REVIEW_ID}\` in commit \`${COMMIT_SHA}\`:
${SUMMARY}"

# Post the comment. gh pr comment is auth'd via GH_TOKEN or gh's login.
# Captured stdout includes the comment URL on success.
#
# Note: the previous ``COMMENT_URL=$(...); RC=$?`` form was unreachable
# under ``set -e`` because a failing command substitution in an
# assignment exits immediately. Use ``if <assign>; then ... else`` so the
# non-zero path actually runs.
if COMMENT_URL=$(gh pr comment "$PR_NUM" --repo "$REPO" --body "$BODY" 2>&1); then
    :
else
    RC=$?
    echo "error: gh pr comment failed (rc=$RC): $COMMENT_URL" >&2
    exit "$RC"
fi
echo "acked review=$REVIEW_ID hash=$BODY_HASH on $PR_KEY (commit=$COMMIT_SHA)"
echo "$COMMENT_URL"
