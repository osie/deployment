# OSIE Docker Compose Deployment

## Quick Install (Single VM)

```bash
wget https://raw.githubusercontent.com/osie/deployment/main/docker-compose/install.sh
sudo bash install.sh
```

The installer will interactively guide you through setup. It:

1. Asks for a **public domain** (Let's Encrypt HTTPS) or **IP address** (self-signed HTTPS)
2. Validates DNS propagation for domain mode (querying authoritative nameservers)
3. Installs Docker if not present (Debian/Ubuntu, RHEL/AlmaLinux/Rocky/CentOS)
4. Clones the deployment repo, copies files to `/opt/osie`
5. Generates secrets and `.env`
6. Starts all services via `docker compose`

### CLI Options

| Option | Description |
|---|---|
| `--hostname DOMAIN` | Public hostname (skips interactive prompt, enables domain mode) |
| `--skip-dns-check` | Skip DNS verification |
| `--branch BRANCH` | Git branch to clone (default: `main`) |

### Examples

```bash
# Interactive
sudo bash install.sh

# Non-interactive with domain
sudo bash install.sh --hostname osie.example.com

# Non-interactive, skip DNS check
sudo bash install.sh --hostname osie.example.com --skip-dns-check

# Use a specific branch
sudo bash install.sh --branch feat/my-branch
```

### Re-running

The installer is idempotent. Re-running it will:
- Pull fresh compose files and config from git
- Preserve existing secrets (passwords, encryption key)
- Force-recreate all containers

### File Layout (`/opt/osie`)

```
/opt/osie/
  docker-compose.yml          # Caddy + base services
  docker-compose.base.yml     # MongoDB, RabbitMQ, API, UI, Admin
  .env                        # Generated secrets and config
  caddy/Caddyfile             # Reverse proxy config
  config/application.yml      # OSIE API Spring config
```

### Useful Commands

```bash
cd /opt/osie

# Logs
docker compose logs -f

# Status
docker compose ps

# Stop
docker compose down

# Restart
docker compose up -d --force-recreate
```

## Local Development

Copy `.env.example` to `.env`, set `PUBLIC_HOSTNAME=localhost`, then:

```bash
docker compose -f docker-compose.caddy.prod.yml up -d
```

Navigate to `https://localhost` (accept the self-signed certificate warning).
