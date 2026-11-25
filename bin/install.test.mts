import assert from "node:assert/strict";
import {
  chmodSync,
  copyFileSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  readlinkSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { install, payload } from "./install.mts";

function fixture() {
  const directory = realpathSync(
    mkdtempSync(join(tmpdir(), "dotagents-install-")),
  );
  const repo = join(directory, "repo");
  const home = join(directory, "home");
  for (const path of [
    "shared",
    ".claude/skills/branchstat",
    ".agents/skills",
    ".codex",
    "bin",
  ])
    mkdirSync(join(repo, path), { recursive: true });
  mkdirSync(home);
  writeFileSync(join(repo, ".claude/CLAUDE.md"), "Personal instructions");
  writeFileSync(
    join(repo, ".claude/skills/branchstat/SKILL.md"),
    "Shared skill",
  );
  symlinkSync(
    "../../.claude/skills/branchstat",
    join(repo, ".agents/skills/branchstat"),
  );
  writeFileSync(join(repo, ".codex/AGENTS.md"), "Codex instructions");
  writeFileSync(join(repo, "package.json"), '{"type":"module"}');
  writeFileSync(join(repo, "shared/local.example.md"), "I'm <name>.");
  writeFileSync(join(repo, "shared/claude-settings.example.json"), "{}");
  writeFileSync(join(repo, "shared/codex-config.example.toml"), "# Codex");
  // A skill's executables live in its bin directory; its other scripts do not.
  mkdirSync(join(repo, "shared/skills/bench/bin"), { recursive: true });
  writeFileSync(join(repo, "shared/skills/bench/bin/bench-lock"), "#!/bin/sh");
  chmodSync(join(repo, "shared/skills/bench/bin/bench-lock"), 0o755);
  mkdirSync(join(repo, "shared/skills/branchstat"));
  for (const script of ["branchstat.sh", "branchstat.test.sh"]) {
    writeFileSync(join(repo, "shared/skills/branchstat", script), "#!/bin/sh");
    chmodSync(join(repo, "shared/skills/branchstat", script), 0o755);
  }
  const cleanup = () => rmSync(directory, { recursive: true, force: true });
  return { repo, home, cleanup };
}

test("CLI dry run leaves home untouched", (context) => {
  const { repo, home, cleanup } = fixture();
  context.after(cleanup);
  for (const module of ["install.mts", "template-drift.mts"])
    copyFileSync(
      join(dirname(fileURLToPath(import.meta.url)), module),
      join(repo, "bin", module),
    );
  const result = spawnSync(
    process.execPath,
    [
      "--import",
      import.meta.resolve("tsx"),
      join(repo, "bin/install.mts"),
      "--home",
      home,
    ],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Dry run/);
  assert.match(result.stdout, /^ {2}\.local\/bin\/bench-lock$/m);
  assert.match(result.stdout, /^ {2}\.agents\/local\.md$/m);
  assert.deepEqual(readdirSync(home), []);
});

test("installation preserves backups and runtime state, and is idempotent", (context) => {
  const { repo, home, cleanup } = fixture();
  context.after(cleanup);
  mkdirSync(join(home, ".codex/sessions"), { recursive: true });
  writeFileSync(join(home, ".codex/sessions/keep"), "Live session");
  writeFileSync(join(home, ".codex/AGENTS.md"), "Local instructions");
  writeFileSync(join(home, ".codex/config.toml"), "Local configuration");
  mkdirSync(join(home, ".claude/skills/branchstat"), { recursive: true });
  writeFileSync(join(home, ".claude/skills/branchstat/keep"), "Local skill");
  mkdirSync(join(home, ".local/bin"), { recursive: true });
  writeFileSync(join(home, ".local/bin/bench-lock"), "Local bench-lock");
  install({ repo, home, apply: true });
  const backups = join(home, ".local/state/dotagents/backups");
  const [backupName] = readdirSync(backups);
  assert.ok(backupName);
  const backup = join(backups, backupName);
  assert.equal(lstatSync(backup).mode & 0o777, 0o700);
  assert.equal(
    readFileSync(join(backup, ".codex/AGENTS.md"), "utf8"),
    "Local instructions",
  );
  assert.equal(
    readFileSync(join(backup, ".claude/skills/branchstat/keep"), "utf8"),
    "Local skill",
  );
  assert.equal(
    readFileSync(join(backup, ".local/bin/bench-lock"), "utf8"),
    "Local bench-lock",
  );
  assert.equal(
    readFileSync(join(home, ".codex/sessions/keep"), "utf8"),
    "Live session",
  );
  assert.equal(
    readlinkSync(join(home, ".codex/AGENTS.md")),
    join(repo, ".codex/AGENTS.md"),
  );
  // The user's own configuration is left in place, never linked.
  assert.equal(
    readFileSync(join(home, ".codex/config.toml"), "utf8"),
    "Local configuration",
  );
  assert.ok(!lstatSync(join(home, ".codex/config.toml")).isSymbolicLink());
  assert.equal(
    readFileSync(join(home, ".agents/skills/branchstat/SKILL.md"), "utf8"),
    "Shared skill",
  );
  assert.equal(
    readlinkSync(join(home, ".local/bin/bench-lock")),
    join(repo, "shared/skills/bench/bin/bench-lock"),
  );
  assert.deepEqual(readdirSync(join(home, ".local/bin")), ["bench-lock"]);
  const manifest = JSON.parse(
    readFileSync(join(backup, "manifest.json"), "utf8"),
  ) as { repo: string; paths: string[] };
  assert.equal(manifest.repo, repo);
  assert.ok(manifest.paths.includes(".codex/AGENTS.md"));
  assert.ok(!manifest.paths.includes(".codex/config.toml"));
  assert.ok(manifest.paths.includes(".local/bin/bench-lock"));
  install({ repo, home, apply: true });
  assert.deepEqual(readdirSync(backups), [backupName]);
});

test("late failure restores replaced files and removes newly installed links", (context) => {
  const { repo, home, cleanup } = fixture();
  context.after(cleanup);
  mkdirSync(join(repo, ".claude/commands"));
  writeFileSync(join(repo, ".claude/commands/example.md"), "New command");
  mkdirSync(join(home, ".claude/skills"), { recursive: true });
  writeFileSync(join(home, ".claude/CLAUDE.md"), "Original instructions");
  symlinkSync("../old-skill", join(home, ".claude/skills/branchstat"));
  // A dangling parent passes planning and only fails once earlier links,
  // the local bin ones included, are already in place.
  symlinkSync("missing", join(home, ".codex"));
  mkdirSync(join(home, ".local/bin"), { recursive: true });
  writeFileSync(join(home, ".local/bin/bench-lock"), "Local bench-lock");
  assert.throws(() => install({ repo, home, apply: true }), /ENOENT/);
  assert.equal(
    readFileSync(join(home, ".claude/CLAUDE.md"), "utf8"),
    "Original instructions",
  );
  assert.equal(
    readlinkSync(join(home, ".claude/skills/branchstat")),
    "../old-skill",
  );
  assert.equal(readlinkSync(join(home, ".codex")), "missing");
  assert.throws(
    () => lstatSync(join(home, ".agents/skills/branchstat")),
    /ENOENT/,
  );
  assert.throws(
    () => lstatSync(join(home, ".claude/commands/example.md")),
    /ENOENT/,
  );
  assert.equal(
    readFileSync(join(home, ".local/bin/bench-lock"), "utf8"),
    "Local bench-lock",
  );
  assert.throws(() => lstatSync(join(home, ".agents/local.md")), /ENOENT/);
});

test("local files are created from their templates once, then never overwritten", (context) => {
  const { repo, home, cleanup } = fixture();
  context.after(cleanup);
  const local = join(home, ".agents/local.md");
  const settings = join(home, ".claude/settings.json");
  const config = join(home, ".codex/config.toml");
  install({ repo, home, apply: true });
  assert.equal(readFileSync(local, "utf8"), "I'm <name>.");
  assert.equal(readFileSync(settings, "utf8"), "{}");
  assert.equal(readFileSync(config, "utf8"), "# Codex");
  for (const path of [local, settings, config])
    assert.ok(!lstatSync(path).isSymbolicLink(), path);
  writeFileSync(local, "I'm someone.");
  writeFileSync(settings, '{"theme":"dark"}');
  writeFileSync(config, 'model = "mine"');
  // Already installed: the links are all in place, the files are still kept.
  install({ repo, home, apply: true });
  writeFileSync(join(repo, ".codex/new.md"), "New file");
  install({ repo, home, apply: true });
  assert.equal(readFileSync(local, "utf8"), "I'm someone.");
  assert.equal(readFileSync(settings, "utf8"), '{"theme":"dark"}');
  assert.equal(readFileSync(config, "utf8"), 'model = "mine"');
});

test("a local file left in the checkout is never linked into home", (context) => {
  const { repo, home, cleanup } = fixture();
  context.after(cleanup);
  writeFileSync(join(repo, ".codex/config.toml"), "Left in the checkout");
  const paths = payload(repo).map(({ path }) => path);
  assert.ok(!paths.includes(".codex/config.toml"));
  install({ repo, home, apply: true });
  assert.equal(
    readFileSync(join(home, ".codex/config.toml"), "utf8"),
    "# Codex",
  );
});

test("an earlier link into the checkout is detached into the user's own copy", (context) => {
  const { repo, home, cleanup } = fixture();
  context.after(cleanup);
  // An earlier installation linked the settings into the checkout.
  writeFileSync(join(repo, ".claude/settings.json"), '{"theme":"light"}');
  mkdirSync(join(home, ".claude"), { recursive: true });
  symlinkSync(
    join(repo, ".claude/settings.json"),
    join(home, ".claude/settings.json"),
  );
  install({ repo, home, apply: true });
  const settings = join(home, ".claude/settings.json");
  assert.ok(!lstatSync(settings).isSymbolicLink());
  assert.equal(readFileSync(settings, "utf8"), '{"theme":"light"}');
  writeFileSync(settings, '{"theme":"dark"}');
  assert.equal(
    readFileSync(join(repo, ".claude/settings.json"), "utf8"),
    '{"theme":"light"}',
  );
});

test("a dangling link into the checkout is replaced by the template", (context) => {
  const { repo, home, cleanup } = fixture();
  context.after(cleanup);
  mkdirSync(join(home, ".codex"), { recursive: true });
  symlinkSync(
    join(repo, ".codex/config.toml"),
    join(home, ".codex/config.toml"),
  );
  install({ repo, home, apply: true });
  const config = join(home, ".codex/config.toml");
  assert.ok(!lstatSync(config).isSymbolicLink());
  assert.equal(readFileSync(config, "utf8"), "# Codex");
});

test("a link to elsewhere is the user's choice and stays", (context) => {
  const { repo, home, cleanup } = fixture();
  context.after(cleanup);
  const elsewhere = join(dirname(home), "my-settings.json");
  writeFileSync(elsewhere, '{"mine":true}');
  mkdirSync(join(home, ".claude"), { recursive: true });
  symlinkSync(elsewhere, join(home, ".claude/settings.json"));
  install({ repo, home, apply: true });
  assert.equal(readlinkSync(join(home, ".claude/settings.json")), elsewhere);
});

test("local files in the checkout are ignored, and their templates versioned", () => {
  const repo = dirname(dirname(fileURLToPath(import.meta.url)));
  for (const path of [
    ".agents/local.md",
    ".claude/settings.json",
    ".codex/config.toml",
  ]) {
    const result = spawnSync("git", ["check-ignore", "-q", path], {
      cwd: repo,
    });
    assert.equal(result.status, 0, path);
  }
  for (const template of [
    "shared/local.example.md",
    "shared/claude-settings.example.json",
    "shared/codex-config.example.toml",
  ])
    assert.doesNotMatch(
      readFileSync(join(repo, template), "utf8"),
      /\/Users\/|\/home\//,
      `${template} names no home directory`,
    );
  const settings = JSON.parse(
    readFileSync(join(repo, "shared/claude-settings.example.json"), "utf8"),
  ) as { hooks: Record<string, { hooks: { command: string }[] }[]> };
  assert.deepEqual(
    settings.hooks.UserPromptSubmit?.flatMap(({ hooks }) =>
      hooks.map(({ command }) => command),
    ),
    ["~/.claude/hooks/grill-one-at-a-time.sh"],
  );
});

const settingsTemplate = {
  hooks: {
    UserPromptSubmit: [
      { hooks: [{ type: "command", command: "~/.claude/hooks/grill.sh" }] },
    ],
  },
  statusLine: { type: "command", command: "~/.claude/statusline.sh" },
};

function withTemplates(repo: string) {
  writeFileSync(
    join(repo, "shared/claude-settings.example.json"),
    `${JSON.stringify(settingsTemplate, null, 2)}\n`,
  );
  writeFileSync(
    join(repo, "shared/codex-config.example.toml"),
    '# Codex\nproject_doc_fallback_filenames = ["CLAUDE.md"]\n',
  );
}

function captureLog(run: () => void) {
  const lines: string[] = [];
  const log = console.log;
  console.log = (...args: unknown[]) => void lines.push(args.join(" "));
  try {
    run();
  } finally {
    console.log = log;
  }
  return lines.join("\n");
}

test("a template hook and key the local settings lack are reported, then added on apply, additively", (context) => {
  const { repo, home, cleanup } = fixture();
  context.after(cleanup);
  withTemplates(repo);
  mkdirSync(join(home, ".claude"), { recursive: true });
  mkdirSync(join(home, ".codex"), { recursive: true });
  const settings = join(home, ".claude/settings.json");
  const config = join(home, ".codex/config.toml");
  const local = {
    theme: "dark",
    hooks: {
      Stop: [{ hooks: [{ type: "command", command: "my-notifier" }] }],
      UserPromptSubmit: [
        { hooks: [{ type: "command", command: "my-prompt-hook" }] },
      ],
    },
  };
  writeFileSync(settings, `${JSON.stringify(local, null, 4)}\n`);
  const toml =
    'model = "mine"\n\n[projects."/somewhere"]\ntrust_level = "trusted"\n';
  writeFileSync(config, toml);

  const dry = captureLog(() => install({ repo, home, apply: false }));
  assert.match(dry, /hook UserPromptSubmit: ~\/\.claude\/hooks\/grill\.sh/);
  assert.match(dry, /key statusLine/);
  assert.match(dry, /key project_doc_fallback_filenames/);
  assert.equal(
    readFileSync(settings, "utf8"),
    `${JSON.stringify(local, null, 4)}\n`,
  );
  assert.equal(readFileSync(config, "utf8"), toml);

  install({ repo, home, apply: true });
  const updated = readFileSync(settings, "utf8");
  assert.ok(updated.startsWith('{\n    "theme": "dark"'), "indentation kept");
  assert.deepEqual(JSON.parse(updated), {
    theme: "dark",
    hooks: {
      Stop: local.hooks.Stop,
      UserPromptSubmit: [
        ...local.hooks.UserPromptSubmit,
        ...settingsTemplate.hooks.UserPromptSubmit,
      ],
    },
    statusLine: settingsTemplate.statusLine,
  });
  assert.equal(
    readFileSync(config, "utf8"),
    'model = "mine"\n\nproject_doc_fallback_filenames = ["CLAUDE.md"]\n\n[projects."/somewhere"]\ntrust_level = "trusted"\n',
  );

  // In step now: nothing reported, nothing rewritten.
  const again = captureLog(() => install({ repo, home, apply: true }));
  assert.doesNotMatch(again, /lacks entries|Added to/);
  assert.equal(readFileSync(settings, "utf8"), updated);
});

test("local settings in step with the template, home spelled out, report nothing", (context) => {
  const { repo, home, cleanup } = fixture();
  context.after(cleanup);
  withTemplates(repo);
  mkdirSync(join(home, ".claude"), { recursive: true });
  const settings = {
    ...settingsTemplate,
    hooks: {
      UserPromptSubmit: [
        {
          hooks: [
            { type: "command", command: join(home, ".claude/hooks/grill.sh") },
          ],
        },
      ],
    },
  };
  writeFileSync(
    join(home, ".claude/settings.json"),
    JSON.stringify(settings, null, 2),
  );
  const output = captureLog(() => install({ repo, home, apply: false }));
  assert.doesNotMatch(output, /Claude settings|claude\/settings\.json lacks/);
});

test("absent local settings are still created from the template, with no drift report", (context) => {
  const { repo, home, cleanup } = fixture();
  context.after(cleanup);
  withTemplates(repo);
  const output = captureLog(() => install({ repo, home, apply: true }));
  assert.doesNotMatch(output, /lacks entries/);
  assert.deepEqual(
    JSON.parse(readFileSync(join(home, ".claude/settings.json"), "utf8")),
    settingsTemplate,
  );
});

test("two skills shipping the same executable are rejected before any mutation", (context) => {
  const { repo, home, cleanup } = fixture();
  context.after(cleanup);
  mkdirSync(join(repo, "shared/skills/other/bin"), { recursive: true });
  writeFileSync(join(repo, "shared/skills/other/bin/bench-lock"), "#!/bin/sh");
  assert.throws(
    () => install({ repo, home, apply: true }),
    /Two skills ship the executable bench-lock/,
  );
  assert.deepEqual(readdirSync(home), []);
});

test("broken internal links are rejected before any mutation", (context) => {
  const { repo, home, cleanup } = fixture();
  context.after(cleanup);
  symlinkSync("../missing", join(repo, ".codex/broken"));
  assert.throws(
    () => install({ repo, home, apply: true }),
    /broken internal link/,
  );
  assert.deepEqual(readdirSync(home), []);
});

test("external links can be installed even when their checkout is absent", (context) => {
  const { repo, home, cleanup } = fixture();
  context.after(cleanup);
  const external = join(dirname(repo), "absent-external-checkout");
  symlinkSync(external, join(repo, ".codex/external"));
  install({ repo, home, apply: true });
  assert.equal(
    readlinkSync(join(home, ".codex/external")),
    join(repo, ".codex/external"),
  );
});

test("children git ignores, such as local worktrees, are not linked", (context) => {
  const { repo, cleanup } = fixture();
  context.after(cleanup);
  const git = (...args: string[]) => {
    const result = spawnSync("git", args, { cwd: repo, encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
  };
  git("init", "--quiet");
  writeFileSync(join(repo, ".git/info/exclude"), ".claude/worktrees/\n");
  mkdirSync(join(repo, ".claude/worktrees/some-session"), { recursive: true });
  const sources = payload(repo).map(({ source }) => source);
  assert.ok(!sources.includes(".claude/worktrees"));
  assert.ok(sources.includes(".claude/CLAUDE.md"));
  assert.ok(sources.includes(".claude/skills/branchstat"));
});

test("the real checkout puts bench-lock, bench-remote, bench-device, bench-compare, bench-ab, and only skill executables, on PATH", () => {
  const repo = dirname(dirname(fileURLToPath(import.meta.url)));
  const onPath = payload(repo).filter(({ path }) =>
    path.startsWith(".local/bin/"),
  );
  for (const name of [
    "bench-lock",
    "bench-remote",
    "bench-device",
    "bench-compare",
    "bench-ab",
  ]) {
    assert.ok(
      onPath.some(
        ({ path, source }) =>
          path === `.local/bin/${name}` &&
          source === `shared/skills/bench/bin/${name}`,
      ),
      name,
    );
  }
  for (const { path, source } of onPath) {
    assert.match(source, /^shared\/skills\/[^/]+\/bin\/[^/]+$/);
    assert.ok(statSync(join(repo, source)).mode & 0o111, `${source} +x`);
  }
});
