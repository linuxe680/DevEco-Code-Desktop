# DevEco Code Desktop

A native macOS GUI for the locally installed `deveco` CLI. The app manages a local `deveco serve` process and talks to its HTTP API.

## Run

```bash
./Scripts/build-app.sh     # build the .app bundle
open "DevEco Code Desktop.app"
```

## Distribute

```bash
./Scripts/make-dmg.sh      # build + package build/DevEco Code Desktop-<version>.dmg
./Scripts/make-icon.sh     # regenerate AppIcon.png / AppIcon.icns from make-icon.swift
```

Requirements: macOS 13+, Xcode command line tools, and `deveco` installed locally.

The build script signs the app with a persistent self-signed development
certificate stored in `~/Library/Application Support/DevEcoCodeDesktop/signing`.
This keeps the code identity stable across rebuilds, so macOS remembers
permissions such as access to the project folder in `~/Documents`. The first
launch after the initial setup may ask once; later rebuilds reuse the grant.

## What works

- Choose a project folder; the app starts `deveco serve` on a free local port (starting at `127.0.0.1:4096`, configurable).
- The app resolves the `deveco` binary itself (common npm/homebrew locations, then the login shell's `PATH`), so it works when launched from Finder/Dock. A specific path can also be set in Settings.
- **Settings (⌘,)**: quit behavior for the server process, launch at login, deveco binary path, starting port, auto-start, Enter-to-send, per-session default model, font size, auto-scroll, and Thinking default expansion.
- Sessions: create (⌘N), search, rename, **archive** (server-side `time.archived`, shown in an Archived section), and delete — all via the sidebar context menu; sessions are grouped by Today / Yesterday / Earlier with relative timestamps. New sessions take their title from the first prompt, and existing placeholder titles are backfilled when loaded.
- Send prompts with Enter (Shift+Enter inserts a newline, ⌘⏎ also sends) and stream assistant text, reasoning, and tool status live; the transcript follows the stream and shows a Generating indicator until the session goes idle.
- Conversations use a Codex-style transcript: compact right-aligned user bubbles, borderless left-aligned assistant prose, elapsed time above each reply, and quiet tool cards with per-call duration. Assistant prose supports headings, lists, quotes, inline formatting, and scalable code blocks.
- Chat text size defaults to 15 pt and is adjustable from the **Aa** menu in the chat header or Settings → Chat (13–30 pt); the setting scales prose, code, tool output, and the composer. Codex declares 16 px in CSS, but its CJK fallback renders optically smaller than AppKit at the same nominal size, so 15 pt is the default visual match. Secondary text follows Codex's 14 pt / 12 pt tiers, and code defaults to 14 pt.
- Assistant output renders inline Markdown; fenced code blocks get a language label and a copy button.
- Agent todo list is shown as a collapsible panel (from the `todo.updated` event and `GET /session/{id}/todo`).
- Assistant messages show friendly model names plus token usage and cost below the reply.
- **Changes (Diff)**: view all files a session modified with unified diffs and +/− counts (`GET /session/{id}/diff` + `session.diff` events).
- **Compact** compresses long conversation context (`POST /session/{id}/compact`).
- **Revert**: right-click any message to roll the session back to before it (`/revert` + `/unrevert`, with an orange banner while reverted).
- **Export**: save any session as a Markdown transcript (sidebar context menu or File menu).
- **⌘K** opens a quick switcher for active sessions; the Project menu keeps recent folders.
- Retry-aware status: when the model provider rate-limits, the footer shows "Retrying · attempt n · reason"; the sidebar marks busy/retrying sessions.
- **Prompt queueing**: Enter while generating queues the prompt (removable chips); it sends automatically when the session goes idle.
- **Prompt history**: Option+↑/↓ recalls recently sent prompts.
- Drafts, queued prompts, attachments, and generating/retry state are isolated per session, so switching chats never hijacks the current composer or sends another session's files. The sidebar and ⌘K switcher flag background sessions that need permission, need an answer, failed, are retrying, or finished with unread activity. A macOS notification + optional sound fire when a background session finishes (Settings → Chat).
- A banner appears when the server reports a newer deveco version.
- **Agent questions**: when the agent asks for a decision (single/multi-select options or free text), an inline card handles answering or skipping (`question.asked` → `/question/{id}/reply`).
- **Slash commands**: typing "/" in the chat input shows completions for commands, skills, and MCP prompts (`GET /command`); sending "/name args" routes to the dedicated command endpoint. Sessions can be forked from the sidebar.
- A first-run setup card appears when the deveco CLI is missing, with a binary picker and retry.
- The Dock icon shows a badge while permission requests or agent questions are pending.
- The sidebar footer shows project usage totals (sessions/messages/cost from `GET /stats/usage`); the status bar shows the current git branch (`GET /vcs` + `vcs.branch.updated`).
- File attachments in messages render as clickable chips (image/PDF/text icons).
- Diff panels colorize unified diff lines (+green / −red / @@blue).
- **Backup & Restore** (Settings → Server): zip/restore the deveco data directory; restoring stops the server, replaces data, and restarts.
- Answer permission requests from the UI with Allow once, Always allow, or Reject.
- Server log tail and error banner.
- **Models & Providers**: browse configured and available providers, add or edit custom OpenAI-compatible providers, set base URL and API key, manage models with context/output limits and reasoning flag, delete providers, and set the default model.
- Pick a model per chat session from the composer footer, next to reasoning effort and send; the picker covers **every model the server can run** (`GET /api/model` — built-in, configured, and plugin providers), merged with models from custom providers. Model IDs may contain slashes; selection routes as `providerID/modelID`. Effort levels come from the selected model (or the global default while the session is on “Server default”), are shown as 低/中/高/极高/最高/无 in Chinese, and are sent with each prompt.
- Configure a built-in provider as a custom template from the Available providers list.
- Quitting the app stops the managed server process (configurable in Settings).

## Release & distribution

Build a versioned DMG with release notes and SHA-256 in one command — see [RELEASE.md](RELEASE.md):

```bash
Scripts/release.sh        # bumps the version, builds, packages, verifies
```

## Design notes

See [ROADMAP.md](ROADMAP.md) for the analysis methodology (server OpenAPI → official web-UI bundle → upstream opencode/codex sources) and the phased feature plan.

## Localization

The UI ships in English and Simplified Chinese; macOS picks automatically per system language. Strings live in `Resources/{en,zh-Hans}.lproj/Localizable.strings`.

## Notes

- The server runs without a password and binds to loopback only.
- The app sets `XDG_DATA_HOME` to `~/Library/Application Support/DevEcoCodeDesktop/deveco-data` so server logs stay inside the app container.
- Provider changes use `PATCH /config`; model selection per prompt uses the `model` field of `POST /session/{id}/prompt_async`.
- Streaming updates come over the `GET /event` SSE stream with exponential-backoff reconnects; a light poll only runs while a prompt is in flight as a fallback.
- The API is the same one used by the bundled web UI (`GET /doc` on the running server).

## Tests

```bash
swift test
```
