# Flightdeck

A read-only overview of every Claude Code agent running on this Mac. Park it on
a second display and glance at it: who is working, who finished, who needs you.

It does not launch, queue, or manage work. You stay in your IDE.

## Why it is actually live

Every Claude Code process writes its own state to
`~/.claude/sessions/<pid>.json` and rewrites it on each state change:

```json
{ "pid": 22937, "sessionId": "d82ab55e…", "cwd": "…/workspace/babysteps",
  "name": "babysteps-0b", "kind": "interactive",
  "status": "busy", "statusUpdatedAt": 1787908222581 }
```

Flightdeck subscribes to that directory with FSEvents (50ms latency) instead of
polling. Measured on Claude Code 2.1.250, every observed transition hit disk
within **70ms** — including detached `--bg` agents with no terminal at all, and
interactive sessions whose window was never focused:

```
+4.07s  pid=36090   -       -> idle   kind=bg           mtime_age=0.01s
+4.28s  pid=36090   idle    -> busy   kind=bg           mtime_age=0.06s
+6.87s  pid=36090   busy    -> idle   kind=bg           mtime_age=0.04s
+62.46s pid=2079    waiting -> busy   kind=interactive  mtime_age=0.07s
```

There is no hook to install, no `claude` CLI to spawn per refresh (that costs
~0.58s a call), and nothing tied to window activation — which is what makes
other dashboards go stale until you visit the window.

## Grouping

Agents are grouped by **project**, with the project name as the section header.
Projects are ordered by the most urgent lane any of their agents is in, then by
most recent activity — so a project with an agent waiting on you rises to the
top.

Within a project the ordering is unchanged: most urgent lane first, then most
recently changed. Each card keeps a lane-coloured stripe and status word, so
status is still readable at a glance without lane headers. The project name was
removed from the cards themselves, since the header now carries it.

## Lanes

| Lane | Meaning |
| --- | --- |
| NEEDS ATTENTION | `needs_input` / `waiting` / `blocked` — the agent is asking you something |
| RUNNING | `busy` / `compacting` |
| FINISHED | `idle` — stopped, ball is in your court |
| INACTIVE | process gone; dropped entirely after 12h |

`status` is treated as an **open** string set, and this matters in practice —
2.1.250 emits `shell` while an agent runs a command, which was not in the
binary's obvious status strings and turned up only by watching live sessions.

So **unknown statuses count as working**, and render their raw value as the
status word. FINISHED is claimed only for a positively known idle state. The
worst error this app can make is telling you an agent is done when it is not.

## Card titles

Every agent gets a title you can scan. Deterministic sources first, a model
only for the residue:

1. **Referenced file heading.** If the prompt points at a file
   (`@.scratch/issues/08-golem-init.md`), that file's first markdown heading
   describes the work better than the command that opened it — and is free and
   instant. This is what turns `/mattpocock-skills:implement @…08-golem-init.md`
   into *"08: [watchtower] golem init"*.
2. **User prose.** The first non-`isMeta`, non-sidechain user turn, kept
   verbatim when it is already short enough to read as a title.
3. **The slash command as typed** — `<command-name>` plus `<command-args>`,
   skipping hygiene commands like `/clear`.
4. **Generated title** (`TitleService`), for the residue only: a bare slash
   command with no resolvable file, and rambling prompts over 120 characters.
   Never for a session with no recovered intent at all — seeding a model with
   transcript boilerplate produced titles like *"Session cleared, ready for a
   new task"*, so the seed is built strictly from recovered intent (prose, or
   the command and its arguments) and generation is skipped when there is none.
   One `claude -p` call with Haiku, cached to
   `~/Library/Application Support/Flightdeck/titles.json`, so a session is
   summarised once and then costs nothing. Cache entries are keyed by a hash of
   the seed as well as the session id, so a title generated from one prompt is
   discarded rather than shown forever once the prompt changes. It runs detached (~7-8s) while the
   card shows its deterministic title, and the full prompt stays in the
   tooltip.
5. **`No prompt yet`** when no transcript exists at all — a pre-warmed
   background agent that was never given work. Better than showing a hex id.

Precedence is heading, then generated, then prose, then command. A generated
title is only *consulted* when generation was warranted — reading that cache
unconditionally let a stale entry override a perfectly good heading.

Across 9 live sessions this needed 4 model calls; 5 resolved for free.

