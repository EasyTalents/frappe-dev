# AGENTS.md — Orchestration Codex

## Goals
- Build fiable, logs lisibles, zéro secret en clair.
- Qualité: lint → typecheck → test → build (quand dispo).

## Commands
lint: |
  if [ -f package.json ]; then npx -y eslint . || true; fi
  if [ -f requirements.txt ] || [ -f pyproject.toml ]; then python -m pyflakes . || true; fi
typecheck: |
  if command -v pyright >/dev/null 2>&1; then pyright || true; fi
  if [ -f tsconfig.json ]; then npx -y tsc -p tsconfig.json --noEmit || true; fi
test: |
  if [ -f package.json ]; then npm test --silent || echo "No JS tests"; fi
  if [ -d tests ]; then pytest -q || echo "No Py tests"; fi
build: |
  if [ -f package.json ]; then npm run build || true; fi

## Policies
- Ne jamais committer de secrets; lire depuis ENV.
- Afficher chaque commande avant exécution; journaliser en /tmp/agent.log.

## PR Readiness Checklist
- lint/typecheck/test/build OK (ou justifiés s’ils n’existent pas).
- Diff propre + plan de test succinct.
