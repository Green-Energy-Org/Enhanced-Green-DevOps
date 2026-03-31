#!/bin/bash
# ==============================================================================
# hook_start.sh — VERSION ÉVÉNEMENTIELLE UNIVERSELLE (SANS ECOFLOC)
# ==============================================================================

exec >> /tmp/runner_hooks.log 2>&1

PIPELINE_ID="$GITHUB_RUN_ID"
JOB_NAME=$(echo "$GITHUB_JOB" | tr ' ' '_')

echo "------------------------------------------------------------------------"
echo "🌿 [GREEN-CHECK] Début du job : $JOB_NAME"
echo "------------------------------------------------------------------------"

(
    echo "🕵️ [EVENT-WATCHER] En attente passive de démarrage de conteneur..."
    
    # On écoute les événements sans formatage complexe (format texte brut par défaut)
    # On filtre sur 'container' et 'start'
    # La sortie typique est : 2026-03-31T... container start b57708767196... (image=python:3.9-slim, name=...)
    
    timeout 600s docker events --filter 'type=container' --filter 'event=start' | while read -r line; do
        
        # On extrait le 4ème champ qui est l'ID du conteneur dans le log standard de Docker
        CID=$(echo "$line" | awk '{print $4}')
        
        if [ -n "$CID" ]; then
            # On récupère le PID sur l'hôte
            D_PID=$(docker inspect -f '{{.State.Pid}}' "$CID" 2>/dev/null)
            
            if [ -n "$D_PID" ] && [ "$D_PID" -gt 0 ]; then
                echo "🎯 [EVENT-BINGO] Signal intercepté !"
                echo "🆔 CID : ${CID:0:12}"
                echo "🆔 PID Hôte : $D_PID"
                
                # Vérification du processus
                PROC_NAME=$(ps -p "$D_PID" -o comm=)
                echo "📊 Processus rattaché : $PROC_NAME"
                
                # On arrête le watcher dès qu'on a capturé le conteneur principal
                pkill -P $$ docker
                break
            fi
        fi
    done
    echo "🏁 [WATCHER] Fin de la surveillance."
) &

echo "✅ [SUCCESS] Watcher Universel activé."
exit 0