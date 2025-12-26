#!/bin/bash

# File Structure Helper for webook_deploy_debian
# Displays and explains the project structure

set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for better visibility
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

show_usage() {
    cat << EOF
${CYAN}File Structure Helper for webook_deploy_debian${NC}

Usage: $0 [OPTIONS]

Options:
    -h, --help              Show this help message
    -t, --tree              Show full directory tree
    -s, --summary           Show structure summary (default)
    -d, --detailed          Show detailed structure with descriptions
    -c, --config            Show config directory structure
    -v, --verify            Verify all expected files exist

Description:
    This script helps you understand the file structure of the
    webook_deploy_debian repository and navigate its components.

EOF
}

show_summary() {
    echo -e "${CYAN}=== Repository Structure Summary ===${NC}\n"
    
    cat << 'EOF'
webook_deploy_debian/
├── 📄 Core Files
│   ├── install.sh              - Main installation script
│   ├── webhook.js              - Webhook HTTP server (Node.js)
│   └── package.json            - Node.js dependencies
│
├── 📁 scripts/                 - All deployment and setup scripts
│   ├── env-bootstrap.sh        - Install base tools (Docker, Node, etc.)
│   ├── enable_ssh.sh           - Setup SSH user and permissions
│   ├── init.sh                 - Configuration wizard
│   ├── deploy_config.sh        - Deploy all configured projects
│   ├── check_env.sh            - Environment validation
│   ├── manage_projects.sh      - Project management utilities
│   ├── fix_permissions.sh      - Fix file ownership issues
│   ├── clear_all.sh            - Cleanup utility
│   │
│   ├── Deploy Templates:
│   │   ├── deploy.template.sh        - Docker project template
│   │   ├── deploy-static.template.sh - Static files template
│   │   └── deploy-php.template.sh    - PHP project template
│   │
│   ├── Cloudflare Integration:
│   │   ├── setup_webhook_service.sh  - Setup webhook systemd service
│   │   ├── install_cloudflare_service.sh
│   │   ├── register_cloudflare.sh
│   │   ├── sync_cloudflare.sh
│   │   ├── sync_cloudflare_dns.sh
│   │   ├── check_cloudflare.sh
│   │   └── reload_cloudflare.sh
│   │
│   └── optimizations/          - Performance optimization scripts
│
├── 📁 config/                  - Generated configuration (not in git)
│   ├── projects.json           - Main configuration file
│   ├── projects.example.json   - Example configuration
│   ├── env_bootstrap.json      - Bootstrap state
│   ├── ssh_state.json          - SSH user state
│   └── projects_state.json     - Project initialization state
│
└── 📚 Documentation
    ├── README.md               - Main documentation
    ├── README-lite.md          - Quick reference
    ├── FAST-DEPLOY-RU.md       - Fast deployment guide (Russian)
    ├── STATIC-DEPLOY.md        - Static file deployment guide
    ├── OPTIMIZATION.md         - Performance optimization guide
    ├── OPTIMIZATION-SUMMARY.md - Optimization summary
    └── WORKFLOW-DIAGRAM.md     - Workflow visualization

EOF
}

