# justfile

# 1. Provide a clean list of commands when you just type the alias
default:
    @just --list

# 2. Pull individual repositories
pull-frontend:
    @echo "⬇️ Pulling Frontend..."
    git -C ~/dhantera-app/portfolio-optimizer-frontend pull

pull-backend:
    @echo "⬇️ Pulling Backend..."
    git -C ~/dhantera-app/portfolio-optimizer-backend pull

pull-infra:
    @echo "⬇️ Pulling Infra..."
    git -C ~/dhantera-app/infra-and-docs pull

# 3. Pull everything in sequence
pull-all: pull-infra pull-frontend pull-backend
    @echo "✅ All repositories updated."

# 4. Master Deploy: Pull prebuilt GHCR images and recreate changed containers
# Usage: `sys deploy` OR `sys deploy backend`
deploy target="":
    @echo "🚀 Pulling & deploying {{target}}..."
    docker compose pull {{target}}
    @if [ -z "{{target}}" ]; then docker compose up -d --remove-orphans; else docker compose up -d {{target}}; fi

# 5. Start or update state without pulling new images
# Usage: `sys start` OR `sys start dozzle`
start target="":
    @echo "▶️ Starting {{target}} (No Pull)..."
    @if [ -z "{{target}}" ]; then docker compose up -d --remove-orphans; else docker compose up -d {{target}}; fi