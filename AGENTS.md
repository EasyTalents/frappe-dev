# AGENTS.md — Orchestration Codex pour frappe-dev-main

## Goals
- Valider et corriger `.devcontainer/devcontainer.json`.
- Vérifier la santé du script `.devcontainer/scripts/init.sh` (lint, shellcheck, idempotence).
- S’assurer que `postCreateCommand` et `postAttachCommand` pointent bien vers `init.sh` et `bench start`.
- Produire un diff propre + note de release pour toute correction.

## Commands
lint: |
  # 1) JSON du devcontainer (sans commentaires)
  if command -v jq >/dev/null 2>&1; then jq . .devcontainer/devcontainer.json >/dev/null; fi || true
  # 2) Shell script init
  bash -n .devcontainer/scripts/init.sh
  if command -v shellcheck >/dev/null 2>&1; then shellcheck -S warning .devcontainer/scripts/init.sh || true; fi

validate: |
  # Sanity checks sur les clés importantes du devcontainer
  python3 - <<'PY'
import json,sys
with open('.devcontainer/devcontainer.json') as f:
    data=json.load(f)
assert 'name' in data and 'features' in data, "devcontainer.json incomplet"
assert 'postCreateCommand' in data, "postCreateCommand manquante"
print("OK: devcontainer keys")
PY

fix-devcontainer: |
  # Si invalide, réécrire un devcontainer.json canonique (voir modèle recommandé)
  echo "Utilise le modèle du README_Codex ou celui fourni par l'agent (diff ci-joint)."

## Policies
- Pas de secrets en clair. Uniquement via ENV/Secrets côté Codespaces/Coder (hors périmètre Codex).
- Toujours journaliser les commandes (echo avant exécution) et limiter les logs à l’essentiel.

## PR Readiness Checklist
- devcontainer.json valide (parse JSON OK), `postCreateCommand` appelle bien `.devcontainer/scripts/init.sh`.
- `init.sh` passe `bash -n`, `shellcheck` (warnings acceptables).
- README mis à jour si des commandes changent.
