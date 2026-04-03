#!/bin/bash
# ==============================================================================
# hook_stop.sh — Calculateur d'Énergie Triple-Niveau (Composant, Job, Pipeline)
# ==============================================================================
set +e
exec >> /tmp/runner_hooks.log 2>&1

# --- 1. Contexte ---
REPO_NAME=$(echo "$GITHUB_REPOSITORY" | tr '[:upper:]' '[:lower:]' | tr '/' '_' | tr '-' '_')
COMMIT_ID="${GITHUB_SHA:0:7}"
BRANCH_NAME="$GITHUB_REF_NAME"
PIPELINE_ID="$GITHUB_RUN_ID"
JOB_NAME=$(echo "$GITHUB_JOB" | tr ' ' '_')

# Variables YAML
P_CAT="${PROJECT_CATEGORY:-IA}"
P_NAME="${PROJECT_NAME:-Chatbot-LLM}"
[ "$GITHUB_EVENT_NAME" = "workflow_dispatch" ] && TRIGGER="manual" || TRIGGER="auto"

# --- 2. Chemins ---
BASE_DIR="/home/medyassine/GreenDevOps/jobs_energy/$REPO_NAME"
RAW_DIR="$BASE_DIR/raw_samples"
JOB_METRICS_DIR="$BASE_DIR/granularity"
ML_DIR="$BASE_DIR/global_history"
PIPELINE_DIR="$BASE_DIR/pipelines_total"
mkdir -p "$JOB_METRICS_DIR" "$ML_DIR" "$PIPELINE_DIR"

PID_FILE="/tmp/ecofloc_${PIPELINE_ID}_${JOB_NAME}.pids"
START_TS_FILE="/tmp/ecofloc_${PIPELINE_ID}_${JOB_NAME}_start.ts"
CONTAINER_PID_FILE="/tmp/ecofloc_${PIPELINE_ID}_${JOB_NAME}.cid"
# --- 3. Fonctions de Calcul ---
fadd() { echo "scale=6; ${1:-0} + ${2:-0}" | bc 2>/dev/null || echo "0"; }

# --- 3. Fonctions de Calcul (Version Unifiée dockerd) ---
parse_ecofloc() {
    local mod=$1
    local total_j=0
    local total_w=0
    local total_n=0

    # 1. Récupérer le fichier du RUNNER
    local runner_csv=$(sudo ls "${RAW_DIR}/ECOFLOC_${mod}_COMM_Runner.Worker"*.csv 2>/dev/null | head -1)
    if [ -n "$runner_csv" ] && [ -s "$runner_csv" ]; then
        read r_w r_j r_n <<< $(sudo awk -F',' '/^[0-9]/ { sum_p+=$3; sum_e+=$4; n++ } END { if (n>0) printf "%.4f %.4f %d", sum_p/n, sum_e, n; else printf "0 0 0"; }' "$runner_csv")
        total_j=$(echo "$total_j + $r_j" | bc)
        total_w=$(echo "$total_w + $r_w" | bc)
        total_n=$((total_n + r_n))
    fi

    # 2. Récupérer le fichier de DOCKER (Nouvelle méthode : COMM_dockerd)
    # EcoFloc génère ce nom via l'option -n "dockerd"
    local docker_csv=$(sudo ls "${RAW_DIR}/ECOFLOC_${mod}_COMM_dockerd"*.csv 2>/dev/null | head -1)
    
    if [ -n "$docker_csv" ] && [ -s "$docker_csv" ]; then
        read d_w d_j d_n <<< $(sudo awk -F',' '/^[0-9]/ { sum_p+=$3; sum_e+=$4; n++ } END { if (n>0) printf "%.4f %.4f %d", sum_p/n, sum_e, n; else printf "0 0 0"; }' "$docker_csv")
        total_j=$(echo "scale=4; $total_j + $d_j" | bc)
        total_w=$(echo "scale=4; $total_w + $d_w" | bc)
        total_n=$((total_n + d_n))
        echo "  [DEBUG] Fusion dockerd détectée pour $mod : +$d_j Joules" >&2
    fi

    printf "%.4f %.4f %d" "$total_w" "$total_j" "$total_n"
}

# --- 4. Calcul de l'énergie du Job ---
if [ -f "$PID_FILE" ]; then
    echo "🛑 Arrêt des sondes..."
    while read pid; do sudo kill -2 "$pid" 2>/dev/null; done < "$PID_FILE"
    sleep 3 

    # --- CALCUL ET AFFICHAGE DÉTAILLÉ ---
    echo "======================================================="
    echo "📊 RAPPORT ÉNERGÉTIQUE DÉTAILLÉ (PROD vs DOCKER)"
    echo "======================================================="

    for mod in CPU RAM SD NIC GPU; do
        # Mesure Runner
        R_FILE=$(sudo ls ${RAW_DIR}/ECOFLOC_${mod}_COMM_Runner.Worker*.csv 2>/dev/null | head -1)
        R_J=$(sudo awk -F',' '/^[0-9]/ {s+=$4} END {printf "%.2f", s+0}' "$R_FILE" 2>/dev/null || echo "0.00")

        # Mesure Docker (Correction ici : on cherche COMM_dockerd)
        D_FILE=$(sudo ls ${RAW_DIR}/ECOFLOC_${mod}_COMM_dockerd*.csv 2>/dev/null | head -1)
        D_J=$(sudo awk -F',' '/^[0-9]/ {s+=$4} END {printf "%.2f", s+0}' "$D_FILE" 2>/dev/null || echo "0.00")

        TOTAL_MOD=$(echo "$R_J + $D_J" | bc)
        echo "🔹 $mod :"
        echo "   [Host Runner] : $R_J J"
        echo "   [Docker/App ] : $D_J J"
        echo "   => Total $mod : $TOTAL_MOD J"
    done
    echo "======================================================="
