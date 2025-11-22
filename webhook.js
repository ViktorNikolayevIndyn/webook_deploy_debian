#!/usr/bin/env node

/**
 * webhook.js
 * GitHub Webhook → автодеплой по config/projects.json
 *
 * НИЧЕГО не устанавливает, только:
 *  - слушает HTTP webhook
 *  - проверяет подпись (если задан secret)
 *  - по событию push дергает deployScript для подходящих проектов
 */

const http = require("http");
const crypto = require("crypto");
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

// ---------- Загрузка конфига ----------

const ROOT_DIR = path.resolve(__dirname);
const CONFIG_DIR = path.join(ROOT_DIR, "config");
const CONFIG_FILE = path.join(CONFIG_DIR, "projects.json");

function loadConfig() {
  if (!fs.existsSync(CONFIG_FILE)) {
    console.error(`[config] Config file not found: ${CONFIG_FILE}`);
    process.exit(1);
  }

  try {
    const raw = fs.readFileSync(CONFIG_FILE, "utf8");
    const cfg = JSON.parse(raw);
    console.log("[config] Loaded projects.json");
    return cfg;
  } catch (e) {
    console.error("[config] Failed to parse projects.json:", e.message);
    process.exit(1);
  }
}

// Первый загруз конфига
let CONFIG = loadConfig();

// ---------- Хелперы ----------

function verifySignature(secret, payload, signature) {
  // Если secret пустой → подпись не проверяем
  if (!secret) {
    console.warn("[verify] No secret configured, skipping signature check.");
    return true;
  }

  if (!signature || typeof signature !== "string") {
    console.warn("[verify] Missing X-Hub-Signature-256 header.");
    return false;
  }

  const hmac = crypto.createHmac("sha256", secret);
  const digest = "sha256=" + hmac.update(payload).digest("hex");

  const sigBuf = Buffer.from(signature);
  const digBuf = Buffer.from(digest);

  if (sigBuf.length !== digBuf.length) {
    return false;
  }

  return crypto.timingSafeEqual(sigBuf, digBuf);
}

function runDeploy(project, ref) {
  const name = project.name || "<unnamed>";
  const script = project.deployScript;
  const args = project.deployArgs || [];

  if (!script) {
    console.warn(`[deploy] Project '${name}' has no deployScript. Skipping.`);
    return;
  }

  console.log(
    `[deploy] Starting deploy for '${name}' (ref=${ref || "n/a"}) via: ${script} ${args.join(
      " "
    )}`
  );

  const child = spawn(script, args, {
    cwd: project.workDir || ROOT_DIR,
    stdio: "inherit",
    shell: true,
  });

  child.on("exit", (code) => {
    console.log(
      `[deploy] Deploy for '${name}' finished with exit code ${code}`
    );
  });

  child.on("error", (err) => {
    console.error(
      `[deploy] Failed to spawn deploy for '${name}':`,
      err.message
    );
  });
}

// ---------- HTTP server (GitHub webhook) ----------

function createServer() {
  // На старте освежаем конфиг
  CONFIG = loadConfig();

  const webhookCfg = CONFIG.webhook || {};
  const port = webhookCfg.port || 4000;
  const pathExpected = webhookCfg.path || "/github";
  const secret = webhookCfg.secret || "";

  const server = http.createServer((req, res) => {
    if (req.url !== pathExpected || req.method !== "POST") {
      res.statusCode = 404;
      return res.end("Not found");
    }

    const sig = req.headers["x-hub-signature-256"];
    const event = req.headers["x-github-event"];
    const delivery = req.headers["x-github-delivery"];

    console.log(
      `[webhook] Incoming request: event=${event}, delivery=${delivery}, path=${req.url}`
    );

    let body = [];
    req
      .on("data", (chunk) => {
        body.push(chunk);
      })
      .on("end", () => {
        body = Buffer.concat(body);
        const payloadString = body.toString("utf8");

        // Проверка подписи
        if (!verifySignature(secret, payloadString, sig)) {
          console.warn("[webhook] Signature verification FAILED. Ignoring.");
          res.statusCode = 401;
          return res.end("Invalid signature");
        }

        let payload;
        try {
          payload = JSON.parse(payloadString);
        } catch (e) {
          console.error("[webhook] Failed to parse JSON payload:", e.message);
          res.statusCode = 400;
          return res.end("Invalid JSON");
        }

        const repoFullName =
          payload.repository && payload.repository.full_name
            ? payload.repository.full_name
            : "";
        const ref = payload.ref || "";

        console.log(
          `[webhook] Payload: repo=${repoFullName}, ref=${ref}, event=${event}`
        );

        if (event === "ping") {
          console.log("[webhook] ping event – OK");
          res.statusCode = 200;
          return res.end("pong");
        }

        if (event !== "push") {
          console.log("[webhook] Not a push event. Ignoring.");
          res.statusCode = 200;
          return res.end("ignored");
        }

        const projects = CONFIG.projects || [];
        let matched = 0;

        for (const project of projects) {
          if (!project.repo || !project.branch) continue;

          const repoMatch = project.repo === repoFullName;
          const refMatch = ref === `refs/heads/${project.branch}`;

          if (repoMatch && refMatch) {
            matched += 1;
            runDeploy(project, ref);
          }
        }

        console.log(`[webhook] Matched projects: ${matched}`);
        res.statusCode = 200;
        res.end(`ok, matched=${matched}`);
      })
      .on("error", (err) => {
        console.error("[webhook] Request error:", err.message);
        res.statusCode = 500;
        res.end("error");
      });
  });

  server.listen(port, () => {
    console.log(
      `[webhook] Listening on port ${port}, path=${pathExpected}, config=${CONFIG_FILE}`
    );
  });

  server.on("error", (err) => {
    console.error("[webhook] Server error:", err.message);
  });

  return server;
}

// ---------- START ----------

createServer();
