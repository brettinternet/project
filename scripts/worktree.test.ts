import { afterAll, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  cpSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { servicesReady } from "./compose-ready";
import { setupEnvironment } from "./worktree-env";

const fixture = realpathSync(mkdtempSync(join(tmpdir(), "project-worktree-test-")));
const primary = join(fixture, "primary checkout");
mkdirSync(primary);
const git = (cwd: string, ...args: string[]) =>
  execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
git(primary, "init", "-b", "main");
git(primary, "config", "user.name", "Fixture");
git(primary, "config", "user.email", "fixture@example.invalid");
for (const file of ["Taskfile.dist.yaml", ".taskfiles", ".env.schema", "mise.toml"]) {
  cpSync(resolve(import.meta.dir, "..", file), join(primary, file), { recursive: true });
}
mkdirSync(join(primary, "client"));
git(primary, "add", "Taskfile.dist.yaml", ".taskfiles", ".env.schema", "mise.toml");
git(primary, "-c", "core.hooksPath=/dev/null", "commit", "-m", "fixture");
const left = join(fixture, "left");
const right = join(fixture, "right");
git(primary, "worktree", "add", "-b", "left", left);
git(primary, "worktree", "add", "-b", "right", right);
for (const root of [left, right]) mkdirSync(join(root, "client"));

// Only this test-created directory under the canonical OS temp root is removed.
afterAll(() => rmSync(fixture, { recursive: true }));

test("setup preserves local overrides, generates distinct identities, and is repeatable", () => {
  writeFileSync(join(primary, ".env.local"), "API_KEY=primary-only-fixture\n");
  setupEnvironment(primary);
  expect(readFileSync(join(primary, ".env.worktree.local"), "utf8")).toBe("");
  expect(readFileSync(join(primary, ".env.local"), "utf8")).toContain("primary-only-fixture");
  setupEnvironment(left);
  setupEnvironment(right);
  const generated = readFileSync(join(left, ".env.worktree.local"), "utf8");
  expect(generated).not.toBe(readFileSync(join(right, ".env.worktree.local"), "utf8"));
  expect(readFileSync(join(left, ".env.local"), "utf8")).toBe("");
  writeFileSync(join(left, ".env.worktree.local"), `${generated}# retained edit\n`);
  setupEnvironment(left);
  expect(readFileSync(join(left, ".env.worktree.local"), "utf8")).toBe(
    `${generated}# retained edit\n`,
  );
});

test("Task/Varlock ignores inherited routing and scopes Compose to the worktree", () => {
  setupEnvironment(right);
  const output = execFileSync(
    "task",
    [
      "--dir",
      right,
      "setup:env:run",
      "--",
      "bun",
      "-e",
      "console.log(JSON.stringify({project:process.env.COMPOSE_PROJECT_NAME,port:process.env.APP_PORT,domain:process.env.DOMAIN}))",
    ],
    {
      env: {
        ...process.env,
        MISE_TRUSTED_CONFIG_PATHS: fixture,
        COMPOSE_PROJECT_NAME: "primary-do-not-touch",
        APP_PORT: "1",
        DOMAIN: "primary.invalid",
      },
      encoding: "utf8",
    },
  );
  const actual = JSON.parse(output.trim());
  const generated = readFileSync(join(right, ".env.worktree.local"), "utf8");
  expect(generated).toContain(`COMPOSE_PROJECT_NAME=${actual.project}\n`);
  expect(generated).toContain(`APP_PORT=${actual.port}\n`);
  expect(actual.domain).not.toBe("primary.invalid");
});

test("the example server fails rather than choosing another port", async () => {
  const occupied = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: () => new Response("occupied"),
  });
  const child = Bun.spawn([process.execPath, resolve(import.meta.dir, "dev-server.ts")], {
    env: { ...process.env, APP_PORT: String(occupied.port) },
    stdout: "ignore",
    stderr: "pipe",
  });
  const timeout = setTimeout(() => child.kill(), 3000);
  try {
    const output = await new Response(child.stderr).text();
    expect(await child.exited).not.toBe(0);
    expect(output).toContain("EADDRINUSE");
    expect(output).toContain(String(occupied.port));
  } finally {
    clearTimeout(timeout);
    child.kill();
    occupied.stop(true);
  }
});

test("readiness rejects missing, exited, unhealthy, and partially healthy services", () => {
  expect(servicesReady([], [])).toBe(false);
  expect(servicesReady(["db"], [])).toBe(false);
  expect(servicesReady(["db"], [{ Service: "db", State: "exited" }])).toBe(false);
  expect(servicesReady(["db"], [{ Service: "db", State: "running", Health: "starting" }])).toBe(
    false,
  );
  expect(
    servicesReady(
      ["db"],
      [
        { Service: "db", State: "running", Health: "healthy" },
        { Service: "db", State: "running", Health: "unhealthy" },
      ],
    ),
  ).toBe(false);
  expect(
    servicesReady(
      ["db", "web"],
      [
        { Service: "db", State: "running", Health: "healthy" },
        { Service: "web", State: "running" },
      ],
    ),
  ).toBe(true);
});
