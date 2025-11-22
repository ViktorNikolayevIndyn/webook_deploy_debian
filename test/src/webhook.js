const config = loadConfig();

const WH = config.webhook || {};
const PORT = WH.port || 4000;
const PATHNAME = WH.path || "/github";
const SECRET = WH.secret || "";

const CONFIG_PATH = path.join(__dirname, "..", "config", "projects.json");
const ROOT_DIR_DEFAULT = path.join(__dirname, "..");

// === Загрузка конфига ===
function loadConfig() {
  try {
    const raw = fs.readFileSync(CONFIG_PATH, "utf8");
    return JSON.parse(raw);
  } catch (err) {
    console.error("[webhook] ERROR: cannot read config:", CONFIG_PATH, err.message);
    process.exit(1);
  }
}


// === Поиск проекта/ветки ===
function findBranchConfig(repoFullName, ref) {
  // ref вида "refs/heads/dev-branch-cloud" -> берём только имя ветки
  const branchName = ref.replace(/^refs\/heads\//, "");

  const project = (config.projects || []).find(
    (p) => p.repo === repoFullName
  );

  if (!project) {
    console.log(`[webhook] No project config for repo=${repoFullName}`);
    return null;
  }

  const branchCfg = project.branches && project.branches[branchName];

  if (!branchCfg) {
    console.log(`[webhook] No branch config for repo=${repoFullName}, branch=${branchName}`);
    return null;
  }

  if (branchCfg.enabled === false) {
    console.log(
      `[webhook] Branch disabled in config: repo=${repoFullName}, branch=${branchName}`
    );
    return null;
  }

  return {
    project,
    branchName,
    branchCfg
  };
}

// === Запуск команды деплоя ===
function runDeploy(project, branchName, branchCfg, config) {
  const rootDir =
    (config.rootDir && config.rootDir.trim() !== "")
      ? config.rootDir
      : ROOT_DIR_DEFAULT;

  const deployScriptName = config.deployScript || "deploy.sh";

  const deployScript = path.isAbsolute(deployScriptName)
    ? deployScriptName
    : path.join(rootDir, deployScriptName);

  const repoDirRel = branchCfg.repoDir;
  const composeRel = branchCfg.composeFile;
  const serviceName = branchCfg.service;

  if (!repoDirRel || !composeRel || !serviceName) {
    console.log(
      `[webhook] Missing repoDir/composeFile/service in branch config for repo=${project.repo}, branch=${branchName}`
    );
    return;
  }

  const repoDir = path.isAbsolute(repoDirRel)
    ? repoDirRel
    : path.join(rootDir, repoDirRel);

  const composeFile = path.isAbsolute(composeRel)
    ? composeRel
    : path.join(rootDir, composeRel);

  console.log(
    `[webhook] Starting deploy: project=${project.name}, repo=${project.repo}, branch=${branchName}`
  );
  console.log(`[webhook] RootDir      : ${rootDir}`);
  console.log(`[webhook] DeployScript : ${deployScript}`);
  console.log(`[webhook] RepoDir      : ${repoDir}`);
  console.log(`[webhook] ComposeFile  : ${composeFile}`);
  console.log(`[webhook] Service      : ${serviceName}`);

  const args = [repoDir, branchName, composeFile, serviceName];

  const child = spawn(deployScript, args, {
    stdio: "inherit"
  });

  child.on("close", (code) => {
    console.log(
      `[webhook] Deploy finished: project=${project.name}, branch=${branchName}, code=${code}`
    );
  });
}

// === HTTP-сервер ===
const server = http.createServer((req, res) => {
  if (req.method !== "POST" || req.url !== PATH) {
    res.writeHead(404);
    return res.end("Not found");
  }

  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("end", () => {
    const body = Buffer.concat(chunks).toString("utf8");

    let payload;
    try {
      payload = JSON.parse(body);
    } catch (e) {
      console.log("[webhook] Invalid JSON");
      res.writeHead(400);
      return res.end("Invalid JSON");
    }

    const event = req.headers["x-github-event"];
    const repoName = payload.repository && payload.repository.full_name;
    const ref = payload.ref;

    console.log(`[webhook] Event=${event}, repo=${repoName}, ref=${ref}`);

    if (!repoName || !ref) {
      res.writeHead(200);
      return res.end("Missing repo/ref");
    }

    if (event !== "push") {
      res.writeHead(200);
      return res.end("Event ignored");
    }

    // Перечитываем конфиг на каждый запрос (чтобы можно было править без рестарта)
    config = loadConfig();

    const result = findBranchConfig(repoName, ref);
    if (!result) {
      res.writeHead(200);
      return res.end("No matching project/branch in config");
    }

    runDeploy(result.project, result.branchName, result.branchCfg, config);

    res.writeHead(200);
    return res.end("Deploy triggered");
  });
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`[webhook] Listening on port ${PORT}, path=${PATH}`);
});
