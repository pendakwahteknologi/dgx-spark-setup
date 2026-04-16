# DGX Spark Setup

Reproducible setup for NVIDIA DGX Spark machines (DIGITS GB10, MSI EdgeXpert, etc.).

This repo contains everything needed to configure a fresh DGX Spark as an AI workstation with a web dashboard, reverse proxy, and managed services.

## What gets installed

| Service | Description | Local Port |
|---|---|---|
| **Nginx** | Reverse proxy, ties all services under one domain | `:8080` |
| **Ollama** | Local LLM inference API | `:11434` |
| **ComfyUI** | Image/video generation with Stable Diffusion | `:8188` |
| **code-server** | VS Code in the browser | `:8443` |
| **{{HOSTNAME}}-manager** | System stats + service management API (FastAPI) | `:9000` |
| **Cloudflare Tunnel** | Expose services publicly via your domain | - |
| **Tailscale** | Mesh VPN for private access between devices | - |

## Nginx routes

All services are exposed under a single domain via nginx on port `8080`:

```
/              -> Static dashboard        (/var/www/<HOSTNAME>-main/index.html)
/{{HOSTNAME}}-api/  -> System Manager API      (localhost:9000/api/)
/code/         -> code-server             (localhost:8443)
/ollama/       -> Ollama API              (localhost:11434)
/comfyui/      -> ComfyUI                 (localhost:8188)
/benchmarks/*  -> Static benchmark reports
```

The Cloudflare tunnel points `<HOSTNAME>.<DOMAIN>` to `localhost:8080`.

## Setup instructions (for Claude on the new machine)

### Prerequisites

The machine should be a fresh DGX Spark (Ubuntu 24.04, aarch64) with NVIDIA drivers already installed. You need:

1. A **hostname** for the machine (e.g., `spark1`, `edge1`)
2. A **domain** you control (e.g., `pendakwah.tech`)
3. A **Cloudflare tunnel token** (create one at https://one.dash.cloudflare.com -> Networks -> Tunnels)
4. A **Tailscale auth key** (from https://login.tailscale.com/admin/settings/keys)

### Post-setup: register CLI tools

After the setup script completes, authenticate with GitHub and Hugging Face:

```bash
# GitHub — needed for git push, gh CLI, and private repos
gh auth login

# Hugging Face — needed for downloading gated models (Llama, Mistral, etc.)
pip install huggingface-hub
huggingface-cli login
```

### Step-by-step

```
# 1. Clone this repo
git clone https://github.com/<OWNER>/dgx-spark-setup.git
cd dgx-spark-setup

# 2. Run the setup script with your parameters
sudo ./setup.sh \
  --hostname spark1 \
  --domain pendakwah.tech \
  --cloudflare-token <YOUR_TUNNEL_TOKEN> \
  --tailscale-key <YOUR_TAILSCALE_KEY> \
  --user <USERNAME>
```

Or, tell Claude on the new machine:

> Set up this machine using the instructions in https://github.com/<OWNER>/dgx-spark-setup.
> The hostname is `spark1`, domain is `pendakwah.tech`.
> Here is the Cloudflare tunnel token: `...`
> Here is the Tailscale auth key: `...`

Claude will read this README, adapt all the template configs, and run the setup.

### Manual setup (if not using setup.sh)

Each config file in `configs/` uses placeholders that must be replaced:

| Placeholder | Example | Description |
|---|---|---|
| `{{HOSTNAME}}` | `spark1` | Machine hostname |
| `{{DOMAIN}}` | `pendakwah.tech` | Your domain |
| `{{USER}}` | `atom` | Primary non-root user |
| `{{CLOUDFLARE_TOKEN}}` | - | Tunnel token from Cloudflare dashboard |

Follow the numbered steps in `setup.sh` to understand what each section does.

## File layout

```
configs/
  nginx/site.conf           # Nginx reverse proxy config
  cloudflared/config.yml     # Cloudflare tunnel config
  ollama/override.conf       # Ollama systemd overrides (GPU tuning)
  systemd/comfyui.service    # ComfyUI systemd unit
  systemd/atom-manager.service # System manager API unit (installs as {{HOSTNAME}}-manager)
  code-server/config.yaml    # code-server config
atom-manager/
  app.py                     # FastAPI system manager (stats + service control)
  requirements.txt           # Python dependencies
dashboard/
  index.html                 # Web dashboard (templatized)
setup.sh                     # Automated setup script
```

## Hardware reference

Tested on:
- **NVIDIA Project DIGITS** (GB10, Cortex-X925, 128GB unified, 3.7TB NVMe)
- Should work on any DGX Spark OEM (MSI EdgeXpert, etc.) running Ubuntu 24.04 aarch64

## Notes

- The dashboard fetches stats from the `{{HOSTNAME}}-manager` API
- Ollama is tuned for GB10's 128GB unified memory (see `configs/ollama/override.conf`)
- ComfyUI runs in a conda env — the setup script creates it
- All services bind to `127.0.0.1` — only nginx is exposed
