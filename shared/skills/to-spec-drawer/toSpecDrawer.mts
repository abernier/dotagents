// Pure and dependency-free: `toSpecDrawer.render.mts` inlines this file, types
// stripped, into the picker, so the widget and the CLI run the same rules.
// Keep it to erasable TypeScript and type-only imports.
import type { SpecModel } from "./toSpecDrawer.schema.mts";

type Option = SpecModel["options"][number];

/**
 * Section headings of `to-spec`'s template, in its order. `to-spec` owns
 * them; a test fails when its installed SKILL.md drifts from this list.
 */
export const SPEC_HEADINGS = [
  "Problem Statement",
  "Solution",
  "User Stories",
  "Implementation Decisions",
  "Testing Decisions",
  "Out of Scope",
  "Further Notes",
];

function optionsById(model: SpecModel) {
  return new Map(model.options.map((option) => [option.id, option]));
}

/** What an option cannot be ticked without: its parent, then its requires. */
function needs(option: Option) {
  return [option.parent ?? [], option.requires ?? []].flat();
}

/** `ids` plus everything they transitively need. */
function withRequirements(model: SpecModel, ids: Iterable<string>) {
  const options = optionsById(model);
  const result = new Set<string>();
  const pending = [...ids];
  while (pending.length > 0) {
    const id = pending.pop()!;
    if (result.has(id)) continue;
    result.add(id);
    const option = options.get(id);
    if (option) pending.push(...needs(option));
  }
  return result;
}

/** `id` plus every option that transitively needs it. */
function withDependents(model: SpecModel, id: string) {
  const result = new Set([id]);
  let grew = true;
  while (grew) {
    grew = false;
    for (const option of model.options)
      if (
        !result.has(option.id) &&
        needs(option).some((needed) => result.has(needed))
      ) {
        result.add(option.id);
        grew = true;
      }
  }
  return result;
}

function alternativesOf(model: SpecModel, option: Option) {
  return model.options.filter(
    (other) =>
      option.exclusiveGroup &&
      other.exclusiveGroup === option.exclusiveGroup &&
      other.id !== option.id,
  );
}

/**
 * Tick `id`: its parent and requirements come with it, a ticked alternative
 * goes (with what depends on it), and each alternative group under a newly
 * ticked option gets its default when none of the group is ticked yet.
 *
 * @param model Validated spec model.
 * @param selected Currently ticked ids.
 * @param id Option to tick.
 */
export function check(
  model: SpecModel,
  selected: Iterable<string>,
  id: string,
) {
  const next = new Set(selected);
  const pending = [id];
  while (pending.length > 0) {
    for (const added of withRequirements(model, [pending.pop()!])) {
      if (next.has(added)) continue;
      next.add(added);
      const option = optionsById(model).get(added)!;
      for (const alternative of alternativesOf(model, option))
        for (const dropped of withDependents(model, alternative.id))
          next.delete(dropped);
      const children = model.options.filter(
        (child) => child.parent === added && child.exclusiveGroup,
      );
      for (const group of new Set(
        children.map((child) => child.exclusiveGroup),
      )) {
        const members = children.filter(
          (child) => child.exclusiveGroup === group,
        );
        const fallback = members.find((member) => member.default);
        if (fallback && !members.some((member) => next.has(member.id)))
          pending.push(fallback.id);
      }
    }
  }
  return next;
}

/**
 * Untick `id` and every option that needs it.
 *
 * @param model Validated spec model.
 * @param selected Currently ticked ids.
 * @param id Option to untick.
 */
export function uncheck(
  model: SpecModel,
  selected: Iterable<string>,
  id: string,
) {
  const next = new Set(selected);
  for (const dropped of withDependents(model, id)) next.delete(dropped);
  return next;
}

/**
 * The picker's opening state: the model's recommended options, ticked one by
 * one so their requirements and defaults come along.
 *
 * @param model Validated spec model.
 */
export function initialSelection(model: SpecModel) {
  return model.selected.reduce<Set<string>>(
    (selected, id) => check(model, selected, id),
    new Set(),
  );
}

/**
 * Re-derive a selection sent back by the picker: unknown ids and two ticked
 * alternatives are errors, missing requirements are added. The closure, not
 * the widget's state, is what gets published.
 *
 * @param model Validated spec model.
 * @param ids Ids the user ticked.
 */
export function closeSelection(model: SpecModel, ids: Iterable<string>) {
  const options = optionsById(model);
  for (const id of ids)
    if (!options.has(id)) throw new Error(`Unknown option ${id}.`);
  const closed = withRequirements(model, ids);
  const groups = new Map<string, string>();
  for (const id of closed) {
    const group = options.get(id)!.exclusiveGroup;
    if (!group) continue;
    const other = groups.get(group);
    if (other)
      throw new Error(`${other} and ${id} are alternatives; tick only one.`);
    groups.set(group, id);
  }
  return closed;
}

/**
 * The spec body for a selection, laid out as `to-spec`'s template: the ticked
 * options contribute their stories and decisions, every unticked one is listed
 * under Out of Scope.
 *
 * @param model Validated spec model.
 * @param selected Ticked ids, already closed.
 */
export function assemble(model: SpecModel, selected: Iterable<string>) {
  const ticked = new Set(selected);
  const kept = model.options.filter((option) => ticked.has(option.id));
  const left = model.options.filter((option) => !ticked.has(option.id));
  const numbered = (lines: string[]) =>
    lines.map((line, index) => `${index + 1}. ${line}`).join("\n");
  const bullets = (lines: string[]) =>
    lines.map((line) => `- ${line}`).join("\n");
  const orNone = (text: string) => text || "None.";
  const [
    problem,
    solution,
    stories,
    implementation,
    testing,
    outOfScope,
    notes,
  ] = SPEC_HEADINGS;

  const sections = [
    [problem, model.problem],
    [solution, model.solution],
    [stories, orNone(numbered(kept.flatMap((option) => option.userStories)))],
    [
      implementation,
      orNone(bullets(kept.flatMap((option) => option.implementationDecisions))),
    ],
    [
      testing,
      orNone(bullets(kept.flatMap((option) => option.testingDecisions))),
    ],
    [
      outOfScope,
      orNone(
        bullets([
          ...left.map((option) =>
            option.summary
              ? `${option.label}: ${option.summary}`
              : option.label,
          ),
          ...model.outOfScope,
        ]),
      ),
    ],
    ...(model.furtherNotes ? [[notes, model.furtherNotes]] : []),
  ];
  return `${sections.map(([heading, body]) => `## ${heading}\n\n${body}`).join("\n\n")}\n`;
}
