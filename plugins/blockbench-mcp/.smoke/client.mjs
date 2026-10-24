/**
 * 冒烟测试（裸 JSON-RPC stdio 客户端，无 SDK 依赖）：
 * 经 launcher.mjs 跑通 initialize → tools/list → create → edit → validate → render → info。
 */
import { spawn } from "node:child_process";
import { rmSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import readline from "node:readline";

const plugin = fileURLToPath(new URL("..", import.meta.url));
const child = spawn(process.execPath, [plugin + "launcher.mjs"], {
  cwd: "F:/yaohai-epic",
  stdio: ["pipe", "pipe", "inherit"],
});
const rl = readline.createInterface({ input: child.stdout });
const pending = new Map();
let nextId = 1;

rl.on("line", (line) => {
  if (!line.trim()) return;
  try {
    const msg = JSON.parse(line);
    if (msg.id !== undefined && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    }
  } catch { /* 非 JSON 行忽略 */ }
});

function request(method, params, timeoutMs = 600000) {
  return new Promise((resolve, reject) => {
    const id = nextId++;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(method + " 超时")); }, timeoutMs);
    pending.set(id, (msg) => { clearTimeout(timer); resolve(msg); });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
}

const call = async (name, args) => {
  const res = await request("tools/call", { name, arguments: args });
  const text = (res.result?.content ?? []).map((c) => c.text ?? "").join("\n");
  const img = (res.result?.content ?? []).find((c) => c.type === "image");
  return { ok: !res.result?.isError, text, img, raw: res };
};

const init = await request("initialize", {
  protocolVersion: "2024-11-05",
  capabilities: {},
  clientInfo: { name: "smoke", version: "0" },
}, 30000);
console.log("INIT:", init.result ? `${init.result.serverInfo.name} ${init.result.serverInfo.version}` : "FAIL");
child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");

const tools = await request("tools/list", {}, 30000);
const names = (tools.result?.tools ?? []).map((t) => t.name);
console.log(`TOOLS: ${names.length} 个 → ${names.slice(0, 6).join(", ")} …`);

const r1 = await call("bbmodel_create", {
  file: "_mcp_smoke/robot.bbmodel", format: "free", name: "Smoke Robot",
  resolution: { width: 64, height: 64 },
});
const rev = r1.ok ? JSON.parse(r1.text).revision : "";
console.log("CREATE:", r1.ok ? `ok rev=${rev}` : "FAIL " + r1.text.slice(0, 200));

const r2 = await call("bbmodel_edit", {
  file: "_mcp_smoke/robot.bbmodel", expected_revision: rev,
  operations: [
    { op: "add_group", name: "body", origin: [0, 12, 0] },
    { op: "add_group", name: "head", origin: [0, 24, 0], parent: "body" },
    { op: "add_group", name: "arm_left", origin: [-4, 22, 0], parent: "body" },
    { op: "add_group", name: "arm_right", origin: [4, 22, 0], parent: "body" },
    { op: "add_group", name: "leg_left", origin: [-2, 12, 0] },
    { op: "add_group", name: "leg_right", origin: [2, 12, 0] },
    { op: "add_cube", name: "torso", from: [-4, 12, -3], to: [4, 24, 3], parent: "body" },
    { op: "add_cube", name: "skull", from: [-3, 24, -3], to: [3, 30, 3], parent: "head" },
    { op: "add_cube", name: "arm_l", from: [-6, 12, -2], to: [-4, 22, 2], parent: "arm_left" },
    { op: "add_cube", name: "arm_r", from: [4, 12, -2], to: [6, 22, 2], parent: "arm_right" },
    { op: "add_cube", name: "leg_l", from: [-4, 0, -2], to: [-2, 12, 2], parent: "leg_left" },
    { op: "add_cube", name: "leg_r", from: [2, 0, -2], to: [4, 12, 2], parent: "leg_right" },
    { op: "add_mesh_primitive", shape: "icosphere", diameter: 5, detail: 1, name: "crest", origin: [0, 30, 0], parent: "head" },
  ],
});
console.log("EDIT:", r2.ok ? "ok" : "FAIL " + r2.text.slice(0, 300));

const r3 = await call("bbmodel_validate", { file: "_mcp_smoke/robot.bbmodel" });
console.log("VALIDATE:", r3.ok ? r3.text.replace(/\s+/g, " ").slice(0, 300) : "FAIL " + r3.text.slice(0, 300));

const r4 = await call("bbmodel_render", {
  file: "_mcp_smoke/robot.bbmodel", preset: "icon",
  output: "_mcp_smoke/robot_icon.png", overwrite: true,
});
console.log("RENDER:", r4.ok ? (r4.img ? "ok(image)" : "ok-noimg") : "FAIL " + r4.text.slice(0, 300));
if (r4.img?.data) {
  writeFileSync(plugin + ".smoke/render_out.png", Buffer.from(r4.img.data, "base64"));
  console.log("RENDER image saved → plugins/blockbench-mcp/.smoke/render_out.png");
}

const r5 = await call("bbmodel_info", { file: "_mcp_smoke/robot.bbmodel" });
console.log("INFO:", r5.ok ? r5.text.replace(/\s+/g, " ").slice(0, 200) : "FAIL");

child.kill();
try { rmSync("F:/yaohai-epic/_mcp_smoke", { recursive: true, force: true }); console.log("CLEANUP: ok"); } catch { console.log("CLEANUP: skip"); }
