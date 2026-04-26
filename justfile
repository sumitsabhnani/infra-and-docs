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

pull-sweeper:
    @echo "⬇️ Pulling Price Sweeper..."
    git -C ~/dhantera-app/price-sweeper pull

pull-infra:
    @echo "⬇️ Pulling Infra..."
    git -C ~/dhantera-app/infra-and-docs pull

# 3. Pull everything in sequence
pull-all: pull-infra pull-frontend pull-backend pull-sweeper
    @echo "✅ All repositories updated."

# 4. Master Deploy: Deploy everything, or pass a target to deploy a specific service
# Usage: `sys deploy` OR `sys deploy backend`
deploy target="":
    @echo "🚀 Deploying {{target}}..."
    docker compose up {{target}} --build -d

# 5. Start or update state without rebuilding images
# Usage: `sys start` OR `sys start dozzle`
start target="":
    @echo "▶️ Starting {{target}} (No Build)..."
    docker compose up {{target}} -d