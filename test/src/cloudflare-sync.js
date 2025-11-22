const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const yaml = require("js-yaml");

const CONFIG_PATH = path.join(__dirname, "..", "config", "projects.json");

function loadConfig() {
  try {
    const raw = fs.readFileSync(CONFIG_PATH, "utf8");
    return JSON.parse(raw);
  } catch (err) {
    console.error("[cloudflare-sync] Failed to read config/projects.json");
    console.error(err.message);
    process.exit(1);
  }
}

function buildIngressForProfile(config, profileName) {
  const profile = config.cloudflare.profiles[profileName];
  if (!profile) {
    console.error(`[cloudflare-sync] Profile not found: ${profileName}`);
    return { ingress: [], hosts: [] };
  }

  const hosts = [];
  const ingress = [];

  for (const project of config.projects || []) {
    if (project.cloudflareProfile !== profileName) continue;

    const branches = project.branches || {};
    for (const [branchName, br] of Object.entries(branches)) {
      if (!br.cloudflare || !br.cloudflare.enabled) continue;

      const sub = br.cloudflare.subdomain;
      const localPort = br.cloudflare.localPort;
      const localPath = br.cloudflare.localPath || "/";
      const protocol = br.cloudflare.protocol || "http";

      if (!sub || !localPort) {
        console.warn(
          `[cloudflare-sync] Skip ${project.name}/${branchName}: subdomain or localPort missing`
        );
        continue;
      }

      const hostname = `${sub}.${profile.rootDomain}`;
      const service = `${protocol}://localhost:${localPort}${localPath}`;

      ingress.push({ hostname, service });
      hosts.push(hostname);
    }
  }

  // Fallback 404
  ingress.push({ service: "http_status:404" });

  return { ingress, hosts };
}

function updateProfile(config, profileName) {
  const profile = config.cloudflare.profiles[profileName];
  if (!profile) return;

  const configFile = profile.configFile;
  const tunnelName = profile.tunnelName;
  const serviceName = profile.serviceName;

  if (!configFile || !tunnelName) {
    console.error(
      `[cloudflare-sync] configFile or tunnelName missing for profile ${profileName}`
    );
    return;
  }

  const { ingress, hosts } = buildIngressForProfile(config, profileName);

  let yml = {};
  if (fs.existsSync(configFile)) {
    try {
      yml = yaml.load(fs.readFileSync(configFile, "utf8")) || {};
    } catch (err) {
      console.error(`[cloudflare-sync] Failed to load YAML: ${configFile}`);
      console.error(err.message);
    }
  }

  // Keep tunnel / credentials-file / others, only override ingress
  yml.ingress = ingress;

  try {
    fs.writeFileSync(configFile, yaml.dump(yml), "utf8");
    console.log(`[cloudflare-sync] Updated ingress in ${configFile}`);
  } catch (err) {
    console.error(`[cloudflare-sync] Failed to write YAML: ${configFile}`);
    console.error(err.message);
    return;
  }

  // DNS routes
  for (const host of hosts) {
    try {
      console.log(
        `[cloudflare-sync] cloudflared tunnel route dns ${tunnelName} ${host}`
      );
      execSync(`cloudflared tunnel route dns ${tunnelName} ${host}`, {
        stdio: "inherit"
      });
    } catch (err) {
      console.error(
        `[cloudflare-sync] route dns failed for ${host}: ${err.message}`
      );
    }
  }

  // Restart systemd service
  if (serviceName) {
    try {
      console.log(`[cloudflare-sync] Restart service: ${serviceName}`);
      execSync(`systemctl restart ${serviceName}`, { stdio: "inherit" });
    } catch (err) {
      console.error(
        `[cloudflare-sync] Failed to restart service ${serviceName}: ${err.message}`
      );
    }
  }
}

function main() {
  const config = loadConfig();

  if (!config.cloudflare || !config.cloudflare.profiles) {
    console.error("[cloudflare-sync] No cloudflare.profiles in config");
    process.exit(1);
  }

  const profiles = Object.keys(config.cloudflare.profiles);
  if (!profiles.length) {
    console.error("[cloudflare-sync] No profiles defined");
    process.exit(1);
  }

  for (const name of profiles) {
    console.log(`=== Cloudflare profile: ${name} ===`);
    updateProfile(config, name);
  }

  console.log("[cloudflare-sync] Done.");
}

main();
