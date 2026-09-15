import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export function worktreeEnvironment(root: string): string {
  const hash = createHash("sha256").update(root).digest();
  const identity = `project-${hash.toString("hex").slice(0, 12)}`;
  // Deterministic, not reserved: startup must fail if another process owns a port.
  const port = 20000 + (hash.readUInt32BE(0) % 10000) * 3;
  return [
    "# Generated local worktree identity. Edit ports here if a collision occurs.",
    `COMPOSE_PROJECT_NAME=${identity}`,
    `DOMAIN=${identity}.example.arpa`,
    `APP_PORT=${port}`,
    `TRAEFIK_PORT=${port + 1}`,
    `POSTGRES_PORT=${port + 2}`,
    "",
  ].join("\n");
}

export function setupEnvironment(root: string): void {
  root = realpathSync(root);
  const [gitDir, commonDir] = execFileSync(
    "git",
    ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"],
    { cwd: root, encoding: "utf8" },
  )
    .trim()
    .split("\n");
  for (const [name, content] of [
    [".env.local", ""],
    [".env.worktree.local", gitDir === commonDir ? "" : worktreeEnvironment(root)],
  ]) {
    const path = join(root, name!);
    if (!existsSync(path)) writeFileSync(path, content!, { flag: "wx", mode: 0o600 });
  }
}

if (import.meta.main) setupEnvironment(process.cwd());
