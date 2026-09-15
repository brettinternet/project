// Replace this small runnable example with your project's application command.
const server = Bun.serve({
  hostname: "127.0.0.1",
  port: Number(process.env.APP_PORT ?? 3000),
  fetch(request) {
    if (new URL(request.url).pathname === "/readyz") return new Response("ready\n");
    return Response.json({
      project: process.env.COMPOSE_PROJECT_NAME,
      checkout: process.cwd(),
      message: "Worktrunk prepares this checkout; Hum owns this process.",
    });
  },
});
console.log(`App ready at ${server.url}`);
