#!/usr/bin/env -S node --import tsx
import {
  chmodSync,
  constants,
  copyFileSync,
  existsSync,
  lstatSync,
  readFileSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readlinkSync,
  realpathSync,
  renameSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import {
  claudeSettingsDrift,
  codexConfigDrift,
  type Drift,
} from "./template-drift.mts";

function pathExists(path: string) {
  try {
    lstatSync(path);
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw error;
  }
}

function resolveMissingPath(path: string, depth = 0): string {
  if (depth > 40) throw new Error(`Too many symbolic links: ${path}`);
  if (existsSync(path)) return realpathSync(path);
  if (pathExists(path) && lstatSync(path).isSymbolicLink()) {
    return resolveMissingPath(
      resolve(dirname(path), readlinkSync(path)),
      depth + 1,
    );
  }
  const parent = dirname(path);
  if (parent === path) return path;
  return join(resolveMissingPath(parent, depth + 1), relative(parent, path));
}

/** One link the installer manages. */
type PayloadItem = {
  /** Where the link goes, relative to home. */
  path: string;
  /** What the link points at, relative to the checkout. */
  source: string;
};

/**
 * Directory under home where a skill's executables are linked. It is expected
 * to be on PATH already.
 */
const localBin = ".local/bin";

/**
 * A shared skill's executables are the files directly in its `bin` directory.
 * Each is linked by name into the local bin directory; a skill's other
 * scripts, helpers and tests included, never reach PATH.
 */
function skillExecutables(repo: string) {
  const items: PayloadItem[] = [];
  const skills = join(repo, "shared/skills");
  if (!existsSync(skills)) return items;
  for (const skill of readdirSync(skills).sort()) {
    const bin = join(skills, skill, "bin");
    if (!existsSync(bin) || !lstatSync(bin).isDirectory()) continue;
    for (const executable of readdirSync(bin).sort()) {
      const path = join(localBin, executable);
      const source = join("shared/skills", skill, "bin", executable);
      const clash = items.find((item) => item.path === path);
      if (clash)
        throw new Error(
          `Two skills ship the executable ${executable}: ${clash.source} and ${source}`,
        );
      items.push({ path, source });
    }
  }
  return items;
}

/**
 * The paths among `paths` (relative to `repo`) that git ignores, such as the
 * local worktrees Claude Code creates under `.claude/worktrees`. They are not
 * harness sources. Outside a git checkout, nothing is ignored.
 */
function gitIgnored(repo: string, paths: string[]) {
  if (!paths.length) return new Set<string>();
  const result = spawnSync("git", ["check-ignore", "-z", "--stdin"], {
    cwd: repo,
    input: paths.join("\0"),
    encoding: "utf8",
  });
  if (result.error) throw result.error;
  // Exit status 1 means none is ignored; 128 means repo is not a git checkout.
  if (result.status === 1 || result.status === 128) return new Set<string>();
  if (result.status !== 0)
    throw new Error(`git check-ignore failed: ${result.stderr}`);
  return new Set(result.stdout.split("\0").filter(Boolean));
}

/** A file in home that belongs to the user, started from a versioned template. */
type LocalFile = {
  /** Where the file lives, relative to home. */
  path: string;
  /** The template it starts from, relative to the checkout. */
  template: string;
  /** What the file holds, for the installer's messages. */
  label: string;
  /**
   * What an existing local file lacks from its template, when the harness
   * keeps it in step; the local instructions are free text, never compared.
   */
  drift?: (template: string, local: string, home: string) => Drift;
};

/**
 * The user's own files: never versioned. The installer creates each from its
 * versioned template only when it is missing, and never overwrites it.
 *
 * The local instructions say who the user is and what is true of their
 * machine. Each tool's settings are local too: the tool itself writes into
 * them, and neither tool loads a second user-level file to layer personal
 * values over a shared one.
 */
export const localFiles: LocalFile[] = [
  {
    path: ".agents/local.md",
    template: "shared/local.example.md",
    label: "Local instructions",
  },
  {
    path: ".claude/settings.json",
    template: "shared/claude-settings.example.json",
    label: "Claude settings",
    drift: claudeSettingsDrift,
  },
  {
    path: ".codex/config.toml",
    template: "shared/codex-config.example.toml",
    label: "Codex configuration",
    drift: (template, local) => codexConfigDrift(template, local),
  },
];

/**
 * How a local file is brought into place, or nothing when it already is.
 *
 * - `create`: missing, or a dangling link left by an earlier installation
 *   that linked it into the checkout; created from its template.
 * - `detach`: a link into the checkout that still resolves, left by an
 *   earlier installation; replaced by a copy of what it points at, so that
 *   the tool's own writes stop landing in the checkout.
 */
function localFilePlan(repo: string, home: string, file: LocalFile) {
  const destination = join(home, file.path);
  if (!pathExists(destination)) return { action: "create" as const, file };
  if (!lstatSync(destination).isSymbolicLink()) return undefined;
  const target = resolve(dirname(destination), readlinkSync(destination));
  const fromRepo = relative(repo, resolveMissingPath(target));
  const intoRepo =
    !isAbsolute(fromRepo) &&
    fromRepo !== ".." &&
    !fromRepo.startsWith(`..${sep}`);
  if (!intoRepo) return undefined;
  if (existsSync(target)) return { action: "detach" as const, file, target };
  return { action: "create" as const, file, dangling: target };
}

/**
 * What a local file that already exists lacks from its template: read
 * through a link to the checkout too, since that is what it will hold once
 * detached. Files about to be created from the template lack nothing.
 */
function templateDrift(
  repo: string,
  home: string,
  file: LocalFile,
  plan: ReturnType<typeof localFilePlan>,
) {
  if (!file.drift || plan?.action === "create") return undefined;
  const local = plan?.action === "detach" ? plan.target : join(home, file.path);
  const drift = file.drift(
    readFileSync(join(repo, file.template), "utf8"),
    readFileSync(local, "utf8"),
    home,
  );
  return drift.missing.length ? { file, drift } : undefined;
}

/**
 * Every link the installer manages: the skills' executables, then the
 * runtime directories, which mirror the checkout, minus what git ignores and
 * the user's local files.
 *
 * @param repo Checkout containing the versioned harness directories.
 */
export function payload(repo: string) {
  const items = skillExecutables(repo);
  const runtime: PayloadItem[] = [];
  for (const root of [".claude", ".agents", ".codex"]) {
    for (const child of readdirSync(join(repo, root)).sort()) {
      const directory = join(repo, root, child);
      const sources =
        ["skills", "commands", "hooks"].includes(child) &&
        existsSync(directory) &&
        lstatSync(directory).isDirectory()
          ? readdirSync(directory)
              .sort()
              .map((item) => join(root, child, item))
          : [join(root, child)];
      for (const source of sources) runtime.push({ path: source, source });
    }
  }
  const ignored = gitIgnored(
    repo,
    runtime.map(({ source }) => source),
  );
  const local = new Set(localFiles.map(({ path }) => path));
  items.push(
    ...runtime.filter(
      ({ path, source }) => !ignored.has(source) && !local.has(path),
    ),
  );
  return items;
}

type InstallOptions = {
  /** Checkout containing the versioned harness directories. */
  repo: string;
  /** Home directory receiving the links and backups. */
  home: string;
  /** Install links when true; otherwise print the proposed changes. */
  apply: boolean;
};

/**
 * Link the versioned harness into home, backing up existing paths and rolling
 * back completed replacements if installation fails.
 */
export function install({ repo, home, apply }: InstallOptions) {
  repo = realpathSync(repo);
  home = resolve(home);
  const entries = payload(repo).flatMap(({ path, source }) => {
    const target = join(repo, source);
    const destination = join(home, path);
    if (
      pathExists(destination) &&
      lstatSync(destination).isSymbolicLink() &&
      readlinkSync(destination) === target
    )
      return [];
    if (!existsSync(target)) {
      const resolved = resolveMissingPath(target);
      const fromRepo = relative(repo, resolved);
      const internal =
        fromRepo === "" ||
        (!isAbsolute(fromRepo) &&
          fromRepo !== ".." &&
          !fromRepo.startsWith(`..${sep}`));
      if (!lstatSync(target).isSymbolicLink() || internal)
        throw new Error(`Missing source or broken internal link: ${target}`);
      console.log(`External checkout not present: ${path}`);
    }
    return [{ path, target, destination }];
  });
  const locals: NonNullable<ReturnType<typeof localFilePlan>>[] = [];
  const drifts: NonNullable<ReturnType<typeof templateDrift>>[] = [];
  for (const file of localFiles) {
    const template = join(repo, file.template);
    if (!existsSync(template)) throw new Error(`Missing template: ${template}`);
    const plan = localFilePlan(repo, home, file);
    if (plan) locals.push(plan);
    const drift = templateDrift(repo, home, file, plan);
    if (drift) drifts.push(drift);
  }
  console.log(
    `${entries.length} paths to link; runtime directories stay in place`,
  );
  for (const { path } of entries) console.log(`  ${path}`);
  for (const plan of locals)
    console.log(
      plan.action === "create"
        ? `${plan.file.label} to create from ${plan.file.template}, then yours to edit:\n  ${plan.file.path}`
        : `${plan.file.label} to copy out of the checkout, then yours to edit:\n  ${plan.file.path}`,
    );
  for (const { file, drift } of drifts) {
    const how = drift.updated
      ? "to add"
      : `to add by hand, since ${drift.reportOnly}`;
    console.log(
      `~/${file.path} lacks entries of ${file.template}, ${how}:\n${drift.missing.map((line) => `  ${line}`).join("\n")}`,
    );
  }
  if (!apply) {
    console.log("Dry run. Use --apply to install.");
    return;
  }
  /** Created after the links, so that a failed installation leaves none. */
  const seedLocal = () => {
    for (const plan of locals) {
      const local = join(home, plan.file.path);
      mkdirSync(dirname(local), { recursive: true });
      if (plan.action === "detach") {
        const copy = `${local}.dotagents-${process.pid}`;
        copyFileSync(plan.target, copy, constants.COPYFILE_EXCL);
        renameSync(copy, local);
        console.log(`Copied ${plan.target} to ${local}: it is now yours.`);
        continue;
      }
      if ("dangling" in plan && plan.dangling) {
        unlinkSync(local);
        console.log(
          `${local} linked to ${plan.dangling}, which is gone; its last versioned content is in the checkout's git history.`,
        );
      }
      copyFileSync(
        join(repo, plan.file.template),
        local,
        constants.COPYFILE_EXCL,
      );
      console.log(
        `Created ${local} from ${plan.file.template}: yours to edit.`,
      );
    }
    // Recomputed from the file as it is now, detached copies included.
    for (const { file } of drifts) {
      const local = join(home, file.path);
      const text = readFileSync(local, "utf8");
      const drift = file.drift?.(
        readFileSync(join(repo, file.template), "utf8"),
        text,
        home,
      );
      if (!drift?.updated || drift.updated === text) continue;
      writeFileSync(local, drift.updated);
      console.log(`Added to ${local}: ${drift.missing.join("; ")}`);
    }
  };
  if (!entries.length) {
    seedLocal();
    console.log("Already installed.");
    return;
  }
  const backups = join(home, ".local/state/dotagents/backups");
  mkdirSync(backups, { recursive: true });
  const stamp = new Date().toISOString().replaceAll(/[-:]/g, "");
  const backup = mkdtempSync(join(backups, `${stamp}-`));
  chmodSync(backup, 0o700);
  const completed: {
    path: string;
    destination: string;
    hadOriginal: boolean;
  }[] = [];
  try {
    for (const { path, target, destination } of entries) {
      const saved = join(backup, path);
      const hadOriginal = pathExists(destination);
      mkdirSync(dirname(destination), { recursive: true });
      if (hadOriginal) {
        mkdirSync(dirname(saved), { recursive: true });
        renameSync(destination, saved);
      }
      completed.push({ path, destination, hadOriginal });
      symlinkSync(target, destination);
    }
    writeFileSync(
      join(backup, "manifest.json"),
      `${JSON.stringify({ repo, paths: completed.map(({ path }) => path) }, null, 2)}\n`,
    );
  } catch (error) {
    for (const { path, destination, hadOriginal } of completed.reverse()) {
      if (pathExists(destination) && lstatSync(destination).isSymbolicLink())
        unlinkSync(destination);
      if (hadOriginal) renameSync(join(backup, path), destination);
    }
    throw error;
  }
  seedLocal();
  console.log(`Installed. Previous files: ${backup}`);
}

if (
  process.argv[1] &&
  realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))
) {
  const { values } = parseArgs({
    options: {
      home: { type: "string", default: homedir() },
      apply: { type: "boolean", default: false },
    },
  });
  install({
    repo: dirname(dirname(realpathSync(fileURLToPath(import.meta.url)))),
    home: values.home,
    apply: values.apply,
  });
}
