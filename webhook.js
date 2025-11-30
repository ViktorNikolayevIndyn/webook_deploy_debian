// webhook.js
// Simple GitHub webhook -> deploy runner with /health endpoint

const http = require("http");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { spawn, execSync } = require("child_process");

const ROOT_DIR = __dirname;
const CONFIG_PATH = path.join(ROOT_DIR, "config", "projects.json");
const PACKAGE_JSON_PATH = path.join(ROOT_DIR, "package.json");

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

// извлекаем имя ветки из ref
// "refs/heads/main" -> "main"
function extractBranch(ref) {
  if (!ref) return null;
  if (ref.startsWith("refs/heads/")) {
    return ref.substring("refs/heads/".length);
  }
  return ref;
}

function getVersionInfo() {
  const info = {
    packageVersion: null,
    gitRev: null,
    gitShortRev: null,
    gitBranch: null,
  };

  // Версия из package.json (если есть)
  try {
    if (fs.existsSync(PACKAGE_JSON_PATH)) {
      const raw = fs.readFileSync(PACKAGE_JSON_PATH, "utf8");
      const pkg = JSON.parse(raw);
      if (pkg && pkg.version) {
        info.packageVersion = pkg.version;
      }
    }
  } catch (e) {
    // просто пропускаем
  }

  // Инфо из git
  try {
    info.gitRev = execSync("git rev-parse HEAD", {
      cwd: ROOT_DIR,
      stdio: ["ignore", "pipe", "ignore"],
    })
      .toString()
      .trim();
  } catch (e) {}

  try {
    info.gitShortRev = execSync("git rev-parse --short HEAD", {
      cwd: ROOT_DIR,
      stdio: ["ignore", "pipe", "ignore"],
    })
      .toString()
      .trim();
  } catch (e) {}

  try {
    info.gitBranch = execSync("git rev-parse --abbrev-ref HEAD", {
      cwd: ROOT_DIR,
      stdio: ["ignore", "pipe", "ignore"],
    })
      .toString()
      .trim();
  } catch (e) {}

  return info;
}

loadConfig();

const webhookCfg = (config && config.webhook) || {};
const webhookPort = webhookCfg.port || 4000;
const webhookPath =
  (webhookCfg.path || "/github").replace(/\/+$/, "") || "/github";
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
    console.warn("[verify] Missing X-Hub-Signature-256 header.");
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

// новая логика матчинга: только repo + branch, без хитрых эвристик
function matchProjectsByPayload(payload) {
  if (!config || !Array.isArray(config.projects)) return [];

  const repoFull = payload?.repository?.full_name || "";
  const ref = payload?.ref || "";
  const branchName = extractBranch(ref);

  console.log(
    `[match] Incoming: repo=${repoFull}, ref=${ref}, branch=${branchName}`
  );

  if (!repoFull || !branchName) {
    console.log("[match] repo or branch is empty, no matches.");
    return [];
  }

  console.log("[match] Projects in config:");
  for (const p of config.projects) {
    console.log(
      `  - name=${p.name}, repo=${p.repo}, branch=${p.branch}, workDir=${p.workDir}`
    );
  }

  const matches = config.projects.filter((p) => {
    if (!p.repo) return false;

    // строгое совпадение полного имени репо
    if (p.repo !== repoFull) return false;

    // если ветка в конфиге не задана – матчим все ветки этого репо
    if (!p.branch) return true;

    // точное совпадение имени ветки
    return p.branch === branchName;
  });

  console.log(`[match] Matched ${matches.length} project(s).`);
  return matches;
}

// Send GitHub commit status (priority: env var > config file > secrets file)
function sendGitHubStatus(repo, sha, state, description, context) {
  let token = process.env.GITHUB_TOKEN;
  
  // Try to read from config file
  if (!token && config?.webhook?.githubToken) {
    token = config.webhook.githubToken;
  }
  
  // Try to read from secrets file if still not set
  if (!token) {
    const tokenPath = path.join(ROOT_DIR, "secrets", "github_token");
    try {
      token = fs.readFileSync(tokenPath, "utf8").trim();
    } catch (err) {
      // Token file doesn't exist, that's ok
    }
  }
  
  if (!token) {
    console.log("[github] No GITHUB_TOKEN found, skipping status update");
    return;
  }

  const data = JSON.stringify({
    state,
    description,
    context: context || "webhook-deploy",
  });

  const options = {
    hostname: "api.github.com",
    path: `/repos/${repo}/statuses/${sha}`,
    method: "POST",
    headers: {
      "User-Agent": "webhook-deploy",
      "Authorization": `Bearer ${token}`,
      "Content-Type": "application/json",
      "Content-Length": data.length,
    },
  };

  const req = http.request(options, (res) => {
    if (res.statusCode === 201) {
      console.log(`[github] Status updated: ${state} for ${repo}@${sha.substring(0, 7)}`);
    } else {
      console.error(`[github] Failed to update status: ${res.statusCode}`);
    }
  });

  req.on("error", (err) => {
    console.error("[github] Error sending status:", err.message);
  });

  req.write(data);
  req.end();
}