show_detailed() {
    echo -e "${CYAN}=== Detailed File Structure ===${NC}\n"
    
    echo -e "${GREEN}📄 ROOT LEVEL FILES${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cat << EOF
install.sh              Main installation script (run as root)
                        - Sets up user, groups, and environment
                        - Manages installation state

webhook.js              Node.js webhook HTTP server
                        - Receives Git webhooks
                        - Matches repos/branches to projects
                        - Triggers deployment scripts

package.json            Node.js dependencies for webhook.js
.gitignore              Git ignore patterns
file_structure.sh       This script - file structure helper

EOF

    echo -e "\n${GREEN}📁 SCRIPTS DIRECTORY${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${YELLOW}Setup & Initialization:${NC}"
    cat << EOF
  env-bootstrap.sh      Install system dependencies
                        - APT update/upgrade
                        - Docker, curl, git, node, jq
                        - Creates config/env_bootstrap.json

  enable_ssh.sh         Create webhook user with permissions
                        - Creates SSH user (default: webuser)
                        - Adds to sudo and docker groups
                        - Creates config/ssh_state.json

  init.sh               Interactive configuration wizard
                        - Webhook port/path/secret setup
                        - Project configuration (repo, branch, workDir)
                        - Cloudflare tunnel metadata
                        - Generates config/projects.json

EOF

    echo -e "${YELLOW}Deployment:${NC}"
    cat << EOF
  deploy_config.sh      Deploy all configured projects
                        - Reads config/projects.json
                        - For each project: clone/pull and run deploy.sh
                        - Manages Cloudflare tunnel routing

  deploy.template.sh    Template for Docker projects
                        - Smart git pull with change detection
                        - Conditional rebuild (only if needed)
                        - Docker Compose orchestration
                        - Copied to each project as deploy.sh

  deploy-static.template.sh   Template for static file projects
                              - Serves files via Python HTTP server
                              - 2-5 second deployment time
                              - No Docker required

  deploy-php.template.sh      Template for PHP projects
                              - PHP-specific deployment logic

EOF

    echo -e "${YELLOW}Management & Utilities:${NC}"
    cat << EOF
  manage_projects.sh    Project management utilities
                        - Add/remove/list projects
                        - Update project configurations

  check_env.sh          Environment validation
                        - Checks Docker, Node, cloudflared
                        - Validates configuration files
                        - Tests webhook port

  fix_permissions.sh    Fix ownership issues
                        - Corrects file permissions
                        - Ensures webhook user owns project files

  clear_all.sh          Cleanup utility
                        - Removes generated configs
                        - Cleans up project directories

  after_install_fix.sh  Post-installation fixes

EOF

    echo -e "${YELLOW}Cloudflare Integration:${NC}"
    cat << EOF
  setup_webhook_service.sh      Setup webhook as systemd service
  install_cloudflare_service.sh Install cloudflared as service
  register_cloudflare.sh        Register tunnel with Cloudflare
  sync_cloudflare.sh            Sync tunnel configuration
  sync_cloudflare_dns.sh        Sync DNS records
  check_cloudflare.sh           Check tunnel status
  reload_cloudflare.sh          Reload tunnel configuration

EOF

    echo -e "\n${GREEN}📁 CONFIG DIRECTORY${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cat << EOF
projects.json           Main configuration (auto-generated)
                        - Webhook settings (port, path, secret)
                        - Project definitions
                        - Cloudflare tunnel metadata

projects.example.json   Example configuration template
                        - Shows expected structure
                        - Contains placeholder values

env_bootstrap.json      Environment bootstrap state
                        - Version and timestamp
                        - Used by install.sh for idempotency

ssh_state.json          SSH user state
                        - Username and setup status
                        - Version and timestamp

projects_state.json     Project initialization state
                        - Tracks init.sh runs
                        - Version and timestamp

Note: All .json files except projects.example.json are generated
      and excluded from git via .gitignore

EOF

    echo -e "\n${GREEN}📚 DOCUMENTATION${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cat << EOF
README.md                   Comprehensive documentation
                            - Features and architecture
                            - Setup instructions
                            - Configuration guide

README-lite.md              Quick reference guide
FAST-DEPLOY-RU.md           Fast deployment guide (Russian)
STATIC-DEPLOY.md            Static file deployment documentation
OPTIMIZATION.md             Performance optimization guide
OPTIMIZATION-SUMMARY.md     Optimization summary
WORKFLOW-DIAGRAM.md         Visual workflow explanation

EOF
}

show_tree() {
    echo -e "${CYAN}=== Full Directory Tree ===${NC}\n"
    
    if command -v tree &> /dev/null; then
        cd "$ROOT_DIR"
        tree -a -L 3 -I '.git' --dirsfirst
    else
        echo "Note: 'tree' command not installed. Showing basic structure..."
        echo
        cd "$ROOT_DIR"
        find . -not -path '*/\.git/*' -type f -o -type d | head -100 | sort
    fi
}