Step 2's filter matters: transcripts routinely open with `isMeta` entries
wrapped in `<local-command-caveat>` and `<command-name>` tags. Taking line one
naively is why other tools title cards
*"Base directory for this skill: /Users/…"*.

`claude -p` was verified not to register its own session file, so the
summariser cannot show up in Flightdeck's own list. The CLI is located
explicitly (`~/.local/bin/claude` and friends) because a GUI app inherits only
`/usr/bin:/bin:/usr/sbin:/sbin`.

## Usage windows

The footer carries the two rate-limit windows Claude Code itself tracks — the
5-hour session window and the weekly one — as bars with the percentage, the
time until each resets, and a colour that turns amber past half and red past
85%.

The figures are Claude Code's own, never a local estimate. There is no way to
recompute them from token counts on disk: the percentage is of a plan limit
the client never writes down. So Flightdeck reads them from wherever Claude
Code has left them, and there are two such places.

**`~/.claude.json` → `cachedUsageUtilization`** is always there and needs no
setup, but Claude Code only refreshes it when it actually asks the server —
opening `/usage`, or nearing a limit. On 2.1.250 it sat 20 hours stale through
a full day of sessions. It is a real reading, just not necessarily a current
one, which is why its age is always shown.

**The status line** is the live source. `rate_limits` is a documented
status-line field, handed to your status-line command on every render of every
session, so it is current within seconds. Flightdeck cannot receive it
directly, so `scripts/flightdeck-usage.sh` taps it: it saves `rate_limits` to
`~/.claude/flightdeck-usage.json` and then runs your real status line with the
same payload, unchanged.

Wrap whatever you already have in `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "~/workspace/flightdeck/scripts/flightdeck-usage.sh npx -y ccstatusline@latest",
  "padding": 0
}
```

Your status line looks and behaves exactly as before; the tap is silent, never
fails the render, and needs `jq`. Flightdeck takes whichever of the two sources
was measured more recently, so the tap simply takes over once it starts
writing.

Two things are deliberately *not* shown as a percentage:

- A window whose `resets_at` has passed reads `— window reset`, not `0%`. The
  window running now started from zero and has only grown since; by how much is
  not knowable from a reading that predates it. (Claude Code drops a window
  from `rate_limits` at rollover for the same reason.)
- With no reading on disk at all, the strip is absent rather than showing
  zeroes.

Hover the strip to see which source is in use and how old it is.

## Cleanup

`Clear N done` in the footer (or `⌘K`) hides finished agents to cut clutter.

**It never kills a process.** Flightdeck observes; it does not manage work, and
an idle session is usually one you will continue tomorrow. Clearing a card
costs you nothing but the card.

The mechanic that makes that safe: a dismissal records the session's activity
timestamp *at the moment you cleared it*, not just its id. A card stays hidden
only while nothing has happened since. The instant the agent does anything —
you continue it, it starts working, it asks you something — its
`statusUpdatedAt` advances past the dismissal and the card returns on its own,
in whichever lane it now belongs to.

So continuing a cleaned-up session is not a special case; it is the same
comparison. Consequences that fall out for free:

- Continue a cleared agent and it reappears under RUNNING within ~70ms.
- When it finishes again it stays visible, because that is *new* completion —
  it is not silently re-hidden by the old dismissal.
- A cleared agent whose process later exits stays hidden. Nothing happened.
- Clears persist across app restarts, so cleanup is not undone by quitting.

Recovering from a clear, in increasing order of scope:

| Affordance | Scope |
| --- | --- |
| `Undo` in the footer, or `⌘Z` | the batch just cleared, for 10s |
| `N hidden` in the footer | everything ever cleared, any time |
| Right-click a card → Clear From Flightdeck | one agent, finished only |

The footer always states how many agents are hidden. Hidden state you cannot
see is a trap, so the count is never silent, and the empty view reads "All
caught up" with a restore button rather than pretending nothing is running.

Records for sessions that have been gone over a week are pruned so
`dismissed.json` cannot grow without bound.

## Jumping to an agent

Clicking a card goes to where that agent is actually running — the Ghostty tab,
the WebStorm window with the embedded terminal it was started from.

The host is found by walking the agent's process ancestry until a real GUI
application appears (`claude` -> `zsh` -> Ghostty). That has to be a process
walk rather than a guess from the working directory: one WebStorm process
commonly hosts five projects at once, and the directory says nothing about
which terminal you launched from.

Picking the window *inside* that app is done through whatever interface the app
publishes for it, because there is no general mechanism that is also safe:

