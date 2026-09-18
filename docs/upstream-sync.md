# Tracking and integrating both upstreams

This fork tracks two independent sources. GitHub displays one parent for a fork, but a local Git repository can fetch and compare any number of remotes.

| Remote | Repository | Role |
|---|---|---|
| `origin` | `mikulicf/moonlight-vplus` | Publish this fork's branches and releases. |
| `upstream` | `qiin2333/moonlight-qt` | Moonlight V+ features and fixes. |
| `moonlight` | `moonlight-stream/moonlight-qt` | Original Moonlight fixes, platform support, and dependency updates. |

A branch has only one default tracking branch, so local `master` tracks `origin/master`. That does not prevent comparing or integrating either other remote.

## Check for updates

From the repository root, with Python 3 and Git installed:

```sh
python scripts/upstream-status.py
```

The script adds missing upstream remotes, verifies existing URLs, disables pushing to those two remotes, fetches their `master` branches, and prints a Markdown report against `HEAD`. It never merges or changes the current branch. It accepts the canonical HTTPS and SSH URLs and refuses to repoint an existing remote with a different URL. `origin` is left unchanged.

```sh
python scripts/upstream-status.py --base origin/master --output upstream-status.md
python scripts/upstream-status.py --no-fetch
```

`--no-fetch` uses existing remote refs without network requests or Git configuration changes. The shell wrapper `scripts/upstream-status.sh` provides the same interface where a POSIX shell is available.

The **Upstream sync status** GitHub Actions workflow runs each Monday at 01:23 UTC and can also be started manually. Its job summary and downloadable artifact contain both comparisons. The workflow does not create issues, push commits, or merge changes. Scheduled workflows run from the repository's default branch.

Review updates at least every two weeks, even if the result is to defer all current changes with documented reasons.

## Interpret the report

- **Graph comparison** counts commits reachable from only one side, including merge commits. A cherry-picked change can therefore still appear as an upstream-only graph commit.
- **Applied** means the local base history contains the standard `cherry picked from commit ...` marker for that commit.
- **In progress** means that marker appears on another local branch or an already fetched `origin` branch, but not in the comparison base. This is a review hint; it does not mean the change is integrated.
- **Reviewed** means `scripts/upstream-skip.txt` records a decision for that SHA prefix.
- **Pending** means the commit is neither reachable from the base nor accounted for by those markers or decisions.

Each upstream lists its incoming non-merge commits independently. The final pending count deduplicates identical commit SHAs shared by the two sources. Equivalent changes with different SHAs still require review; the report does not infer equivalence from similar commit titles or patches.

## Integrate on a review branch

Start from a clean, current local branch and review the report before choosing a source:

```sh
git switch master
git pull --ff-only origin master
git switch -c sync/upstream-review
git merge upstream/master
```

After integrating V+, rerun the report: V+ may already include the original Moonlight changes. If additional original Moonlight changes remain useful, review and merge `moonlight/master` separately. Test and resolve conflicts after each integration; do not blindly merge both sources in sequence.

When selecting an individual commit instead of merging a branch, preserve its source:

```sh
git cherry-pick -x <commit-sha>
```

The `-x` marker lets later reports recognize the applied commit. For changes that should be skipped or already have an independent implementation, add `<sha-prefix> <reason>` to `scripts/upstream-skip.txt`, identifying the replacement code or pull request where applicable. Do not mark an unreviewed commit as skipped simply to clear the report.

Rerun the report after integration and run the relevant [tests](../tests/README.md) before pushing a review branch. Check that the English defaults, service choices, and stream-window overlay behavior remain intact.

## Frequent conflict areas

| File or directory | Review considerations |
|---|---|
| `app/streaming/session.cpp` | Overlay, clipboard, USB, and HDR integration share this file. Check event ordering and focus handling carefully. |
| `app/gui/SettingsView.qml` | V+ splits settings into `app/gui/settings/`; original Moonlight changes may need to be moved into those components. |
| `app/languages/*.ts` | Regenerate catalogs with `scripts/update_translate.sh` when appropriate, then review the generated changes. Preserve English defaults and optional translations. |
| `moonlight-common-c` | V+ requires its protocol-library fork. Review and update that submodule separately; do not replace it with the original library without checking the extensions. |

## Dependency updates

Dependency versions have two build paths: Linux source revisions in `build.yml`, and Windows/macOS prebuilt bundle tags in `setup-deps`. Both upstreams can change Qt, SDL, FFmpeg, and related libraries. For each such update, decide whether to adopt it, adapt it to this fork's pins, or defer it with a recorded reason. Keep the build paths on a compatible, tested combination.
