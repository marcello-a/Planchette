---
name: review-pr
description: "Review a pull request you were asked to review, in a free checkout or a temporary worktree, and post the review only after you decided on every finding. Two modes: `review` (check out the PR, find issues, write findings.json) and `submit` (read decisions.json, push the chosen fixes, post one GitHub review, clean up). Use for `/review-pr <url|number>`, `review PR 1234`, `/review-pr submit <dir>`, and whenever Planchette's Reviews panel starts or sends a review. Never posts anything before the decisions exist."
---

# Review a pull request

This is Planchette's default `review-pr` skill. Planchette put it in `~/.claude/skills/review-pr`
because no skill of that name was there; the file `.planchette-default` beside this one marks it,
and Planchette keeps it up to date. To use your own, replace this folder (and delete the marker):
Planchette never touches a `review-pr` skill without the marker. Your own skill must keep the
three-file contract below — the Reviews panel reads and writes nothing else.

Planchette's Reviews panel drives this skill, but it also works on its own from any terminal.
The contract is three JSON files in one directory (the **review dir**):

| File | Written by | Read by |
|---|---|---|
| `findings.json` | this skill, `review` mode | Planchette (shows the findings), `submit` mode |
| `decisions.json` | Planchette, or this skill after asking in the terminal | `submit` mode |
| `sent.json` | this skill, `submit` mode | Planchette (moves the row to "Sent") |

Default review dir when run by hand: `~/.planchette/reviews/<owner>-<repo>-<number>/`.
Planchette passes `--dir`.

## Mode — derive it from the arguments

| Arguments | Mode |
|---|---|
| `<pr-url>` or `<number>` (+ flags) | `review` |
| `submit <review-dir>` | `submit` |

Flags for `review`:

- `--dir <path>` — the review dir (create it).
- `--keep-checkout` — Planchette owns this checkout (a temporary worktree it made). Do not remove
  it at the end; Planchette closes its project and removes the worktree.
- `--checks` — also install dependencies and run the repo's lint, type-check and tests for what
  the PR changes. Off by default: an install can take minutes.

Never commit, push or post in `review` mode. Never post before `decisions.json` exists.

---

## `review` mode

### 1. Resolve the PR

```bash
gh pr view <url|number> --json number,url,title,author,state,isDraft,headRefName,headRefOid,baseRefName,headRepository,headRepositoryOwner,isCrossRepository,maintainerCanModify,additions,deletions,changedFiles
```

Stop if `state` is not `OPEN`.

### 2. Make sure the checkout is free, then check out the PR

**Never take a checkout somebody works in.** Free means: no agent running or open on a work
branch, no unread result, no uncommitted changes, no dev server. Never stash, never reset.

- **Started by Planchette** (`$PLANCHETTE_SESSION` is set and `--dir` was given): Planchette chose
  a free checkout and opened this terminal in it. Check anyway: `git status --porcelain` must be
  empty, else stop and say why.
- **Started by hand**: if the current directory is not a free checkout of the PR's repo, rank the
  candidates and ask the user which one to use (the free ones first, the best marked as
  recommended, plus "temporary worktree, removed after the review"). Busy ones are not options;
  name them with their reason.

  ```bash
  python3 <this skill's folder>/scripts/checkouts.py <owner/repo> [--root <folder>]
  ```

  Without `--root` the script looks at the checkouts Planchette's terminals are in.
  A temporary worktree goes beside the repo:
  `git -C <a checkout of the repo> worktree add --detach <repoRoot>.worktrees/review-pr-<n>`.

Then, in the chosen checkout:

```bash
git rev-parse --abbrev-ref HEAD          # remember it as previousRef ("HEAD" = detached: keep the sha)
git fetch origin
gh pr checkout <n> --branch review/pr-<n> --force
```

`review/pr-<n>` belongs to the review, so `--force` only resets the review's own branch.

### 3. Review

1. Read the diff (`gh pr diff <n>`) and every changed file in full, plus what it calls and what
   calls it, as far as needed to judge the change.
2. Read the repo's own conventions first: `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`, linter and
   formatter configs. Judge the PR by them, not by taste.
3. Look for: bugs and wrong behaviour, missing error handling, security problems, broken or missing
   tests for new behaviour, API or data changes that break callers, and violations of the repo's
   written conventions.
4. With `--checks`: run the repo's own lint, type-check and test commands (from its README,
   package scripts or CI config) for the changed parts. Every failure is a finding.

Keep only findings you verified in the code. Merge duplicates. Skip style that a linter enforces.

### 4. Write `findings.json`

For each finding, check whether its line is inside the PR diff (an added or context line of a
hunk, new side). Only such lines can carry an inline comment.

Preselect a decision per finding:

| Severity | Concrete change of a few lines? | Preselected decision |
|---|---|---|
| high | any | `comment` |
| medium | any | `comment` |
| low | yes | `comment` (with the suggestion) |
| low | no | `skip` |

`fix` is never preselected. A `suggestion` is the exact replacement for lines `startLine…line` on
the new side — only when you are sure it is correct and complete.

