# pr-comments.el

An Emacs package for browsing and responding to unresolved GitHub PR review threads without leaving your editor.
It doesn't replace the GitHub review interface bug rather addresses a narrow problem:
it allows for addressing code review feedback without switching between the editor and the browser.

## How it works

- The plugin detects the current PR via `gh pr view`.
- It fetches all review threads using the GitHub GraphQL API.
- It displays threads as an xref list, sorted by file and line number.
- Pressing RET on a thread jumps to the comment location in the respository.
- Pressing SPC on a thread opens a read-only buffer displaying the discussion.
- You can reply to or resolve comments from the thread list or the thread view buffer.
- Replies are posted as **pending review comments** — they remain in draft until you submit the review on GitHub.
- Replying to or resolving a thread refreshes the thread list.

## Related projects

- **[code-review](https://github.com/wandersoncferreira/code-review)** is a comprehensive code review package for Emacs with support for GitHub, GitLab, and Bitbucket.
  It renders diffs inline and supports submitting full reviews.
  This plugin tries to replace the entire GitHub review interface.
- **[https://github.com/blahgeek/emacs-pr-review](emacs-pr-review)** is a GitHub-specific PR review interface in Emacs.
- **[https://github.com/charignon/github-review](github-review)** is a GitHub-specific PR review package that displays the entire review state in a single buffer.

pr-comments.el has a much smaller scope than these projects since it doesn't try to replace GitHub's web interface.
It focuses solely on minimizing the pain of dealing with unresolved review threads.
It also delegates authentication to the [`gh`](https://cli.github.com/) tool because I hate dealing with `.netrc` (aka `.authinfo`) files.

## Requirements

- Emacs 28.1+
- [`gh` CLI](https://cli.github.com/) authenticated with your GitHub account

## Installation

Load the file manually or add it to your load path:

```elisp
(load "/path/to/pr-comments.el")
```

## Usage

Open a file in a Git repository that has an open pull request, then run:

```
M-x pr-comments
```

This opens a `*pr-comments*` buffer listing all unresolved review threads.
Each entry shows:

- `[●]` (warning face) — thread has no reply yet
- `[✓]` (dimmed) — thread has at least one reply

## Keybindings

### In `*pr-comments*` (thread list buffer)

| Key   | Action                                      |
|-------|---------------------------------------------|
| `RET` | Jump to the file and line of the comment    |
| `SPC` | Show full thread in a side window           |
| `r`   | Reply to the thread at point                |
| `k`   | Resolve the thread at point                 |
| `g`   | Refresh the thread list                     |
| `q`   | Close the buffer                            |

### `*PR Comment*` (single thread view buffer)

|-------|---------------------------------------------|
| `r`   | Reply to the thread                         |
| `k`   | Resolve the thread                          |
| `q`   | Close the buffer                            |

### In `*PR Reply*` (reply compose buffer)

| Key       | Action              |
|-----------|---------------------|
| `C-c C-c` | Submit the reply    |
| `C-c C-k` | Cancel and discard  |

## Customization

| Variable                    | Default | Description                     |
|-----------------------------|---------|---------------------------------|
| `pr-comments-gh-executable` | `"gh"`  | Path to the `gh` CLI executable |
