import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import type { SpecModel } from "./toSpecDrawer.schema.mts";

/** The pure core as a classic browser script: types and `export` stripped. */
function coreScript() {
  const source = readFileSync(
    new URL("./toSpecDrawer.mts", import.meta.url),
    "utf8",
  );
  return stripTypeScriptTypes(source).replace(/^export /gm, "");
}

/** JSON safe to drop inside a `<script>` element. */
function scriptJson(value: unknown) {
  return JSON.stringify(value).replace(/</g, "\\u003c");
}

/**
 * The scope picker as an HTML fragment for `show_widget`: one drawer per
 * group, one checkbox per option, the live spec below, and a Publish button
 * that hands the ticked ids back to the agent through `sendPrompt`.
 *
 * @param model Validated spec model.
 * @param sourcePath Absolute path of the model file, quoted in the publish message.
 */
export function renderPicker(model: SpecModel, sourcePath: string) {
  return `<style>
.tsd-drawer{border:0.5px solid var(--border);border-radius:12px;padding:0.75rem 1rem;margin:0 0 0.75rem}
.tsd-drawer>summary{cursor:pointer;font-weight:500}
.tsd-option{display:flex;gap:8px;align-items:flex-start;padding:4px 0;cursor:pointer}
.tsd-option input{margin-top:5px}
.tsd-hint{font-size:13px;color:var(--text-secondary);line-height:1.5}
.tsd-preview{white-space:pre-wrap;font-family:var(--font-mono);font-size:12px;line-height:1.6;background:var(--surface-1);border-radius:var(--radius);padding:1rem;margin:0}
</style>
<h2 class="sr-only">Scope picker for the spec ${escapeHtml(model.title)}: tick options, the spec below updates, publish sends the selection.</h2>
<div id="tsd-drawers" style="padding:1rem 0 0"></div>
<div style="display:flex;align-items:center;gap:12px;margin:0.5rem 0 1rem">
  <button id="tsd-publish" type="button">Publish spec ↗</button>
  <span id="tsd-count" class="tsd-hint"></span>
</div>
<p id="tsd-fallback" class="tsd-hint" style="display:none"></p>
<pre id="tsd-preview" class="tsd-preview"></pre>
<script>
${coreScript()}
const model = ${scriptJson(model)};
const sourcePath = ${scriptJson(sourcePath)};
let selected = initialSelection(model);
const boxes = new Map();

function depth(option) {
  let level = 0;
  for (let at = option; at.parent; level++)
    at = model.options.find((other) => other.id === at.parent);
  return level;
}

function inTreeOrder(options) {
  const ids = new Set(options.map((option) => option.id));
  const ordered = [];
  const visit = (option) => {
    ordered.push(option);
    for (const child of options.filter((other) => other.parent === option.id))
      visit(child);
  };
  for (const option of options)
    if (!option.parent || !ids.has(option.parent)) visit(option);
  return ordered;
}

for (const drawer of model.drawers) {
  const details = document.createElement("details");
  details.className = "tsd-drawer";
  details.open = true;
  const summary = document.createElement("summary");
  summary.textContent = drawer.id + " " + drawer.title;
  details.append(summary);
  if (drawer.summary) {
    const hint = document.createElement("div");
    hint.className = "tsd-hint";
    hint.textContent = drawer.summary;
    details.append(hint);
  }
  const options = model.options.filter((option) => option.drawer === drawer.id);
  for (const option of inTreeOrder(options)) {
    const label = document.createElement("label");
    label.className = "tsd-option";
    label.dataset.option = option.id;
    label.style.paddingLeft = depth(option) * 24 + "px";
    const box = document.createElement("input");
    box.type = option.exclusiveGroup ? "radio" : "checkbox";
    // No preventDefault: a cancelled click reverts the box after refresh() set it.
    box.addEventListener("click", () => {
      selected = selected.has(option.id)
        ? uncheck(model, selected, option.id)
        : check(model, selected, option.id);
      refresh();
    });
    boxes.set(option.id, box);
    const text = document.createElement("div");
    const name = document.createElement("div");
    name.textContent = option.id + " " + option.label;
    text.append(name);
    const notes = [option.summary, option.requires?.length ? "Requires " + option.requires.join(", ") : ""]
      .filter(Boolean)
      .join(" ");
    if (notes) {
      const hint = document.createElement("div");
      hint.className = "tsd-hint";
      hint.textContent = notes;
      text.append(hint);
    }
    label.append(box, text);
    details.append(label);
  }
  document.getElementById("tsd-drawers").append(details);
}

function tickedIds() {
  return model.options.filter((option) => selected.has(option.id)).map((option) => option.id);
}

function refresh() {
  for (const [id, box] of boxes) box.checked = selected.has(id);
  document.getElementById("tsd-count").textContent =
    selected.size + " of " + model.options.length + " options in scope";
  document.getElementById("tsd-preview").textContent =
    "# " + model.title + "\\n\\n" + assemble(model, selected);
}

document.getElementById("tsd-publish").addEventListener("click", () => {
  const message =
    "Publish the /to-spec-drawer spec " + sourcePath + " with: " + tickedIds().join(",");
  if (typeof sendPrompt === "function") return sendPrompt(message);
  const fallback = document.getElementById("tsd-fallback");
  fallback.textContent = "Send this to the agent: " + message;
  fallback.style.display = "block";
});

refresh();
</script>
`;
}

function escapeHtml(text: string) {
  return text.replace(
    /[&<>"]/g,
    (character) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[character]!,
  );
}