function runDeployForProject(project, ref, sha) {
  const name = project.name || "noname";
  const workDir = project.workDir || ROOT_DIR;
  const deployScript =
    project.deployScript || path.join(workDir, "deploy.sh");
  const deployArgs = Array.isArray(project.deployArgs)
    ? project.deployArgs
    : [];

  console.log(
    `[deploy] Starting deploy for '${name}' (ref=${ref}) via: ${deployScript} ${deployArgs.join(
      " "
    )}`
  );

  // Send pending status to GitHub
  if (project.repo && sha) {
    sendGitHubStatus(project.repo, sha, "pending", `Deploying ${name}...`, `deploy/${name}`);
  }

  // Prepare environment with restartOnDeploy setting
  const deployEnv = {
    ...process.env,
  };
  
  // Add RESTART_ON_DEPLOY env var if configured (for static sites)
  if (project.hasOwnProperty('restartOnDeploy')) {
    deployEnv.RESTART_ON_DEPLOY = String(project.restartOnDeploy);
    console.log(`[deploy] restartOnDeploy=${project.restartOnDeploy}`);
  }

  const child = spawn(deployScript, deployArgs, {
    cwd: workDir,
    env: deployEnv,
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
    
    // Send error status to GitHub
    if (project.repo && sha) {
      sendGitHubStatus(project.repo, sha, "error", `Deploy failed: ${err.message}`, `deploy/${name}`);
    }
  });

  child.on("close", (code) => {
    console.log(
      `[deploy] Deploy process for '${name}' exited with code ${code}`
    );
    
    // Send success/failure status to GitHub
    if (project.repo && sha) {
      if (code === 0) {
        sendGitHubStatus(project.repo, sha, "success", `Deploy completed successfully`, `deploy/${name}`);
      } else {
        sendGitHubStatus(project.repo, sha, "failure", `Deploy failed (exit code ${code})`, `deploy/${name}`);
      }
    }
  });
}

const server = http.createServer((req, res) => {
  const urlPath = req.url.split("?")[0].replace(/\/+$/, "") || "/";

  // --------- /health ----------
  if (req.method === "GET" && urlPath === "/health") {
    const version = getVersionInfo();
    const body = {
      status: "ok",
      ts: new Date().toISOString(),
      configPath: CONFIG_PATH,
      webhook: {
        port: webhookPort,
        path: webhookPath,
        secretEnabled: !!webhookSecret,
      },
      version,
    };

    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(body, null, 2));
    return;
  }

  // --------- GitHub webhook ----------
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
      console.warn("[webhook] Signature verification FAILED. Ignoring.");
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
    const sha = payload?.after || payload?.head_commit?.id || "unknown";

    console.log(
      `[webhook] Payload: repo=${repoFull}, ref=${ref}, sha=${sha.substring(0, 7)}, event=${event}`
    );

    if (event !== "push") {
      console.log("[webhook] Non-push event, ignoring.");
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("Ignored (non-push)\n");
      return;
    }

    const matchedProjects = matchProjectsByPayload(payload);
    console.log(`[webhook] Matched projects: ${matchedProjects.length}`);

    if (matchedProjects.length === 0) {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("No matching projects\n");
      return;
    }

    // отвечаем сразу – деплой идёт в фоне
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("OK\n");

    for (const p of matchedProjects) {
      runDeployForProject(p, ref, sha);
    }
  });
});

server.listen(webhookPort, () => {
  console.log(
    `[webhook] Listening on port ${webhookPort}, path=${webhookPath}, config=${CONFIG_PATH}`
  );
});
