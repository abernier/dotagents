---
name: to-spec-drawer
description: Run /to-spec with a scope picker — the candidate options in dependent drawers, the live spec below, publish the ticked subset. Use when the user types /to-spec-drawer.
disable-model-invocation: true
---

`/to-spec` with one step swapped: the user picks the spec's **scope** before it is
published. `to-spec` stays the owner of everything else — the template, the seams,
the tracker and the `ready-for-agent` label.

## Follow to-spec

Glob `~/.claude/plugins/cache/*/mattpocock-skills/*/skills/engineering/to-spec/SKILL.md`,
take the highest version, read it, and follow it as your instructions. Its step 3
("write the spec, then publish") runs as the steps below instead.

## The scope step

1. **Model.** Write the spec as a model file in your scratchpad
   (`<slug>.spec-model.json`): the parts true whatever is ticked (title, problem,
   solution, further notes, fixed out-of-scope items), and every candidate the
   conversation raised as an **option** carrying its own user stories,
   implementation decisions and testing decisions. Shape:
   [`toSpecDrawer.example.json`](toSpecDrawer.example.json); each field is
   described in [`toSpecDrawer.schema.mts`](toSpecDrawer.schema.mts).
   - One option per piece the user could ship or drop on its own.
   - `parent`: the option it refines. `requires`: what else it cannot ship without.
   - `exclusiveGroup` + `default`: alternatives under one parent; the default is
     ticked when the parent is.
   - `selected`: your recommended scope, so the picker opens on it.
2. **Validate.** `to-spec-drawer validate <model>` until it prints `ok`.
3. **Show.** `to-spec-drawer render <model>` prints an HTML fragment; pass it
   verbatim as `show_widget`'s `widget_code`. Without `show_widget`, list each
   drawer's options as `id label` lines, say which ids you recommend, and ask for
   the id list. End the turn there.
4. **Assemble.** The answer comes back as
   `Publish the /to-spec-drawer spec <model> with: <ids>` (or as typed ids). Run
   `to-spec-drawer assemble <model> --select <ids>`: the body on stdout, the title
   on stderr. It closes the selection over its requirements; an error means two
   alternatives were ticked — say so and show the picker again.
5. **Publish** that title and body as `to-spec` says. The body goes out verbatim:
   it is the preview the user approved. Report the issue link.

## What the picker does

Ticking an option ticks its parent and requirements, unticks a ticked alternative,
and ticks the default of each alternative group under it. Unticking an option
unticks everything that needs it. Every unticked option lands under Out of Scope.
The widget, `assemble` and the tests share one implementation,
[`toSpecDrawer.mts`](toSpecDrawer.mts).

`to-spec-drawer` is on PATH once the harness is installed; otherwise call
`bin/to-spec-drawer` in this skill's directory.
