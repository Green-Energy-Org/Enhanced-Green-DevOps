#!/bin/bash
# ==============================================================================
# hook_start.sh — STRATÉGIE DE MESURE HYBRIDE (RUNNER + DOCKER)
# Version : 4.0 - Multi-Instance Safe
# ==============================================================================

# Redirection totale vers les logs pour un debug complet
exec >> /tmp/runner_hooks.log 2>&1

# --- 1. Variables Dynamiques & Contextuelles ---
REPO_NAME=$(echo "$GITHUB_REPOSITORY" | tr '[:upper:]' '[:lower:]' | tr '/' '_' | tr '-' '_')
JOB_NAME=$(echo "$GITHUB_JOB" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
PIPELINE_ID="$GITHUB_RUN_ID"

echo "========================================================================"
echo "🚀 [START] INITIALISATION DU JOB : $GITHUB_JOB"
echo "📅 Date : $(date '+%Y-%m-%d %H:%M:%S')"
echo "🆔 Pipeline ID : $PIPELINE_ID | Repo : $REPO_NAME"
echo "========================================================================"

# --- 2. Arborescence de Stockage ---
BASE_DIR="/home/medyassine/GreenDevOps/jobs_energy/$REPO_NAME"
RAW_DIR="$BASE_DIR/raw_samples"
mkdir -p "$RAW_DIR"
echo "📂 Dossier de sortie : $RAW_DIR"

# --- 3. Diagnostics Système ---
echo "🔍 [DIAGNOSTIC] Vérification des prérequis système..."
if lsmod | grep -q "msr"; then
    echo "  [OK] Module MSR (Intel RAPL) déjà chargé."
else
    sudo modprobe msr 2>/dev/null && echo "  [OK] Module MSR chargé avec succès." || echo "  [!!] Erreur : Impossible de charger MSR."
fi

# --- 4. Timer et Fichiers de Tracking ---
TS_FILE="/tmp/ecofloc_${PIPELINE_ID}_${JOB_NAME}_start.ts"
PID_FILE="/tmp/ecofloc_${PIPELINE_ID}_${JOB_NAME}.pids"
echo $(date +%s) > "$TS_FILE"
> "$PID_FILE"
echo "⏱️  Timestamp enregistré dans $TS_FILE"

# --- 5. Phase 1 : Lancement Sonde Runner (Obligatoire) ---
echo "📡 [PHASE 1] Activation des sondes sur le Runner (-n Runner.Worker)..."
for conf in cpu ram sd nic gpu; do
    sudo ecofloc --$conf -n "Runner.Worker" -i 1000 -t 3600 -f "$RAW_DIR/" > /dev/null 2>&1 &
    echo $! >> "$PID_FILE"
    echo "  [+] Sonde $conf (Runner) lancée (PID EcoFloc: $!)"
done

# --- 6. Phase 2 : Détection Docker Dynamique (Conditionnelle) ---
CD_PATTERN="docker|push|deploy|publish|integration|container|burnout|docker-build|k8s"

if [[ "$JOB_NAME" =~ $CD_PATTERN ]]; then
    echo "🏗️  [ANALYSE] Job Docker détecté. Activation du Green-Watcher..."

    (
        # --- A. CHECK IMMÉDIAT (Pour Buildkit/Containers déjà actifs) ---
        CID=$(docker ps -q --filter "ancestor=moby/buildkit" | head -n 1)
        [ -z "$CID" ] && CID=$(docker ps -lq)

        if [ -n "$CID" ]; then
            D_PID=$(docker inspect -f '{{.State.Pid}}' "$CID" 2>/dev/null)
            if [ -n "$D_PID" ] && [ "$D_PID" -gt 0 ]; then
                echo "⚡ [FAST-FOUND] Conteneur déjà actif détecté (PID: $D_PID)."
                for conf in cpu ram sd nic gpu; do
                    sudo ecofloc --$conf -p "$D_PID" -i 1000 -t 3600 -f "$RAW_DIR/" > /dev/null 2>&1 &
                    echo $! >> "$PID_FILE"
                done
                exit 0 # Mission accomplie, on arrête le watcher ici
            fi
        fi

        # --- B. ÉCOUTE PASSIVE (Si rien n'est encore lancé) ---
        echo "🕵️ [EVENT-WATCHER] En attente passive du signal Docker 'start'..."
        timeout 600s docker events --filter 'type=container' --filter 'event=start' | while read -r line; do
            CID_EVENT=$(echo "$line" | awk '{print $4}')
            if [ -n "$CID_EVENT" ]; then
                D_PID_EVENT=$(docker inspect -f '{{.State.Pid}}' "$CID_EVENT" 2>/dev/null)
                if [ -n "$D_PID_EVENT" ] && [ "$D_PID_EVENT" -gt 0 ]; then
                    echo "🎯 [EVENT-BINGO] Conteneur détecté (PID: $D_PID_EVENT)."
                    for conf in cpu ram sd nic gpu; do
                        sudo ecofloc --$conf -p "$D_PID_EVENT" -i 1000 -t 3600 -f "$RAW_DIR/" > /dev/null 2>&1 &
                        echo $! >> "$PID_FILE"
                    done
                    pkill -P $$ docker
                    break
                fi
            fi
        done
        echo "🏁 [WATCHER] Fin de la session de surveillance."
    ) &
else
    echo "📝 [ANALYSE] Job standard ($JOB_NAME). Pas de mesure Docker requise."
fi

# --- 7. Snapshot Visuel & Audit (Arrière-plan) ---
(
  sleep 6
  echo ""
  echo "------------------------------------------------------------------------"
  echo "📸 [SNAPSHOT AUDIT] État des processus pour $JOB_NAME"
  
  W_PID=$(pgrep -f "Runner.Worker")
  if [ -n "$W_PID" ]; then
      echo "🌳 Arbre du Runner ($W_PID) :"
      pstree -ap "$W_PID" 2>/dev/null
  fi
  
  echo "📊 Instances EcoFloc en cours :"
  pgrep -af "ecofloc" | grep -v "grep"
  echo "------------------------------------------------------------------------"
  echo ""
) & 

echo "✅ [SUCCESS] Setup terminé. $JOB_NAME est sous haute surveillance."
exit 0