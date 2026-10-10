# Scott Jenson on desktop UX, 2026-10-10

Scott Jenson was the first member of Apple's Human Interface group, and
designs today for Mastodon and Home Assistant. He has given two recent
talks arguing that desktop UX has stood still for twenty years and that
open source should lead it now that Apple and Microsoft no longer take the
risk. This note records what they propose, what Todhchai can borrow, and
the amendments to [../desktop.md](../desktop.md) proposed for decision.

Read from write-ups, not transcripts: LWN's report of the second talk and
a detailed Japanese summary of both had the most; the videos are the
primary source (see Sources). The first talk's "learning loops" are named
in every account and explained in none; watch it before relying on them.

## The talks

1. **"Are we stuck with the same Desktop UX forever?"**, Ubuntu Summit
   25.10, London, 2025-10-24. Its argument: "UX/UI" sets programmers and
   designers against each other by shrinking UX to pixels; thought of as
   user experience, the desktop has far more room to move. It drew more
   than half a million views on YouTube.
2. **"Are we really going to use the same Desktop UX forever?"**, KDE
   Akademy 2026, Graz, September 2026. The follow-up, with working
   prototypes built to pose questions, not to settle them.

## His framing

- **Four layers of UX:** *style* (whitespace, icons, colour), *structure*
  (navigation, how one moves through an app), *strategy* (who it is for,
  and what to leave out: "a designer's best value is helping a team say
  no"), and *stuff* (the technology and historical cruft beneath, which
  bounds the rest). Lasting change has to reach the bottom layer.
- **Three objections, answered.** "Mobile won": consumption, not
  productive work. "WIMP is done": there is plenty left to explore. "Don't
  touch my stuff": fair, so change comes as additions beside what works.
- **Assumptions carried forward.** Overlapping windows came from the
  first Mac's small screen; today's wide monitors want another model.
- **The curse of direct manipulation:** it is fast and forgets. The
  clipboard overwrites itself; yesterday's context has to be rebuilt. The
  desktop should help people remember.
