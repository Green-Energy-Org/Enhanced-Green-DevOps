#!/bin/bash
# ==============================================================================
# hook_start.sh — MODE CAPTURE : Vérification du Timing Docker
# ==============================================================================

exec >> /tmp/runner_hooks.log 2>&1

PIPELINE_ID="$GITHUB_RUN_ID"
JOB_NAME=$(echo "$GITHUB_JOB" | tr ' ' '_')

echo "------------------------------------------------------------------------"
echo "🔍 [CHECK] Début du job : $JOB_NAME"
echo "------------------------------------------------------------------------"

# On lance le Watcher en arrière-plan pour ne pas bloquer le runner
(
    echo "🕵️ [WATCHER] Je commence à surveiller le moteur Docker..."
    
    # On boucle 30 fois (toutes les 2 secondes) pour être très réactif
    for i in {1..30}; do
        # 1. Tentative de détection du conteneur
        CID=$(docker ps -q --filter "ancestor=moby/buildkit" | head -n 1)
        [ -z "$CID" ] && CID=$(docker ps -lq)

        if [ -n "$CID" ]; then
            # 2. On récupère le PID dès que le conteneur existe
            D_PID=$(docker inspect -f '{{.State.Pid}}' "$CID" 2>/dev/null)
            
            if [ -n "$D_PID" ] && [ "$D_PID" -gt 0 ]; then
                echo "🎯 [BINGO] Conteneur trouvé à l'itération $i !"
                echo "🆔 CID : $CID"
                echo "🆔 PID Hôte : $D_PID"
                
                # Ici, on pourrait lancer EcoFloc, mais pour l'instant on fait juste un snapshot
                echo "📊 État CPU du PID $D_PID à cet instant :"
                ps -p "$D_PID" -o %cpu,%mem,cmd | sed 's/^/  /'
                
                break # On a réussi la capture, on sort
            fi
        fi
        
        # On logue un petit point pour dire qu'on cherche encore (toutes les 2s)
        echo -n "." 
        sleep 2
    done
    
    [ $i -eq 30 ] && echo -e "\n❌ [TIMEOUT] Le conteneur n'est jamais apparu."
) &

echo "✅ [SUCCESS] Watcher de capture activé. GitHub Actions peut continuer."
exit 0
