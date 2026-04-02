#!/bin/bash
# ==============================================================================
# hook_start.sh — STRATÉGIE DE MESURE HYBRIDE (RUNNER + DOCKER)
# Version : 4.0 - Multi-Instance Safe
# ==============================================================================
set +e
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


# --- 3. Purge des anciens restes (Anti-Conflit) ---
sudo pkill -f "ecofloc" > /dev/null 2>&1 || true
sudo rm -f "$RAW_DIR"/*.csv > /dev/null 2>&1 || true


# --- 3. Diagnostics Système ---
echo "🔍 [DIAGNOSTIC] Vérification des prérequis système..."
if lsmod | grep -q "msr"; then
    echo "  [OK] Module MSR (Intel RAPL) déjà chargé."
else
    sudo modprobe msr 2>/dev/null && echo "  [OK] Module MSR chargé avec succès." || echo "  [!!] Erreur : Impossible de charger MSR."
fi
set -e
# --- 4. Timer et Fichiers de Tracking ---
TS_FILE="/tmp/ecofloc_${PIPELINE_ID}_${JOB_NAME}_start.ts"
PID_FILE="/tmp/ecofloc_${PIPELINE_ID}_${JOB_NAME}.pids"
CONTAINER_PID_FILE="/tmp/ecofloc_${PIPELINE_ID}_${JOB_NAME}.cid"
echo $(date +%s) > "$TS_FILE"
> "$PID_FILE"
echo "⏱️  Timestamp enregistré dans $TS_FILE"

# --- 5. Phase 1 : Lancement Sonde Runner (Obligatoire) ---
echo "📡 [PHASE 1] Activation des sondes sur le Runner (-n Runner.Worker)..."
for conf in cpu ram sd nic gpu; do
   nohup sudo ecofloc --$conf -n "Runner.Worker" -i 1000 -t 3600 -f "$RAW_DIR/" > /dev/null 2>&1 &
    echo $! >> "$PID_FILE"
    echo "  [+] Sonde $conf (Runner) lancée (PID EcoFloc: $!)"
done

## --- 6. Phase 2 : Détection Docker (Version Stabilisée) ---
CD_PATTERN="docker|push|deploy|publish|integration|container|burnout|docker-build|k8s"

if [[ "$JOB_NAME" =~ $CD_PATTERN ]]; then
    echo "🏗️  [ANALYSE] Job Docker détecté. Surveillance active..."

    (
        # On tente de détecter le conteneur pendant 15 secondes
        for i in {1..15}; do
            # 1. Recherche du CID (Buildkit ou standard)
            CID=$(docker ps --format '{{.Names}}' | grep "buildkit" | head -n 1)
            [ -z "$CID" ] && CID=$(docker ps -lq --filter "status=running")

            if [ -n "$CID" ]; then
                D_PID=$(docker inspect -f '{{.State.Pid}}' "$CID" 2>/dev/null)
                
                # Vérification de l'activité (Enfants ou Type de Job)
                CHILD_COUNT=$(pgrep -P "$D_PID" | wc -l)
                
                if [ "$CHILD_COUNT" -gt 0 ] || [[ "$JOB_NAME" == *"test"* ]]; then
                    echo "🎯 [FOUND] Cible détectée : $CID (PID: $D_PID). Lancement des sondes..."
                    echo "$D_PID" > "$CONTAINER_PID_FILE"
                    for conf in cpu ram sd nic gpu; do
                        nohup sudo ecofloc --$conf -p "$D_PID" -i 1000 -t 3600 -f "$RAW_DIR/" > /dev/null 2>&1 &
                        echo $! >> "$PID_FILE"
                        disown
                    done
                    break 2 # ON SORT DE LA BOUCLE ET DU PROCESSUS DE RECHERCHE
                else
                    echo "⚠️  [GHOST] PID $D_PID inactif, attente d'événements Docker..."
                    # On attend un signal réel d'activité
                    timeout 60s docker events --filter 'event=exec_create' --filter 'event=start' | while read -r line; do
                         NEW_CID=$(echo "$line" | awk '{print $4}')
                         NEW_PID=$(docker inspect -f '{{.State.Pid}}' "$NEW_CID" 2>/dev/null)
                         if [ -n "$NEW_PID" ] && [ "$NEW_PID" != "0" ]; then
                             echo "$NEW_PID" > "$CONTAINER_PID_FILE"
                             for conf in cpu ram sd nic gpu; do
                                 nohup sudo ecofloc --$conf -p "$NEW_PID" -i 1000 -t 3600 -f "$RAW_DIR/" > /dev/null 2>&1 &
                                 echo $! >> "$PID_FILE"
                                 disown
                             done
                             exit 0 # On a fini, on tue le sous-shell de recherche
                         fi
                    done
                    break # On sort de la boucle for si on est entré dans les events
                fi
            fi
            sleep 1 # <--- CRUCIAL : On attend 1s entre chaque vérification
        done
    ) & 
    disown
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
  
 sleep 2
  echo "📊 Processus EcoFloc actifs :"
  pgrep -af "ecofloc" | grep "$RAW_DIR"
) & 
disown

echo "✅ [SUCCESS] Setup terminé. $JOB_NAME est sous haute surveillance."
exit 0