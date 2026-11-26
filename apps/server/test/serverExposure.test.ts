import assert from "node:assert/strict";
import test from "node:test";
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const serverEntry = fileURLToPath(new URL("../src/server.ts", import.meta.url));
const tsx = fileURLToPath(new URL("../node_modules/.bin/tsx", import.meta.url));

async function freePort(): Promise<number> {
  const probe = createServer();
  await new Promise<void>((resolve) => probe.listen(0, "127.0.0.1", resolve));
  const { port } = probe.address() as { port: number };
  await new Promise((resolve) => probe.close(resolve));
  return port;
}

test("the default server binds locally and allows no cross-origin reads", async () => {
  // A temporary working directory keeps the developer's .env out of the test.
  const directory = await mkdtemp(join(tmpdir(), "dailypostbox-server-"));
  const port = await freePort();
  const env = { ...process.env, PORT: String(port), DATA_FILE_PATH: join(directory, "state.json") };
  delete env.HOST;
  const child = spawn(tsx, [serverEntry], { cwd: directory, env });
  let output = "";
  child.stdout.on("data", (chunk) => {
    output += chunk;
  });

  try {
    const deadline = Date.now() + 15_000;
    while (!output.includes("Server listening") && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    assert.match(output, new RegExp(`Server listening at http://127\\.0\\.0\\.1:${port}`));

    const response = await fetch(`http://127.0.0.1:${port}/accounts`, {
      headers: { origin: "https://attacker.example" }
    });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("access-control-allow-origin"), null);
  } finally {
    child.kill();
    await rm(directory, { recursive: true, force: true });
  }
});