| Host | How | Precision |
| --- | --- | --- |
| Ghostty | AppleScript; each terminal surface reports its working directory | exact tab |
| Terminal.app, iTerm2 | AppleScript; tabs expose the tty the agent is attached to | exact tab |
| JetBrains IDEs | re-open the project root, which focuses the window already showing it | exact window |
| VS Code, Cursor, Zed | same, anchored on `.vscode`/`.git` | exact window |
| anything else | the app is raised, and that is all | app only |

The app is always activated first and synchronously, so an unrecognised host
still gets you most of the way. Everything past that is best effort, and
declines rather than guesses: two agents in one directory are separated by tab
title if Claude Code's title and Flightdeck's agree well enough, and left alone
if they do not. Landing in the wrong window is worse than landing in the right
app.

An IDE is only ever handed a directory that is demonstrably a project root —
for JetBrains, the one holding `.idea`. Handing it a subdirectory does not
focus anything; it opens a second project on top of the one you wanted.

First use raises the system's automation prompt for that particular app.
Refusing it costs you the window, not the jump: the app is already frontmost.
A background (`--bg`) agent has no window at all, so its card opens the project
folder instead.

`--locate` prints what a click would target, for every live agent, without
stealing the focus you are trying to watch. `--jump <name>` performs one:

```bash
"$(swift build -c release --show-bin-path)/Flightdeck" --locate
"$(swift build -c release --show-bin-path)/Flightdeck" --jump watchtower-1e
```

### Why not the Window menu

Every app lists its windows and tabs at the bottom of its Window menu, and the
accessibility API can read and press those entries — one mechanism covering
every host, including the ones above.

It is not used here because it cannot be made safe. The press only takes effect
once the menu has actually been opened; pressing an entry of a menu that was
never shown reports success and does nothing. And opening a JetBrains IDE's
menu bar programmatically kills it: WebStorm 2026.2 aborts during
menu-tracking teardown, taking every terminal in it down too. The per-host
interfaces above are narrower, and they are meant to be called.

## Self-test

The dismissal mechanic is covered by an end-to-end test that drives the real
`SessionStore` against synthetic session files (using the test's own pid so the
liveness probe sees a live process):

```bash
"$(swift build -c release --show-bin-path)/Flightdeck" --selftest
```

It asserts the continuation case explicitly, along with undo, restart
persistence, and that an unknown status is never reported as done. It also
covers the title rules against synthetic transcripts: boilerplate is never
summarised, a `@file` heading outranks a generated title, seeds exclude
machinery, and a cached title dies with the prompt it came from. The usage
windows are covered against a synthetic `~/.claude.json` and tap file: the
fresher of the two sources wins whichever it is, fractional percentages
survive, a rolled-over window is flagged rather than reported, and an absent
reading yields nothing rather than a zero. Window targeting is covered against
the strings Ghostty and WebStorm really produced: the working directory wins
over a title that merely reads like the task, two agents in one directory are
separated by title, near-identical tabs are declined rather than guessed
between, and a project root is found from a subdirectory. Finally the mini
deck: the strip lists in-flight agents only, an unknown status is not dropped
from it, whoever needs you sorts first, and the reference-counted watchers keep
running when one of the two windows closes.

`titles.json` is derived data — delete it to regenerate every title.

## Build and run

```bash
./bundle.sh release      # -> dist/Flightdeck.app
open dist/Flightdeck.app
```

`--dump` prints the computed roster and exits, for verifying the data layer
without the window:

```bash
"$(swift build -c release --show-bin-path)/Flightdeck" --dump
```

## Legibility

Type is sized to be read from across a desk rather than for maximum density —
this window is meant to be glanced at on a second display, not studied. Base
sizes live in `Theme.Size`; every one of them is multiplied by a persisted user
scale, so `⌘+` / `⌘-` / `⌘0` resize the whole window coherently (range
0.85–1.6). Default window width is 440pt to suit the larger text. The mini deck
shares the same multiplier, from a much smaller base.

Shortcuts: `⌘K` clear done, `⌘Z` undo that, `⌘+` / `⌘-` / `⌘0` text size,
`⌘⇧M` toggles the mini deck, `⌘⇧T` toggles float-above-other-windows,
`⌘R` forces a refresh,
`⌃⌘F` (or the green button) goes full screen.
Click a card to reveal its project in Finder; right-click for the session ID
and an `claude attach` command.

## Parking it beside another app

