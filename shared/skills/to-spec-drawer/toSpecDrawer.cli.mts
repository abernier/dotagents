import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { parseArgs } from "node:util";
import { assemble, closeSelection } from "./toSpecDrawer.mts";
import { renderPicker } from "./toSpecDrawer.render.mts";
import { specModelSchema } from "./toSpecDrawer.schema.mts";

const usage = `Usage:
  to-spec-drawer validate <model.json>
  to-spec-drawer render <model.json>                  picker HTML for show_widget
  to-spec-drawer assemble <model.json> --select A1,B2 spec body, title on stderr`;

function loadModel(path: string | undefined) {
  if (!path) throw new Error(usage);
  const parsed = specModelSchema.safeParse(
    JSON.parse(readFileSync(path, "utf8")),
  );
  if (!parsed.success)
    throw new Error(
      parsed.error.issues
        .map((issue) => `${issue.path.join(".") || "model"}: ${issue.message}`)
        .join("\n"),
    );
  return parsed.data;
}

function main(argv: string[]) {
  const { positionals, values } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: { select: { type: "string" } },
  });
  const [command, file] = positionals;
  const model = loadModel(file);
  switch (command) {
    case "validate":
      process.stdout.write(`ok: ${model.options.length} options\n`);
      return;
    case "render":
      process.stdout.write(renderPicker(model, resolve(file!)));
      return;
    case "assemble": {
      const ids = (values.select ?? "").split(",").filter(Boolean);
      const body = assemble(model, closeSelection(model, ids));
      process.stderr.write(`${model.title}\n`);
      process.stdout.write(body);
      return;
    }
    default:
      throw new Error(usage);
  }
}

try {
  main(process.argv.slice(2));
} catch (error) {
  process.stderr.write(
    `${error instanceof Error ? error.message : String(error)}\n`,
  );
  process.exit(1);
}
