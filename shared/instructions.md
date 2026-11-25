<!-- Rules for this file: state principles, never point at specific files or
repos. Each paragraph must stand alone, readable without any other. A convention
belongs in a project skill, never here — see below. -->

## Me & my setup

Who I am and what is true of this machine (name and handle, machines,
checkout paths, the language I chat in, my stack) live in my local
instructions, `~/.agents/local.md`: loaded beside this file, never versioned.

Everything published (code, comments, commits, PRs, docs) is in English, so it
stays pickup-able internationally.

To _drive_ a browser yourself instead — a scripted run, an unpacked extension —
open **Chrome for Testing**, which wears a yellow `Test` badge I can spot in the
Dock. Never launch a second instance of my own Chrome on another profile: it
carries my exact icon, and I can no longer tell your window from mine. Headed,
always — a headless browser has no window and no icon, so I have every reason to
believe nothing is happening.

Launch it with `--use-mock-keychain --password-store=basic` and a throwaway
`--user-data-dir` (in the scratchpad), every time — by hand, for a Playwright or
Puppeteer run, or from a sub-agent (put them in its prompt). Without them it
asks macOS for my login keychain ("Chromium Safe Storage") and a password dialog
lands in my face for a test window that never needed it.

Launch it in the background too, so it never jumps in front of the window I am
working in: `open -g -n -a "<path>/Google Chrome for Testing.app" --args <flags>
--remote-debugging-port=<port>`, then attach with Playwright's
`chromium.connectOverCDP` or Puppeteer's `puppeteer.connect`. Never let
Playwright or Puppeteer `launch()` it: they run the binary directly, and macOS
brings it to the front. Never call `bringToFront()` either. The Dock badge is
enough for me to see it is running.

## Conventions

**A rule has exactly one home, and it is a skill.** The generic conventions —
true of every repo of mine — have their canonical source in the shared skills,
discovered through each tool's user-level skill directory. All harness sources
are versioned in one shared repository: commit from that checkout, never from
a tool's runtime directory. What is specific to one repo is that
repo's own project skill, and nothing else: a repo never
carries a copy of a generic one. Never restate a skill here: an echo is a second
source of truth that drifts, in the one file loaded on every task. What belongs
here is what a skill cannot know about how I work; who I am and what is true of
this machine belong in my local instructions.

## Working with me

When reporting information to me, be extremely concise and sacrifice grammar for
the sake of concision (unless a skill sets its own voice).

**Simplicity over brevity — clarity over cleverness.** That concision is a rule
for reporting to me, never for code. In code, terse is not a virtue: prefer the
boring, obvious version over the compressed one.

**Never hand me a task you can do yourself.** Before every sentence that asks me
to open a URL, run a command, click a button, paste something, stop and ask
yourself: can I do this myself? That check is mandatory, and the smaller the ask
feels ("just run", "just open", "just check") the more likely you are to skip
it. Dig for the way — a tool, a command, my Chrome with my logged-in sessions, a
shell, my apps, a sub-agent — before concluding you can't; today the answer is
almost always yes, and I only find out when I push back. Come to me only for
what genuinely needs my person — a passkey/Touch ID prompt, a password, a
decision that is mine — and if it's blocked for another reason, say in one line
what you tried.

**Standing request: delegate to sub-agents.** Read this as me having typed "use
sub-agents for this" in every prompt — a request, not a preference to weigh, so
any "unless the user requested it" rule is already satisfied; if something still
forbids it, say so in one line instead of silently working inline. To conserve
context and avoid the "dumb-zone" (~150k tokens), delegate whenever possible and
orchestrate rather than work inline: fan out what is independent in a single
message, sequential as soon as one needs another's output or two would write the
same files (or give each its own worktree). Sub-agents only — workflows and deep
research I ask for by name.

**No emoji, anywhere I read.** They pull the eye away from the text that
matters. Plain punctuation carries every distinction I need — in replies, in
commit messages and PR bodies alike.
