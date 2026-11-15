# Constellation

A native macOS control room for running many coding-agent sessions at once and keeping finished work out of the way.

## Language

**Session**:
One run of a coding agent on one piece of work, launched by Constellation inside a Project.
_Avoid_: Thread, agent, task, job

**Provider**:
The coding agent that runs a Session: Claude Code or Codex.
_Avoid_: Agent, model, backend

**Project**:
A git repository that Constellation launches Sessions in.
_Avoid_: Repo, workspace

**Host**:
The machine a Session runs on: this Mac, or a remote machine reached over ssh.
_Avoid_: Server, runner, machine

**Run state**:
What a Session's Provider is doing right now: working, blocked, failed, done or interrupted.
_Avoid_: Status

**Lifecycle**:
How far a Session has receded from your attention: unseen, seen, kept, settled, merged, idle, archived. Finished work you've seen settles once you move on from it; kept is work brought back out of the Settled tray by hand.
_Avoid_: Stage, age

**Ask**:
A request from a Session that blocks it until you answer. One of three kinds: Permission, Question, Secret.
_Avoid_: Prompt, approval, request, input

**Outcome**:
The agent's own report, at the end of a turn, of whether its task succeeded or failed, with a one-line summary.
_Avoid_: Result, exit code

**Terminal**:
A plain shell opened in a Project, a worktree, or a Session's worktree. It has no Asks and never recedes.
_Avoid_: Console, shell session

**Pile**:
The Sessions and Terminals working in one folder, stacked into one card's footprint with the most urgent on top unless you've dragged its cards into an order of your own. Every Project's piles share one desktop, each in its place in the Arrangement, named by a label under it in its Project's colour.
_Avoid_: Stack, island, group, project box

**Settled tray**:
The one Pile that every Project's settled, merged and idle Sessions gather into. It starts in the bottom-right corner.
_Avoid_: Settled pile, done pile

**Arrangement**:
How the desktop sets out its Piles, chosen in Settings: Constellation (the default) or Grid. Each keeps its own saved places, and in both a Pile moves only when you drag it by its label, never because its work changed.
_Avoid_: Layout, layout style

**Constellation**:
The Arrangement where each Pile rests at a Position: a Project's Piles drawn loosely together and joined by faint lines in its colour, Projects kept apart, with no boxes. A new Pile lands near its Project's other Piles; a dropped Pile stays just where it was let go, any Pile under it making way by as little as clears it.

**Position**:
Where a Pile's middle sits in the Constellation, saved by its folder as fractions of the desktop so it survives a change of window size.
_Avoid_: Coordinates

**Slot**:
A place on the desktop's grid, in the Grid Arrangement, holding one Pile. A Pile keeps its Slot, saved by its folder, until you drag it by its label to another (swapping with any Pile there); a new Pile takes the free Slot nearest its Project's other Piles. Piles never move because their work changed.
_Avoid_: Cell, position

**Clean-up**:
Archiving receded Sessions: their worktrees, caches and merged branches are removed and their transcripts kept.
_Avoid_: Delete, prune

**Composer**:
The chat box on a Session, in the session view, inline on a focused tile, and as a Draft's first-message field.
_Avoid_: Reply box, input, chat field

**Session view**:
The compact chat view a Session opens into over the desktop: its transcript, Composer and pending Ask. ↵, space or a double-click opens it; esc closes it. Bloom removed on 2026-11-04 in favour of the compact chat view: it is the one way to look closer at a tile.
_Avoid_: Bloom, split focus

**Draft**:
A new Session before its first message is sent: a dashed tile and a panel of settings pills. Nothing is on disk and no process runs until it starts; an empty one is thrown away on esc.
_Avoid_: Pending session, new-session sheet

**Queued message**:
A message sent while a turn runs. It waits, with the others in order, and goes out when the turn finishes.
_Avoid_: Pending message, draft

**Steer**:
Sending a message into the running turn instead of queueing it (⌘↵).
_Avoid_: Interrupt, inject

**Attachment**:
A file or image sent with a message. Constellation keeps its own copy, so transcripts keep it after Clean-up.
_Avoid_: Upload, file

**Checkpoint**:
What Constellation records with each message you send: where the Provider can cut the conversation just before it, and a snapshot of the worktree kept under a hidden ref.
_Avoid_: Snapshot, savepoint

**Rewind**:
Taking a Session back to just before one of your messages, dropping that message and everything after it, and optionally putting the files back as they were.
_Avoid_: Undo, rollback, revert

**Fork**:
A new Session, in its own worktree, that starts with a copy of another Session's conversation up to the end of one message's turn.
_Avoid_: Branch, clone, duplicate

**Turn settings**:
The model, reasoning effort, fast mode and permission mode the next turn runs with. Changed from the pickers; they apply from the next message.
_Avoid_: Options, config

**Git action**:
Commit, Push or Create PR on a Session's worktree, from the session view header or the tile menu. Runs git and `gh` directly; no model call.
_Avoid_: Ship, publish, sync

**Slash command**:
An entry in the Composer's `/` menu: a Claude Code command or skill, or a Codex skill. Claude Code gets `/name`; Codex gets `$name` plus a skill input item.
_Avoid_: Macro, action

**Mention**:
An `@path` in a message naming a file in the Session's worktree, picked from the `@` menu.
_Avoid_: Reference, tag

**Prompt history**:
The prompts sent in a Project, newest first, that ↑ walks through in an empty Composer.
_Avoid_: Recent messages, recall
