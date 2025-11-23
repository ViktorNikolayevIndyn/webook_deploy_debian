// webhook.js
// Лёгкий GitHub webhook → deploy runner
// - читает config/projects.json
// - проверяет секрет (X-Hub-Signature-256), если задан
// - на push по нужной ветке запускает deploy.sh напрямую

const http = require("http");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

const CONFIG_PATH = path.join(__dirname, "config", "projects.json");

let config = null;

function loadConfig() {
  try {
    const raw = fs.readFileSync(CONFIG_PATH, "utf8");
    config = JSON.parse(raw);
    console.log("[config] Loaded projects.json");
  } catch (err) {
    console.error("[config] Failed to parse projects.json:", err.message);
    process.exit(1);
  }
}

loadConfig();

const webhookCfg = (config && config.webhook) || {};
const webhookPort = webhookCfg.port || 4000;
const webhookPath = (webhookCfg.path || "/github").replace(/\/+$/, "") || "/github";
const webhookSecret =
  webhookCfg.secret && String(webhookCfg.secret).trim().length > 0
    ? String(webhookCfg.secret).trim()
    : null;

function verifySignature(req, rawBody) {
  if (!webhookSecret) {
    console.log("[verify] No secret configured, skipping signature check.");
    return true;
  }

  const sig = req.headers["x-hub-signature-256"];
  if (!sig || !sig.startsWith("sha256=")) {
    console.warn("[verify] Missing or invalid X-Hub-Signature-256 header.");
    return false;
  }

  const their = sig.slice("sha256=".length).trim();
  const hmac = crypto.createHmac("sha256", webhookSecret);
  hmac.update(rawBody);
  const ours = hmac.digest("hex");

  const ok = crypto.timingSafeEqual(
    Buffer.from(ours, "hex"),
    Buffer.from(their, "hex")
  );

  if (!ok) {
    console.warn("[verify] Signature mismatch.");
  }
  return ok;
}

function matchProjectsByPayload(payload) {
  if (!config || !Array.isArray(config.projects)) return [];

  const repoFull = payload?.repository?.full_name || "";
  const ref = payload?.ref || "";
  const event = payload?.event || "push";

  const matches = [];

  for (const p of config.projects) {
    // repo / gitUrl
    const projRepo = p.repo || "";
    const projGit = p.gitUrl || "";

    let repoMatch = false;

    if (projRepo && repoFull && projRepo === repoFull) {
      repoMatch = true;
    } else if (
      projRepo &&
      repoFull &&
      repoFull.toLowerCase().endsWith("/" + projRepo.split("/").pop())
    ) {
      repoMatch = true;
    } else if (
      projGit &&
      repoFull &&
      projGit.toLowerCase().includes(repoFull.toLowerCase().split("/").pop())
    ) {
      repoMatch = true;
    }

    if (!repoMatch) continue;

    // ветка
    if (p.branch) {
      const expectedRef = `refs/heads/${p.branch}`;
      if (ref !== expectedRef) {
        continue;
      }
    }

    matches.push(p);
  }

  return matches;
}

function runDeployForProject(project, ref) {
  const name = project.name || "noname";
  const workDir = project.workDir || process.cwd();
  const deployScript = project.deployScript || path.join(workDir, "deploy.sh");
  const deployArgs = Array.isArray(project.deployArgs)
    ? project.deployArgs
    : [];

  console.log(
    `[deploy] Starting deploy for '${name}' (ref=${ref}) via: ${deployScript} ${deployArgs.join(
      " "
    )}`
  );

  // ВАЖНО: запускаем СКРИПТ НАПРЯМУЮ, без /bin/sh
  const child = spawn(deployScript, deployArgs, {
    cwd: workDir,
    env: process.env,
  });

  child.stdout.on("data", (data) => {
    process.stdout.write(`[deploy][${name}][stdout] ${data}`);
  });

  child.stderr.on("data", (data) => {
    process.stderr.write(`[deploy][${name}][stderr] ${data}`);
  });

  child.on("error", (err) => {
    console.error(
      `[deploy] Failed to spawn deploy for '${name}':`,
      err.message
    );
  });

  child.on("close", (code) => {
    console.log(
      `[deploy] Deploy process for '${name}' exited with code ${code}`
    );
  });
}

const server = http.createServer((req, res) => {
  const urlPath = req.url.split("?")[0].replace(/\/+$/, "") || "/";
  if (req.method !== "POST" || urlPath !== webhookPath) {
    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("Not found\n");
    return;
  }

  const event = req.headers["x-github-event"] || "unknown";
  const delivery = req.headers["x-github-delivery"] || "n/a";

  console.log(
    `[webhook] Incoming request: event=${event}, delivery=${delivery}, path=${urlPath}`
  );

  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("end", () => {
    const rawBody = Buffer.concat(chunks);
    const bodyStr = rawBody.toString("utf8") || "{}";

    if (!verifySignature(req, rawBody)) {
      res.writeHead(401, { "Content-Type": "text/plain" });
      res.end("Invalid signature\n");
      return;
    }

    let payload;
    try {
      payload = JSON.parse(bodyStr);
    } catch (err) {
      console.error("[webhook] Failed to parse JSON payload:", err.message);
      res.writeHead(400, { "Content-Type": "text/plain" });
      res.end("Invalid JSON\n");
      return;
    }

    const repoFull = payload?.repository?.full_name || "n/a";
    const ref = payload?.ref || "n/a";

    console.log(
      `[webhook] Payload: repo=${repoFull}, ref=${ref}, event=${event}`
    );

    if (event !== "push") {
      console.log("[webhook] Non-push event, ignoring.");
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("Ignored (non-push)\n");
      return;
    }

    const matchedProjects = matchProjectsByPayload(payload);
    console.log(
      `[webhook] Matched projects: ${matchedProjects.length}`
    );

    if (matchedProjects.length === 0) {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("No matching projects\n");
      return;
    }

    // отвечаем сразу, деплой — в фоне
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("OK\n");

    for (const p of matchedProjects) {
      runDeployForProject(p, ref);
    }
  });
});

server.listen(webhookPort, () => {
  console.log(
    `[webhook] Listening on port ${webhookPort}, path=${webhookPath}, config=${CONFIG_PATH}`
  );
});