The window is full-screen and Split View capable, so it can be tiled next to
Slack or a terminal on a second display: green button ▸ *Tile Window to Left /
Right of Screen*, or View ▸ Enter Full Screen for a whole display of its own.
Two details make that work, and both live in `WindowCoordinator`:

- The window opts into `.fullScreenPrimary` and `.fullScreenAllowsTiling`.
  Without the former, `toggleFullScreen` is a silent no-op and the green button
  and menu item do nothing — which is how this started out.
- Float-above-other-windows drops to `.normal` level while Flightdeck is the
  active app, and again for as long as it is full screen. This matters more
  than it sounds: a window above `.normal` level never gets a real full screen
  — it zooms to fill the desktop it is already on rather than taking a space of
  its own, and macOS refuses to tile it at all. Every window-management gesture
  happens while the app is active, so floating yields for exactly that window
  and costs nothing: it re-engages the moment you switch to Slack, which is the
  only time being on top does anything.

The window also no longer follows the active space (`.moveToActiveSpace` is
cleared), so it stays on the display you parked it on.

Above roughly 700pt of width, projects flow into multiple columns instead of
one stretched column, so a tiled half-display or a full screen reads as a
board. At the default 440pt it is the same single column as before.

## Mini deck

The main window assumes a display you can give it. On a laptop there is no
such display, so `⌘⇧M` (View ▸ Show Mini Deck, or the button in the header)
opens a second window that is only the roster of agents actually in flight:

```
✈ 2
● watchtower                1m ◐
● flightdeck                7m ◐
```

Roughly 210 × 20pt per agent. Everything that is not a project name is either a
glyph or in the tooltip — hovering a row gives the headline, the branch and the
window it will jump to; clicking jumps there, exactly as in the main window.

What it shows is `SessionStore.activeSessions`: the running lane plus anything
in NEEDS ATTENTION. Finished agents are deliberately absent — a row that
lingers after the work is done is precisely the screen space the strip exists
to save — and an unknown status counts as running here for the same reason it
does everywhere else, so an agent can never go missing from it. A "needs you"
agent keeps the bell glyph and gets an amber clock; that is the only second
colour on the strip.

Three window behaviours are the whole point, and are why `MiniDeckController`
drives an `NSPanel` directly instead of adding a SwiftUI `Window` scene:

- It stays at `.floating` unconditionally. The main window deliberately drops
  to `.normal` while Flightdeck is active so it can be full-screened and tiled
  (see below); the strip wants none of that.
- `.canJoinAllSpaces` + `.fullScreenAuxiliary` puts it over a terminal that is
  itself full screen, which is the usual shape of working on one display.
- `.nonactivatingPanel` means clicking a row hands focus straight to the
  terminal the agent runs in, rather than routing through Flightdeck first.

The panel is borderless: with `.titled` the frame carries a titlebar's height
even under `.fullSizeContentView`, which on a strip this small is a third of it
again in transparent dead space. Height follows the roster
(`NSHostingController.sizingOptions`), and the top-left corner is held still
across those resizes so the list grows downwards instead of creeping towards
the menu bar. Position is remembered between launches, as is whether the strip
was open.

The store's file watchers are reference counted, so the strip keeps the data
live on its own — closing the main window does not freeze it.

## Known caveats

- `~/.claude/sessions/*.json` is **internal and undocumented**. A Claude Code
  update could change or remove it. Decoding is defensive (every field beyond
  `pid` is optional), but a format change would need a fix here.
  `claude agents --json` is the documented equivalent and the intended fallback.
- Whether `waiting` always means "needs you" is unconfirmed — it may also cover
  a session simply sitting at an empty prompt. Retune the mapping in
  `Activity.init(raw:)` if the NEEDS ATTENTION lane proves noisy.
- A crashed agent can leave a stale `busy` record. The relative timestamp is
  the tell: `busy` for hours means the process died mid-turn.
- `cachedUsageUtilization` in `~/.claude.json` is undocumented and, on its
  own, often hours stale — install the status-line tap for numbers you can act
  on. `rate_limits` in the status line **is** documented, but appears only for
  Claude.ai subscribers and only after a session's first API response.
- Generated titles describe the session's *opening* intent and are cached for
  its lifetime. A long session that has moved on to something else keeps its
  original title. Delete `titles.json` to regenerate.

## Not built yet

Notification on hand-back (`SessionStore.onHandback` is wired and unused),
launch-at-login, app icon.
