#!/usr/bin/env node
/**
 * ZCode 插件启动器：拉起 vendor 目录里的 headless Blockbench MCP server（stdio）。
 *
 * 职责：
 *  1. 找到可用的 Bun（BBMCP_BUN 环境变量 → PATH → vendor 自带的 bun.exe）
 *  2. 解析模型工作区根目录（BBMCP_ROOT → 从 cwd 向上找工程标记 → 插件内 models/）
 *  3. 确保 vendor 依赖已安装（正常情况下随插件一起分发，无需联网）
 *  4. 以继承 stdio 的方式启动 headless/index.ts，并透传信号与退出码
 *
 * MCP 客户端可以在 .mcp.json 的 args 里追加 headless server 的参数
 * （如 --no-web-links），它们会原样跟在 --root 后面。
 */
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const pluginRoot = path.dirname(fileURLToPath(import.meta.url));
const vendorDir = path.join(pluginRoot, "vendor", "blockbench-mcp");
const entry = path.join(vendorDir, "headless", "index.ts");
const log = (msg) => process.stderr.write(`[blockbench-mcp] ${msg}\n`);

/** 依序探测候选 Bun 可执行文件，返回第一个能打印版本的。 */
function findBun() {
  const exe = process.platform === "win32" ? ".exe" : "";
  const candidates = [];
  if (process.env.BBMCP_BUN) candidates.push(process.env.BBMCP_BUN);
  candidates.push("bun"); // PATH
  for (const base of [
    path.join(vendorDir, "node_modules", ".bin", "bun"),
    path.join(vendorDir, "node_modules", "bun", "bin", "bun"),
  ]) {
    candidates.push(base + exe, base);
  }
  for (const cand of candidates) {
    if (cand !== "bun" && !existsSync(cand)) continue;
    const probe = spawnSync(cand, ["--version"], { encoding: "utf8", timeout: 15000 });
    if (probe.status === 0) return cand;
  }
  return null;
}

/** 从 cwd 向上找工程根（跳过插件自身目录），找不到则退回插件内 models/。 */
function resolveRoot() {
  const explicit = process.env.BBMCP_ROOT || process.env.BBMCP_MODELS_ROOT;
  if (explicit) return path.resolve(explicit);
  const markers = [
    "project.godot", ".git", "package.json", "go.mod", "Cargo.toml",
    "pyproject.toml", "pom.xml", "Makefile",
  ];
  let dir = process.cwd();
  while (true) {
    if (!dir.startsWith(pluginRoot) && markers.some((m) => existsSync(path.join(dir, m)))) {
      return dir;
    }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  const fallback = path.join(pluginRoot, "models");
  mkdirSync(fallback, { recursive: true });
  log(`cwd 附近没有找到工程标记，模型根目录退回 ${fallback}（可用 BBMCP_ROOT 指定）`);
  return fallback;
}

const bun = findBun();
if (!bun) {
  log("找不到 Bun。请安装 Bun（https://bun.sh）或设置 BBMCP_BUN 指向 bun 可执行文件。");
  process.exit(1);
}
if (!existsSync(entry)) {
  log(`缺少 headless 入口：${entry}，插件 vendor 目录不完整。`);
  process.exit(1);
}
// 依赖缺失时现场安装一次（联网）；随插件分发的 node_modules 一般不会走到这里。
if (!existsSync(path.join(vendorDir, "node_modules", "zod"))) {
  log("首次启动：安装 vendor 依赖（需要网络）…");
  const install = spawnSync(bun, ["install", "--production"], { cwd: vendorDir, stdio: "inherit" });
  if (install.status !== 0) {
    log("依赖安装失败。请在 " + vendorDir + " 手动执行 bun install --production。");
    process.exit(1);
  }
}

const root = resolveRoot();
const args = [entry, "--root", root, ...process.argv.slice(2)];
log(`启动 headless server：${bun} headless/index.ts --root ${root}`);
const child = spawn(bun, args, { stdio: "inherit", cwd: vendorDir });

child.on("error", (err) => {
  log(`启动失败：${err.message}`);
  process.exit(1);
});
child.on("exit", (code, signal) => process.exit(code ?? (signal ? 1 : 0)));
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => child.kill(sig));
}
