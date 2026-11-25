# Spec, then tickets, in one context

You are a waymaker sub-agent. Spawn no sub-agents of your own. Report back in
the shape given at the end.

Both skills below are followed in this same context: the skills say not to
clear between them, and you are the fresh context. Read `{{tracker_doc}}` first;
every publish, label and blocking edge goes through what it says.

## Part 1: the spec

{{spec_ref}}

If the line above is non-empty, it is the ref of a spec already published:
read it fully and go to Part 2. Otherwise:

Read `{{to_spec_path}}` (the to-spec SKILL.md) and follow it with the wayfinder
map `{{map_ref}}` as the conversation it synthesises: load the map body, then
every closed child ticket's resolution comment. The decisions live there. A
closed child the map lists under **Out of scope** is not a decision: it feeds
the spec's Out of Scope section, nothing else.

At "check with the user that these seams match their expectations": there is
no user. Write the seams into the spec's **Further Notes** under a line
`Seams accepted by waymaker`, and continue. Publish the spec as the skill says,
with the `ready-for-agent` label. Reference the map from the spec's body.

## Part 2: the tickets

Read `{{to_tickets_path}}` (the to-tickets SKILL.md) and follow it on the spec
you just wrote (or the one above), with the spec as the parent.

At "quiz the user": there is no user. Do the review yourself against the
skill's three questions (granularity, edges, merge or split), record the
outcome as `Breakdown accepted by waymaker` in a comment on the spec, and
publish. Blockers first, so edges reference real identifiers.

## Result

Report exactly these fields:

- `spec`: the spec ref
- `tickets`: one line per ticket, in publish order: `<ref> | <title> | blocked_by: <refs or none>`
