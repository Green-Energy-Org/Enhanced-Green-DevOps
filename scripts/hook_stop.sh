#!/bin/bash
# ==============================================================================
# hook_stop.sh — Lancé automatiquement par le Runner à la fin de chaque job
# ==============================================================================
exec >> /tmp/runner_hooks.log 2>&1
echo "---------------------------------------------------"
echo "🏁 [STOP]  Job: $GITHUB_JOB | Durée: $DURATION s"
echo "📊 Énergie totale calculée: $TOTAL_J Joules"
echo "==================================================="
echo "" 

# Récupérer le nom du repo
REPO_NAME=$(echo "$GITHUB_REPOSITORY" | tr '[:upper:]' '[:lower:]' | tr '/' '_')

# le chemin de stockage avec le repo
METRICS_DIR="/home/medyassine/GreenDevOps/jobs_energy/$REPO_NAME"
mkdir -p "$METRICS_DIR"

JOB_NAME=$(echo "$GITHUB_JOB" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
RUN_ID="$GITHUB_RUN_ID"
PID_FILE="/tmp/ecofloc_${RUN_ID}_${JOB_NAME}.pids"
START_TS_FILE="/tmp/ecofloc_${RUN_ID}_${JOB_NAME}_start.ts"

# --- Fonctions Utilitaires ---
fadd() { echo "scale=6; ${1:-0} + ${2:-0}" | bc 2>/dev/null || echo "0"; }
fdiv() { [ "${2:-1}" = "0" ] && echo "0" || echo "scale=4; ${1:-0} / ${2:-1}" | bc 2>/dev/null || echo "0"; }

parse_ecofloc_comm() {
    local mod=$1
    local csv=$(sudo ls "${METRICS_DIR}/ECOFLOC_${mod}_COMM_Runner.Worker"*.csv 2>/dev/null | head -1)
    if [ -n "$csv" ] && [ -s "$csv" ]; then
        sudo awk -F',' -v f="$csv" '/^[0-9]/ { sum_p+=$3; sum_e+=$4; n++ } END { if (n>0) printf "%.4f %.4f %d %s", sum_p/n, sum_e, n, f; else printf "0.0000 0.0000 0 none" }' "$csv"
    else
        echo "0.0000 0.0000 0 none"
    fi
}

# --- Logique Principale ---
if [ -f "$PID_FILE" ]; then
    # 1. Arrêter les sondes proprement (SIGINT pour flush le CSV)
    while read pid; do sudo kill -2 "$pid" 2>/dev/null; done < "$PID_FILE"
    sleep 2 # Temps de flush

    # 2. Calculer la durée réelle
    START_TS=$(cat "$START_TS_FILE")
    END_TS=$(date +%s)
    DURATION=$((END_TS - START_TS))
    # si le job dure 0s, on arrondit à 1s pour éviter les divisions par zéro
    [ $DURATION -lt 1 ] && DURATION=1

    echo "⏱️ [Run #$GITHUB_RUN_ID] Job: $GITHUB_JOB | Durée: $DURATION s"

    # 3. Parser les composants
    read cpu_w cpu_j cpu_n cpu_csv <<< $(parse_ecofloc_comm "CPU")
    read ram_w ram_j ram_n ram_csv <<< $(parse_ecofloc_comm "RAM")
    read sd_w  sd_j  sd_n  sd_csv  <<< $(parse_ecofloc_comm "SD")
    read nic_w nic_j nic_n nic_csv <<< $(parse_ecofloc_comm "NIC")
    read gpu_w gpu_j gpu_n gpu_csv <<< $(parse_ecofloc_comm "GPU")

    # 4. Calcul du Total J (Somme de tous les composants)
    TOTAL_J=$(fadd $cpu_j $(fadd $ram_j $(fadd $sd_j $(fadd $nic_j $gpu_j))))

    # 5. Archive par Job (CSV Individuels)
    TS_LABEL=$(date '+%Y-%m-%d %H:%M:%S')
    HEADER="date,run_id,job_name,duration_s,avg_power_w,total_energy_j,samples"
    
    for entry in "cpu:$cpu_w:$cpu_j:$cpu_n" "ram:$ram_w:$ram_j:$ram_n" "sd:$sd_w:$sd_j:$sd_n" "nic:$nic_w:$nic_j:$nic_n" "gpu:$gpu_w:$gpu_j:$gpu_n"; do
        IFS=: read mod pw ej sn <<< "$entry"
        FILE="${METRICS_DIR}/job_${RUN_ID}_${JOB_NAME}_${mod}.csv"
        [ ! -f "$FILE" ] && echo "$HEADER" > "$FILE"
        echo "$TS_LABEL,$RUN_ID,$JOB_NAME,$DURATION,$pw,$ej,$sn" >> "$FILE"
    done

    # 6. Archive Pipeline Total (Résumé)
    TOTAL_CSV="${METRICS_DIR}/energy_pipeline_total.csv"
    [ ! -f "$TOTAL_CSV" ] && echo "date,run_id,job_name,duration_s,cpu_j,ram_j,sd_j,nic_j,gpu_j,total_j" > "$TOTAL_CSV"
    echo "$TS_LABEL,$RUN_ID,$JOB_NAME,$DURATION,$cpu_j,$ram_j,$sd_j,$nic_j,$gpu_j,$TOTAL_J" >> "$TOTAL_CSV"

    # Nettoyage des fichiers temporaires
    sudo rm -f "$PID_FILE" "$START_TS_FILE" "$cpu_csv" "$ram_csv" "$sd_csv" "$nic_csv" "$gpu_csv"
fi

exit 0
