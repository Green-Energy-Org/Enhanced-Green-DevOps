#!/bin/bash
# ==============================================================================
# hook_start.sh — Lancé automatiquement par le Runner au début de chaque job
# ==============================================================================

exec >> /tmp/runner_hooks.log 2>&1
echo "🚀 [START] Job: $GITHUB_JOB | Run: $GITHUB_RUN_ID"
echo "---------------------------------------------------"

# Récupérer le nom du repo
REPO_NAME=$(echo "$GITHUB_REPOSITORY" | tr '[:upper:]' '[:lower:]' | tr '/' '_')

# le chemin de stockage avec le repo
METRICS_DIR="/home/medyassine/GreenDevOps/jobs_energy/$REPO_NAME"
mkdir -p "$METRICS_DIR"
sudo modprobe msr 2>/dev/null

# Variables fournies par GitHub Runner
JOB_NAME=$(echo "$GITHUB_JOB" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
RUN_ID="$GITHUB_RUN_ID"

# 1. Sauvegarder le timestamp de début
echo $(date +%s) > "/tmp/ecofloc_${RUN_ID}_${JOB_NAME}_start.ts"

# 2. Lancer les sondes EcoFloc en arrière-plan
# On cible le nom du processus "Runner.Worker" pour tout capturer
PID_FILE="/tmp/ecofloc_${RUN_ID}_${JOB_NAME}.pids"
> "$PID_FILE"

for conf in cpu ram sd nic gpu; do
    # -i 1000ms, -t 3600s de timeout de sécurité
    sudo ecofloc --$conf -n "Runner.Worker" -i 1000 -t 3600 -f "$METRICS_DIR/" > /dev/null 2>&1 &
    echo $! >> "$PID_FILE"
done

# On lance un sous-interpréteur en arrière-plan qui attend que les steps commencent
(
  sleep 5 # On attend 5s pour que le premier step (souvent checkout) soit lancé
  echo "---------------------------------------------------"
  echo "📸 [SNAPSHOT] Arborescence des processus pour $GITHUB_JOB"
  # -a : affiche les arguments (ex: pytest)
  # -p : affiche les PIDs
  pstree -ap $(pgrep -f "Runner.Worker") 2>/dev/null
  echo "---------------------------------------------------"
) & 

exit 0