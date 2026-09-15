import { execFileSync } from "node:child_process";

type Container = { Service: string; State: string; Health?: string };

export function servicesReady(required: string[], containers: Container[]): boolean {
  return (
    required.length > 0 &&
    required.every((name) => {
      const instances = containers.filter((container) => container.Service === name);
      return (
        instances.length > 0 &&
        instances.every(
          (container) => container.State === "running" && container.Health === "healthy",
        )
      );
    })
  );
}

if (import.meta.main) {
  if (!process.env.COMPOSE_PROJECT_NAME) throw new Error("Missing Compose project identity");
  process.env.COMPOSE_DISABLE_ENV_FILE = "1";
  const compose = (...args: string[]) =>
    execFileSync("docker", ["compose", "--profile", "services", ...args], {
      encoding: "utf8",
    }).trim();
  const required = compose("config", "--services").split("\n").filter(Boolean);
  const containers = compose("ps", "--format", "json")
    .split("\n")
    .filter(Boolean)
    .flatMap((line) => JSON.parse(line));
  process.exit(servicesReady(required, containers) ? 0 : 1);
}
