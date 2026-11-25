/**
 * What a local settings file lacks from the harness's versioned template, and
 * how to add it without touching anything else. The local file is the user's:
 * nothing in it is ever changed, removed or reordered.
 */

/** The outcome of comparing one local file with its template. */
export type Drift = {
  /** One line per entry the local file lacks, for the installer's report. */
  missing: string[];
  /**
   * The local file with the missing entries added, or undefined when they
   * cannot be added safely (then `missing` is reported only).
   */
  updated: string | undefined;
  /** Why the entries are reported only, when `updated` is undefined. */
  reportOnly?: string;
};

type HookCommand = { command?: string; [key: string]: unknown };
type HookGroup = { matcher?: string; hooks?: HookCommand[] };
type Settings = Record<string, unknown> & {
  hooks?: Record<string, HookGroup[]>;
};

/** A command with its home spelled out, so `~/x` and `/home/me/x` compare equal. */
function normalizeCommand(command: string | undefined, home: string) {
  if (command === undefined) return undefined;
  return command.replace(/^(~|\$HOME|\$\{HOME\})(?=\/|$)/, home);
}

/** The indentation of a JSON file, as JSON.stringify takes it. */
function jsonIndent(text: string) {
  const match = /^[\t ]+(?=")/m.exec(text);
  return match ? match[0] : "  ";
}

/**
 * Compare Claude settings with their template: each template hook (event,
 * matcher and command) and each other top-level key the local file lacks.
 * A missing hook is appended to its event in a group of its own; a missing
 * key is appended with the template's value.
 */
export function claudeSettingsDrift(
  templateText: string,
  localText: string,
  home: string,
): Drift {
  const template = JSON.parse(templateText) as Settings;
  let local: Settings;
  try {
    local = JSON.parse(localText) as Settings;
  } catch {
    return {
      missing: ["(the file is not valid JSON; nothing compared)"],
      updated: undefined,
      reportOnly: "it is not valid JSON",
    };
  }
  if (typeof local !== "object" || local === null || Array.isArray(local))
    return {
      missing: ["(the file is not a JSON object; nothing compared)"],
      updated: undefined,
      reportOnly: "it is not a JSON object",
    };
  const missing: string[] = [];
  const updated: Settings = structuredClone(local);
  for (const [event, groups] of Object.entries(template.hooks ?? {})) {
    for (const group of groups) {
      for (const hook of group.hooks ?? []) {
        const command = normalizeCommand(hook.command, home);
        const present = (local.hooks?.[event] ?? []).some(
          (candidate) =>
            candidate.matcher === group.matcher &&
            (candidate.hooks ?? []).some(
              (existing) =>
                normalizeCommand(existing.command, home) === command,
            ),
        );
        if (present) continue;
        const matcher =
          group.matcher === undefined ? "" : ` matcher ${group.matcher}`;
        missing.push(`hook ${event}${matcher}: ${hook.command}`);
        updated.hooks ??= {};
        updated.hooks[event] ??= [];
        updated.hooks[event].push({
          ...(group.matcher === undefined ? {} : { matcher: group.matcher }),
          hooks: [hook],
        });
      }
    }
  }
  for (const [key, value] of Object.entries(template)) {
    if (key === "hooks" || key in local) continue;
    missing.push(`key ${key}`);
    updated[key] = value;
  }
  if (!missing.length) return { missing, updated: localText };
  const ending = localText.endsWith("\n") ? "\n" : "";
  return {
    missing,
    updated: `${JSON.stringify(updated, null, jsonIndent(localText))}${ending}`,
  };
}

/** A TOML line that opens a table or an array of tables. */
const tableHeader = /^\s*\[/;
/** A top-level TOML key line: its key, before the `=`. */
const keyLine =
  /^\s*((?:[A-Za-z0-9_-]+|"[^"]*"|'[^']*')(?:\s*\.\s*(?:[A-Za-z0-9_-]+|"[^"]*"|'[^']*'))*)\s*=/;

/**
 * The top-level keys of a TOML document and their lines, found by a line
 * check rather than a parse: every key line before the first table header.
 * Continuation lines of a multi-line value are skipped by tracking open
 * brackets and multi-line strings, so they are never taken for keys.
 */
function topLevelKeys(text: string) {
  const keys = new Map<string, { line: string; complete: boolean }>();
  const lines = text.split("\n");
  let open: { depth: number; quote?: string } | undefined;
  for (const line of lines) {
    if (open) {
      if (open.quote) {
        if (line.includes(open.quote)) open = undefined;
      } else {
        open.depth += depthChange(line);
        if (open.depth <= 0) open = undefined;
      }
      continue;
    }
    if (tableHeader.test(line)) break;
    const match = keyLine.exec(line);
    if (!match?.[1]) continue;
    const key = match[1].replace(/\s+/g, "");
    const value = line.slice(match[0].length);
    const quote = ['"""', "'''"].find(
      (delimiter) => value.split(delimiter).length === 2,
    );
    const depth = depthChange(value);
    const complete = !quote && depth <= 0;
    keys.set(key, { line, complete });
    if (quote) open = { depth: 0, quote };
    else if (depth > 0) open = { depth };
  }
  return keys;
}

/** Opening minus closing brackets and braces, outside simple strings. */
function depthChange(text: string) {
  const bare = text
    .replace(/"(?:[^"\\]|\\.)*"/g, "")
    .replace(/'[^']*'/g, "")
    .replace(/#.*/, "");
  let depth = 0;
  for (const character of bare) {
    if (character === "[" || character === "{") depth++;
    if (character === "]" || character === "}") depth--;
  }
  return depth;
}

/**
 * Compare a Codex configuration with its template, top-level keys only, by a
 * line check (see `topLevelKeys`). A missing key whose template value fits on
 * its line is inserted verbatim before the local file's first table header,
 * where top-level keys must stay; a multi-line one is reported only.
 */
export function codexConfigDrift(
  templateText: string,
  localText: string,
): Drift {
  const template = topLevelKeys(templateText);
  const local = topLevelKeys(localText);
  const missing: string[] = [];
  const additions: string[] = [];
  let reportOnly: string | undefined;
  for (const [key, { line, complete }] of template) {
    if (local.has(key)) continue;
    missing.push(`key ${key}`);
    if (complete) additions.push(line);
    else reportOnly = `the template's ${key} spans several lines`;
  }
  if (!missing.length) return { missing, updated: localText };
  if (reportOnly) return { missing, updated: undefined, reportOnly };
  const lines = localText.split("\n");
  const header = lines.findIndex((line) => tableHeader.test(line));
  if (header === -1) {
    const ending = localText === "" || localText.endsWith("\n") ? "" : "\n";
    return {
      missing,
      updated: `${localText}${ending}${additions.join("\n")}\n`,
    };
  }
  lines.splice(header, 0, ...additions, "");
  return { missing, updated: lines.join("\n") };
}