Write the file atomically (`findings.json.tmp`, then `mv`): Planchette watches it.

```json
{
  "version": 1,
  "pr": {
    "url": "https://github.com/acme/shop/pull/7",
    "repo": "acme/shop",
    "number": 7,
    "title": "Round cart totals per line",
    "author": "lea",
    "headRef": "lea/round-lines",
    "headSha": "<headRefOid at review time>",
    "baseRef": "main",
    "crossRepository": false,
    "maintainerCanModify": true
  },
  "checkout": "/abs/path/of/the/checkout",
  "temporary": true,
  "keepCheckout": true,
  "previousRef": "main",
  "createdAt": "2026-10-29T13:40:00Z",
  "summary": "One line: what the PR does and the overall impression.",
  "findings": [
    {
      "id": "f1",
      "severity": "high",
      "path": "src/cart/totals.ts",
      "line": 41,
      "startLine": null,
      "inDiff": true,
      "title": "Voucher applies to the unrounded total",
      "text": "What is wrong and why, for the reviewer.",
      "comment": "The review comment, written to the author: polite, concrete, with the reason.",
      "suggestion": null,
      "decision": "comment"
    }
  ]
}
```

`severity` ∈ `high|medium|low`. `decision` ∈ `comment|fix|skip`. `startLine` only for a multi-line
suggestion.

### 5. Hand over

- **Planchette** (`$PLANCHETTE_SESSION` set): print one line per finding (severity, `path:line`,
  title) and stop with: "Decide in Planchette's Reviews panel." Ask nothing. Planchette types
  `/review-pr submit "<dir>"` into this terminal when the user clicks "Send review".
- **By hand**: show the findings as a table with the preselected decisions and ask: send as
  preselected (recommended), set all to comment, set all to skip, or change single findings.
  Write `decisions.json` (format below) and go on with `submit` mode.

---

## `submit` mode

Read `findings.json` and `decisions.json` from the review dir:

```json
{
  "version": 1,
  "verdict": "REQUEST_CHANGES",
  "decisions": { "f1": "comment", "f2": "fix", "f3": "skip" }
}
```

`verdict` ∈ `APPROVE|COMMENT|REQUEST_CHANGES`. A finding without a decision keeps the one in
`findings.json`.

### 1. Check the PR again

```bash
gh pr view <url> --json state,headRefOid,mergedAt
```

- Not `OPEN`: post nothing, push nothing. Write `sent.json` with the error and stop. Commits pushed
  onto a merged branch are lost.
- `headRefOid` changed since the review: comments still go on the reviewed commit. Before fixes,
  update the branch: `git pull --ff-only <remote> <headRef>`.

### 2. Fixes (decision `fix`)

The user chose these. They change another person's branch, so keep each one minimal.

1. Make the change in the review checkout; run the cheapest check that covers it.
2. One commit per fix, in the repo's commit convention (read `CONTRIBUTING.md` and `git log`).
3. Push without force, to the PR's head branch:
   - same repo: `git push origin HEAD:<headRef>`
   - fork with `maintainerCanModify`: `git push https://github.com/<headOwner>/<headRepo>.git HEAD:<headRef>`
   - otherwise, or when the push is rejected: never force. Turn the fix into a `comment` (with the
     suggestion when there is one) and record why in `sent.json.errors`.

### 3. Post one review

Write the payload to `<dir>/review.json` and post it with one call:

```bash
gh api repos/<owner>/<repo>/pulls/<n>/reviews --method POST --input <dir>/review.json
```

```json
{
  "commit_id": "<findings.pr.headSha>",
  "event": "REQUEST_CHANGES",
  "body": "…",
  "comments": [
    { "path": "src/cart/totals.ts", "line": 41, "side": "RIGHT", "body": "…" }
  ]
}
```

- `comment` with `inDiff: true` → one entry; body = `comment`, plus a ```` ```suggestion ```` block
  when there is a suggestion (multi-line: add `"start_line"` and `"start_side": "RIGHT"`).
- `comment` with `inDiff: false` → a line in `body`: `` `path:line` — comment ``.
- Pushed fixes → a short list in `body`: sha and subject.
- `skip` → nothing.
- Keep `body` short. `REQUEST_CHANGES` and `COMMENT` need a body or a comment; when both would be
  empty, post only an `APPROVE` verdict, else post nothing and say so.

### 4. Write `sent.json`, then clean up

```json
{
  "version": 1,
  "sentAt": "2026-10-29T14:02:00Z",
  "verdict": "REQUEST_CHANGES",
  "reviewUrl": "https://github.com/…/pull/7#pullrequestreview-…",
  "pushedCommits": [{ "sha": "abc1234", "subject": "…" }],
  "errors": []
}
```

Write it atomically. Then:

- `keepCheckout: true`: leave the checkout; Planchette removes it.
- A temporary worktree this skill made: `git worktree remove <path>`, then
  `git branch -D review/pr-<n>` in the main checkout.
- A normal checkout: `git checkout <previousRef>`, then `git branch -D review/pr-<n>`.

End with one line: the verdict, how many comments and fixes, and the review URL.