# --- 5. Agrégation pour les Bases de Données ---
    read cpu_w cpu_j cpu_n <<< $(parse_ecofloc "CPU")
    read ram_w ram_j ram_n <<< $(parse_ecofloc "RAM")
    read sd_w  sd_j  sd_n  <<< $(parse_ecofloc "SD")
    read nic_w nic_j nic_n <<< $(parse_ecofloc "NIC")
    read gpu_w gpu_j gpu_n <<< $(parse_ecofloc "GPU")

    JOB_TOTAL_J=$(fadd $cpu_j $(fadd $ram_j $(fadd $sd_j $(fadd $nic_j $gpu_j))))

    # --- NIVEAU 1 : GRANULARITÉ ---
    G_HEADER="date,pipeline_id,commit_id,repo_name,project_name,category,branch,trigger,duration_s,avg_power_w,total_energy_j,samples"
    for entry in "cpu:$cpu_w:$cpu_j:$cpu_n" "ram:$ram_w:$ram_j:$ram_n" "sd:$sd_w:$sd_j:$sd_n" "nic:$nic_w:$nic_j:$nic_n" "gpu:$gpu_w:$gpu_j:$gpu_n"; do
        IFS=: read mod pw ej sn <<< "$entry"
        FILE="${JOB_METRICS_DIR}/history_${JOB_NAME}_${mod}.csv"
        [ ! -f "$FILE" ] && echo "$G_HEADER" > "$FILE"
        echo "$TS_LABEL,$PIPELINE_ID,$COMMIT_ID,$REPO_NAME,$P_NAME,$P_CAT,$BRANCH_NAME,$TRIGGER,$DURATION,$pw,$ej,$sn" >> "$FILE"
    done

    # --- NIVEAU 2 : MASTER DB (JOBS) ---
    ML_HEADER="date,pipeline_id,commit_id,repo_name,project_name,category,branch,trigger,job_name,duration_s,cpu_j,ram_j,sd_j,nic_j,gpu_j,total_energy_j"
    ML_FILE="${ML_DIR}/master_energy_database.csv"
    [ ! -f "$ML_FILE" ] && echo "$ML_HEADER" > "$ML_FILE"
    echo "$TS_LABEL,$PIPELINE_ID,$COMMIT_ID,$REPO_NAME,$P_NAME,$P_CAT,$BRANCH_NAME,$TRIGGER,$JOB_NAME,$DURATION,$cpu_j,$ram_j,$sd_j,$nic_j,$gpu_j,$JOB_TOTAL_J" >> "$ML_FILE"

   # --- NIVEAU 3 : PIPELINE TOTAL (MODE UNIQUE) ---
    ACC_FILE="/tmp/pipeline_${PIPELINE_ID}_sum.tmp"
    [ ! -f "$ACC_FILE" ] && echo "0" > "$ACC_FILE"
    CURRENT_SUM=$(cat "$ACC_FILE")
    NEW_SUM=$(fadd $CURRENT_SUM $JOB_TOTAL_J)
    echo "$NEW_SUM" > "$ACC_FILE"

    PIPE_FILE="${PIPELINE_DIR}/pipeline_summary.csv"
    PIPE_HEADER="date,pipeline_id,commit_id,repo_name,project_name,category,branch,trigger,total_pipeline_energy_j"
    
    # Créer le fichier avec header s'il n'existe pas
    [ ! -f "$PIPE_FILE" ] && echo "$PIPE_HEADER" > "$PIPE_FILE"

    # LOGIQUE D'UPDATE :
    # Si le pipeline_id existe déjà, on remplace la ligne. Sinon, on l'ajoute.
    LINE_DATA="$TS_LABEL,$PIPELINE_ID,$COMMIT_ID,$REPO_NAME,$P_NAME,$P_CAT,$BRANCH_NAME,$TRIGGER,$NEW_SUM"

    # 1. Si le fichier n'existe pas, on l'initialise avec l'entête
    if [ ! -f "$PIPE_FILE" ]; then
        echo "$PIPE_HEADER" > "$PIPE_FILE"
    fi

    # 2. On crée un fichier temporaire qui contient TOUT sauf la ligne de ce pipeline
    # On utilise -w pour chercher l'ID exact (évite de confondre l'ID 123 avec 1234)
    grep -v -w "$PIPELINE_ID" "$PIPE_FILE" > "${PIPE_FILE}.tmp"

    # 3. On ajoute la ligne avec la valeur d'énergie mise à jour
    echo "$LINE_DATA" >> "${PIPE_FILE}.tmp"

    # 4. On remplace l'ancien fichier par le nouveau
    mv "${PIPE_FILE}.tmp" "$PIPE_FILE"

    echo "✅ [SUCCESS] Pipeline $PIPELINE_ID mis à jour : $NEW_SUM J"

    echo "🏁 [STOP] Job $JOB_NAME terminé. Total Pipeline ($PIPELINE_ID) mis à jour : $NEW_SUM J"
    # On ajoute une ligne à chaque job : la dernière ligne pour un pipeline_id sera son total final
    #echo "$TS_LABEL,$PIPELINE_ID,$COMMIT_ID,$REPO_NAME,$P_NAME,$P_CAT,$BRANCH_NAME,$TRIGGER,$NEW_SUM" >> "$PIPE_FILE"

    echo "🏁 [STOP] Job $JOB_NAME : $JOB_TOTAL_J J | Total Pipeline provisoire : $NEW_SUM J"

    sudo rm -f "$PID_FILE" "$START_TS_FILE" "$CONTAINER_PID_FILE" "${RAW_DIR}/ECOFLOC_"*.csv
fi