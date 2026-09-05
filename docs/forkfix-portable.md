# CodexBar ForkFix portable build

This fork can be installed on another Mac without copying data from the build machine.

## What the package contains

- A universal macOS app for Apple silicon and Intel.
- The ForkFix Codex session-accounting changes.
- Codex usage retrieval through the locally installed official Codex CLI only.
- Incremental local and remote Codex session accounting.
- A per-user cache at `~/Library/Caches/CodexBarForkFix`.

The package does not contain Codex sessions, account snapshots, OAuth tokens, SSH keys,
remote-host configuration, or the build machine's cache. Remote usage works after the
new Mac can reach the same SSH hosts and Codex Desktop has those remote connections configured.

## Install a release build

1. Download `CodexBar-ForkFix-macos-universal-*.zip` and its `.sha256` file from this
   fork's GitHub Releases page.
2. Verify the download in Terminal:

   ```bash
   shasum -a 256 -c CodexBar-ForkFix-macos-universal-*.zip.sha256
   ```

3. Unzip the archive and move `CodexBar ForkFix.app` to `/Applications`.
4. On first launch, Control-click the app, choose **Open**, then confirm **Open**.

The build is ad-hoc signed because this fork does not include a Developer ID certificate or
notarization credentials. If macOS still blocks the verified archive, remove quarantine only
from this exact app bundle and open it again:

```bash
xattr -dr com.apple.quarantine "/Applications/CodexBar ForkFix.app"
open -a "/Applications/CodexBar ForkFix.app"
```

## New-device prerequisites

- macOS 14 or newer.
- The official Codex CLI installed and signed in to the intended ChatGPT account.
- For remote project accounting: working SSH aliases, `ssh`, and `rsync`; configure or
  connect the remote hosts once in Codex Desktop so ForkFix can discover them.

The first scan on a new device builds a new local ledger. It does not migrate the old Mac's
ledger, and it can only count local or reachable remote JSONL sessions available to that device.

## Build from source

Install Xcode, clone this fork, check out the desired tag, then run:

```bash
./Scripts/package_forkfix_portable.sh
```

Artifacts are written to `dist/`. To build only one architecture:

```bash
ARCHES=arm64 ./Scripts/package_forkfix_portable.sh
```

The app metadata records the exact Git commit used for the build. Automatic Sparkle updates
are disabled so the ForkFix app cannot silently replace itself with an upstream build.

