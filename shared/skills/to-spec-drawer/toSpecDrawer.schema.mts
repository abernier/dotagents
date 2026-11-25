import { z } from "zod";

const id = z
  .string()
  .regex(/^[A-Za-z0-9][A-Za-z0-9_-]*$/)
  .describe("Short stable key, shown to the user and sent back on publish.");

const optionSchema = z.object({
  id,
  drawer: id.describe("Drawer this option is listed under."),
  label: z.string().min(1).describe("One-line name of the option."),
  summary: z
    .string()
    .optional()
    .describe("One sentence on what it adds; also used under Out of Scope."),
  parent: id
    .optional()
    .describe("Option this one refines. Ticking it ticks the parent."),
  requires: z
    .array(id)
    .optional()
    .describe("Other options this one cannot ship without, beyond its parent."),
  exclusiveGroup: z
    .string()
    .optional()
    .describe("Options sharing a group are alternatives: at most one ticked."),
  default: z
    .boolean()
    .optional()
    .describe(
      "The alternative ticked when its parent is ticked and none is yet.",
    ),
  userStories: z
    .array(z.string())
    .default([])
    .describe("'As an X, I want Y, so that Z' lines this option contributes."),
  implementationDecisions: z
    .array(z.string())
    .default([])
    .describe("Implementation decisions this option contributes."),
  testingDecisions: z
    .array(z.string())
    .default([])
    .describe("Testing decisions this option contributes."),
});

/**
 * A spec whose scope is still open: the always-true parts (problem, solution)
 * plus every candidate option, grouped in drawers. The user ticks a subset;
 * `assemble` turns the model and that subset into the spec body.
 */
export const specModelSchema = z
  .object({
    title: z.string().min(1).describe("Title of the issue to publish."),
    problem: z.string().min(1).describe("Problem Statement, user's view."),
    solution: z.string().min(1).describe("Solution, user's view."),
    furtherNotes: z.string().optional().describe("Further Notes section."),
    outOfScope: z
      .array(z.string())
      .default([])
      .describe("Things out of scope whatever the user ticks."),
    selected: z
      .array(id)
      .default([])
      .describe("Options ticked when the picker opens: the recommended scope."),
    drawers: z
      .array(
        z.object({
          id,
          title: z.string().min(1),
          summary: z.string().optional(),
        }),
      )
      .min(1),
    options: z.array(optionSchema).min(1),
  })
  .superRefine((model, context) => {
    const issue = (message: string) =>
      context.addIssue({ code: "custom", message });
    const drawerIds = new Set(model.drawers.map((drawer) => drawer.id));
    const options = new Map(model.options.map((option) => [option.id, option]));
    if (drawerIds.size !== model.drawers.length)
      issue("Drawer ids must be unique.");
    if (options.size !== model.options.length)
      issue("Option ids must be unique.");

    for (const option of model.options) {
      if (!drawerIds.has(option.drawer))
        issue(`${option.id}: unknown drawer ${option.drawer}.`);
      for (const needed of [option.parent ?? [], option.requires ?? []].flat())
        if (!options.has(needed))
          issue(`${option.id}: unknown option ${needed}.`);
      if (option.default && !option.exclusiveGroup)
        issue(`${option.id}: default needs an exclusiveGroup.`);
    }
    for (const selected of model.selected)
      if (!options.has(selected))
        issue(`selected: unknown option ${selected}.`);

    const groups = new Map<string, typeof model.options>();
    for (const option of model.options)
      if (option.exclusiveGroup)
        groups.set(option.exclusiveGroup, [
          ...(groups.get(option.exclusiveGroup) ?? []),
          option,
        ]);
    for (const [group, members] of groups) {
      if (new Set(members.map((member) => member.parent)).size !== 1)
        issue(`Group ${group}: alternatives must share one parent.`);
      if (members.filter((member) => member.default).length > 1)
        issue(`Group ${group}: at most one default.`);
      if (members.some((member) => member.default) && !members[0].parent)
        issue(`Group ${group}: a default needs a parent to be pulled in by.`);
    }

    // A cycle would make ticking and unticking undecidable.
    const visiting = new Set<string>();
    const done = new Set<string>();
    const visit = (optionId: string): boolean => {
      if (done.has(optionId)) return false;
      if (visiting.has(optionId)) return true;
      visiting.add(optionId);
      const option = options.get(optionId);
      const needed = option
        ? [option.parent ?? [], option.requires ?? []].flat()
        : [];
      const cyclic = needed.some(visit);
      visiting.delete(optionId);
      done.add(optionId);
      return cyclic;
    };
    for (const option of model.options)
      if (visit(option.id)) {
        issue(`${option.id}: parent/requires form a cycle.`);
        break;
      }
  });

/** A validated spec model, defaults applied. */
export type SpecModel = z.infer<typeof specModelSchema>;