- **History was early, not wrong.** Lifestreams (a chronological stream of
  one's data), WinFS (a database under the file system, cancelled in 2006)
  and KDE 4's NEPOMUK semantic desktop (narrowed later to Baloo) failed on
  the hardware and systems of their day.
- **Method, after Alan Kay:** understand the present, know the past, make
  the questions clear before reaching for answers. Run research as Ink &
  Switch does: small teams, quick prototypes, published openly, offered as
  options beside the existing desktop.
- **AI:** context, not generation, is what made it useful (an agent given
  the file system). Most desktop AI enters from the top (a chatbot driving
  the OS, "a chatbot with AppleScript") or the bottom (automation); the
  middle is empty. He prefers small, ethically trained models run locally
  (Switzerland's Apertus) and would design for people first: "If the AI
  can use it, great. I don't care. That comes later."

## His examples and prototypes

1. **Middle truncation** of long names (from the 1984 Finder), so both
   ends stay readable.
2. **Select on press, raise on release.** On the Mac a click selects at
   once but raises the window only when the button comes up, so an item
   can be dragged out of a background window. Most Linux desktops raise on
   press. A KDE developer separated the two within hours of his post.
3. **Widescreen-first windows.** The work sits in the middle of the
   screen, about half its width; the sides hold other windows, shrunk but
   live and usable, in place of virtual desktops ("most people struggle
   with them"). Shaking a window pushes the rest aside. Responsive design
   from the web, feasible on Wayland.
4. **The stash.** A music player dragged to the edge reflows into a play
   button.
5. **A document's drawer:** a persistent, clipboard-like canvas (after
   Obsidian's Canvas) attached to each document. Text, images, files and
   web content dropped there stay after the document closes; a local model
   may organize them (several hotels found, grouped, put on a map in the
   document). Reviewed side by side with the document: "a baby virtual
   desktop".
6. **An attention history.** It records signals, not content: dwell time,
   scrolling, that a copy or paste happened but not what. Plain arithmetic,
   no AI, folded fifty pages read about e-bikes into seven milestones on a
   timeline (searches, key pages, saves), each linked back to where it
   came from; across the desktop it would trace an email to a document to
   an image. His answer to Windows Recall's honeypot: signals are worth
   far less to an attacker than content. Prove it useful first, then
   decide how to protect it. A browser extension for now, to be published.

## What Todhchai already has

Several of his asks are already in Todhchai's foundations.

- **Taisce is the semantic desktop he says deserves another try**, kept to
  a narrow scope (filesystem.md): typed attributes on every file, indices,
  queries and live queries, a journal, all in the file system, with
  Tracker showing queries as folders. NEPOMUK's lesson matches the choice
  already made: attributes and queries, not a general graph of linked data.
- **The shell's intent stream** (desktop.md §3, "Scripting"): every app
  publishes the user's intents (commands, opens, selections) as a stream
  others can subscribe to. That is most of an attention history's input.
- **The router** carries every "open this" with its source app, type and
  an entry reference: provenance comes with each hand-off.
- **Clipboard, drag and drop and IME are services of their own** (desktop.md
  §1), not compositor internals, so a persistent clipboard is a change to
  one service.
- **Window management is the server's**, and clients get `configure`
  events with a `configSeq` (§2): the compositor can change a window's
  shape and the app answers before it is shown.
- **Replicants** are already small out-of-process views on the desktop: a
  stashed window is close kin.
- **The hosted SDK runs on Linux under Wayland now**, so prototypes need
  not wait for M8's desktop.

## Amendments

Proposed as independent decisions; 1 to 9 were accepted on 2026-10-10 and
are in the roadmap's "Decided" list, [../desktop.md](../desktop.md) (§0,
§1, §2, §3), [../sdk.md](../sdk.md) (§4, §10) and
[../filesystem.md](../filesystem.md) (§6). 10 is open: the place of AI in
this desktop is not yet decided, neither excluded nor adopted.

1. **Press selects, release raises** (desktop.md §1, input). Radharc
   raises and focuses a background window when the button is released
   without a drag, never on the press; a drag that starts in a background
   window leaves the stacking alone. The same for touch.
2. **Truncate in the middle** (sdk.md, the UI Kit). The UI Kit's label and
   list views elide in the middle by default, keeping a file's extension;
   end elision is an option for prose.
3. **A focus area and a live periphery** (desktop.md §2), as a window
   management mode beside stacking and tiling, per workspace. The middle
   of a wide output holds the windows being worked in; the sides hold the
   others scaled down, live, and usable in place. Workspaces stay, no
   longer the main answer to too many windows.
4. **Stashed windows** (desktop.md §2, sdk.md §4). A window dragged to an
   edge is *stashed*: its `configure` event carries a compact size class,
   and the app may reflow into a minimal form (a player into its play
   button) or let the compositor show it scaled. The UI Kit gives a
   default compact form; a stashed window is laid out with the replicants.
5. **The drawer** (desktop.md §3, Tracker and the clipboard service). The
   clipboard keeps its history as files with attributes (`Clip:Source`,
   the app's signature, `Clip:Origin`, an entry reference, `Clip:Time`),
   and any document may have a drawer: clips linked to it by attribute,
   shown beside it, kept after it closes, found by query. Size and age
   limits per user.
6. **Provenance attributes** (filesystem.md, the Storage Kit). A file made
   by save, download, paste or a translator records where it came from
   (`Sys:Origin`: an entry reference or URL; `Sys:OriginApp`). Tracker
   shows it and can query by it.
7. **An attention history, opt-in** (desktop.md §3). A small service
   folds the intent stream and the router's messages into a timeline of
   signals: opens, saves, dwell, that a copy happened. It never records
   content, keeps everything local in the user's Taisce volume, is off
   until turned on, is listed in the Inspector, and is cleared with one
   command. Tracker shows the timeline.
8. **Layers in desktop.md.** Rework desktop.md around his four layers:
   the look (§6) is style; amendments 3 to 7 are structure; a strategy
   section names who the desktop is for and what it leaves out.
9. **Prototype first, on the hosted SDK.** Amendments 3 to 7 are tried as
   opt-in prototypes on Linux, as Ink & Switch would, before M8 makes any
   of them a default.
10. **AI, later and in the middle** (open). Nothing in the desktop depends on a
    model. If one is added, it is small, local, optional, and works on
    what Taisce and the drawer already gathered (grouping, summarising),
    never as a chatbot driving the system.

## Sources

- Ubuntu Summit 25.10 session page:
  https://discourse.ubuntu.com/t/are-we-stuck-with-the-same-desktop-ux-forever/67253
- The 2025 talk on video: https://youtu.be/1fZTOjd_bOQ
- KDE Akademy 2026 listing: https://conf.kde.org/event/11/contributions/332/
  (recording on media.ccc.de)
- LWN's report of the Akademy 2026 talk:
  https://lwn.net/SubscriberLink/1095425/62d3ef7aa7c889a3/
- A summary of both talks (Japanese):
  https://qiita.com/spumoni/items/b79f562f118a4f5afed1
- The New Stack:
  https://thenewstack.io/ux-pioneer-scott-jenson-on-unsticking-computer-desktop-design
- Karl Voit's note:
  https://karl-voit.at/2026/04/06/Are-we-stuck-with-the-same-Desktop-UX-forever
- Hacker News discussion: https://news.ycombinator.com/item?id=46256834