show_config_structure() {
    echo -e "${CYAN}=== Config Directory Structure ===${NC}\n"
    
    CONFIG_DIR="$ROOT_DIR/config"
    
    if [ -d "$CONFIG_DIR" ]; then
        echo -e "${GREEN}Config directory exists at:${NC} $CONFIG_DIR"
        echo
        
        echo "Files present:"
        ls -lh "$CONFIG_DIR" 2>/dev/null | tail -n +2 | while read -r line; do
            filename=$(echo "$line" | awk '{print $NF}')
            if [ -f "$CONFIG_DIR/$filename" ]; then
                echo -e "  ${GREEN}✓${NC} $filename"
            fi
        done
        echo
        
        echo "Expected files:"
        echo -e "  ${BLUE}•${NC} projects.json          (auto-generated by init.sh)"
        echo -e "  ${BLUE}•${NC} projects.example.json  (template, tracked in git)"
        echo -e "  ${BLUE}•${NC} env_bootstrap.json     (auto-generated by env-bootstrap.sh)"
        echo -e "  ${BLUE}•${NC} ssh_state.json         (auto-generated by enable_ssh.sh)"
        echo -e "  ${BLUE}•${NC} projects_state.json    (auto-generated by init.sh)"
    else
        echo -e "${YELLOW}Config directory does not exist yet.${NC}"
        echo "It will be created when you run install.sh or init.sh"
    fi
    echo
}

verify_structure() {
    echo -e "${CYAN}=== Verifying Repository Structure ===${NC}\n"
    
    local errors=0
    local warnings=0
    
    echo "Checking core files..."
    
    # Core files
    if [ -f "$ROOT_DIR/install.sh" ]; then
        echo -e "  ${GREEN}✓${NC} install.sh"
    else
        echo -e "  ${YELLOW}✗${NC} install.sh ${YELLOW}(missing)${NC}"
        ((errors++))
    fi
    
    if [ -f "$ROOT_DIR/webhook.js" ]; then
        echo -e "  ${GREEN}✓${NC} webhook.js"
    else
        echo -e "  ${YELLOW}✗${NC} webhook.js ${YELLOW}(missing)${NC}"
        ((errors++))
    fi
    
    echo
    echo "Checking scripts directory..."
    
    if [ -d "$ROOT_DIR/scripts" ]; then
        echo -e "  ${GREEN}✓${NC} scripts/ directory exists"
        
        # Check key scripts
        for script in env-bootstrap.sh enable_ssh.sh init.sh deploy_config.sh check_env.sh \
                      deploy.template.sh deploy-static.template.sh manage_projects.sh; do
            if [ -f "$ROOT_DIR/scripts/$script" ]; then
                echo -e "    ${GREEN}✓${NC} $script"
            else
                echo -e "    ${YELLOW}✗${NC} $script ${YELLOW}(missing)${NC}"
                ((warnings++))
            fi
        done
    else
        echo -e "  ${YELLOW}✗${NC} scripts/ directory ${YELLOW}(missing)${NC}"
        ((errors++))
    fi
    
    echo
    echo "Checking documentation..."
    
    for doc in README.md README-lite.md STATIC-DEPLOY.md OPTIMIZATION.md; do
        if [ -f "$ROOT_DIR/$doc" ]; then
            echo -e "  ${GREEN}✓${NC} $doc"
        else
            echo -e "  ${YELLOW}!${NC} $doc ${YELLOW}(missing)${NC}"
            ((warnings++))
        fi
    done
    
    echo
    echo "Checking config..."
    
    if [ -d "$ROOT_DIR/config" ]; then
        echo -e "  ${GREEN}✓${NC} config/ directory exists"
        
        if [ -f "$ROOT_DIR/config/projects.json" ]; then
            echo -e "    ${GREEN}✓${NC} projects.json (configured)"
        else
            echo -e "    ${BLUE}•${NC} projects.json (not yet configured - run init.sh)"
        fi
    else
        echo -e "  ${BLUE}•${NC} config/ directory (will be created on first run)"
    fi
    
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ $errors -eq 0 ] && [ $warnings -eq 0 ]; then
        echo -e "${GREEN}✓ Repository structure is complete!${NC}"
    elif [ $errors -eq 0 ]; then
        echo -e "${YELLOW}⚠ Repository structure is OK with $warnings optional files missing${NC}"
    else
        echo -e "${YELLOW}⚠ Found $errors critical issues and $warnings warnings${NC}"
    fi
    echo
}

# Main script logic
case "${1:-}" in
    -h|--help)
        show_usage
        ;;
    -t|--tree)
        show_tree
        ;;
    -s|--summary|"")
        show_summary
        ;;
    -d|--detailed)
        show_detailed
        ;;
    -c|--config)
        show_config_structure
        ;;
    -v|--verify)
        verify_structure
        ;;
    *)
        echo "Unknown option: $1"
        echo "Use -h or --help for usage information"
        exit 1
        ;;
esac
