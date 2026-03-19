#!/bin/bash
# ==============================================================================
# measure_ultimate.sh — Mesure énergétique CI/CD via EcoFloc + RAPL
# ==============================================================================
# Usage:
#   ./measure_ultimate.sh <job_name> "<commande>" [metrics_dir] [interval_ms]
#
# Exemples:
#   ./measure_ultimate.sh "test"        "pytest tests/ -v"
#   ./measure_ultimate.sh "cold_import" "python3 -c 'import fastapi; import groq'"
#   ./measure_ultimate.sh "lint"        "/home/medyassine/.local/bin/ruff check ."
#   ./measure_ultimate.sh "install"     "pip install -r requirements.txt --break-system-packages"
#
# Stratégie :
#   - RAPL  toujours actif (CPU + GPU intégré Intel) — wraps tout le job
#   - ECOFLOC en parallèle — CPU/RAM/SD/NIC par composant isolé au PID
#   - Si ecofloc retourne 0 mesures → résultat RAPL utilisé (job trop court)
#   - GPU NVIDIA via ecofloc si disponible, sinon Intel iGPU via RAPL uncore
#   - UNE SEULE exécution de la commande — pas de double run
# ==============================================================================

# --- ARGUMENTS ---
JOB_NAME=${1:-"default_job"}
COMMAND_TO_RUN=$(echo "$2" | sed 's/\bpython\b/python3/g')
METRICS_DIR=${3:-"/home/medyassine/GreenDevOps/energy_metrics"}
INTERVAL=${4:-500}   # ms — intervalle ecofloc

export PATH="$PATH:/home/medyassine/.local/bin"
mkdir -p "$METRICS_DIR"
sudo modprobe msr 2>/dev/null

# --- RAPL PATHS ---
RAPL_CPU="/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj"
RAPL_GPU="/sys/class/powercap/intel-rapl/intel-rapl:0/intel-rapl:0:1/energy_uj"  # Intel iGPU uncore
RAPL_RAM="/sys/class/powercap/intel-rapl/intel-rapl:0/intel-rapl:0:0/energy_uj"  # RAM uncore (si dispo)
RAPL_PKG="/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj"                 # Package total

# Vérifie quels domaines RAPL sont disponibles
RAPL_CPU_OK=false;  [ -f "$RAPL_CPU" ] && RAPL_CPU_OK=true
RAPL_GPU_OK=false;  [ -f "$RAPL_GPU" ] && RAPL_GPU_OK=true
RAPL_RAM_OK=false;  [ -f "$RAPL_RAM" ] && RAPL_RAM_OK=true

# Vérifie si GPU NVIDIA disponible
NVIDIA_OK=false
nvidia-smi > /dev/null 2>&1 && NVIDIA_OK=true

echo "=================================================="
echo " MESURE ÉNERGÉTIQUE ULTIME"
echo " Job      : $JOB_NAME"
echo " Command  : $COMMAND_TO_RUN"
echo " Interval : ${INTERVAL}ms"
echo "--------------------------------------------------"
echo " RAPL CPU : $RAPL_CPU_OK"
echo " RAPL GPU : $RAPL_GPU_OK (Intel iGPU)"
echo " RAPL RAM : $RAPL_RAM_OK"
echo " NVIDIA   : $NVIDIA_OK"
echo "=================================================="

# ==============================================================================
# PHASE 1 — Lecture RAPL AVANT
# ==============================================================================
$RAPL_CPU_OK && RAPL_CPU_BEFORE=$(sudo cat "$RAPL_CPU")
$RAPL_GPU_OK && RAPL_GPU_BEFORE=$(sudo cat "$RAPL_GPU")
$RAPL_RAM_OK && RAPL_RAM_BEFORE=$(sudo cat "$RAPL_RAM")
START_TS=$(date +%s)
TIME_START=$(date +%s%N)

# ==============================================================================
# PHASE 1.5 — Synchronise le chemin ecofloc avec METRICS_DIR
# ecofloc peut ignorer -f et utiliser son settings.conf interne
# On force les deux à pointer vers le même dossier
# ==============================================================================
echo "[*] Synchronisation chemin ecofloc → $METRICS_DIR/"
for conf in cpu ram sd nic gpu; do
    echo "$METRICS_DIR/" | sudo tee /opt/ecofloc/${conf}_settings.conf > /dev/null
done

# ==============================================================================
# PHASE 2 — Lancement job + sondes ecofloc EN PARALLÈLE (une seule exécution)
# ==============================================================================
eval "$COMMAND_TO_RUN" &
JOB_PID=$!

# Sondes ecofloc démarrent immédiatement sur le PID réel
sudo ecofloc --cpu -p $JOB_PID -i $INTERVAL -t -1 -f "$METRICS_DIR/" > /dev/null 2>&1 &
ECOFLOC_CPU_PID=$!
sudo ecofloc --ram -p $JOB_PID -i $INTERVAL -t -1 -f "$METRICS_DIR/" > /dev/null 2>&1 &
ECOFLOC_RAM_PID=$!
sudo ecofloc --sd  -p $JOB_PID -i $INTERVAL -t -1 -f "$METRICS_DIR/" > /dev/null 2>&1 &
ECOFLOC_SD_PID=$!
sudo ecofloc --nic -p $JOB_PID -i $INTERVAL -t -1 -f "$METRICS_DIR/" > /dev/null 2>&1 &
ECOFLOC_NIC_PID=$!

# GPU : ecofloc si NVIDIA, sinon RAPL iGPU seulement
if $NVIDIA_OK; then
    sudo ecofloc --gpu -p $JOB_PID -i $INTERVAL -t -1 -f "$METRICS_DIR/" > /dev/null 2>&1 &
    ECOFLOC_GPU_PID=$!
fi

# ==============================================================================
# PHASE 3 — Attente fin du job
# ==============================================================================
wait $JOB_PID
EXIT_CODE=$?

# Lecture RAPL APRÈS (immédiatement après la fin du job)
TIME_END=$(date +%s%N)
$RAPL_CPU_OK && RAPL_CPU_AFTER=$(sudo cat "$RAPL_CPU")
$RAPL_GPU_OK && RAPL_GPU_AFTER=$(sudo cat "$RAPL_GPU")
$RAPL_RAM_OK && RAPL_RAM_AFTER=$(sudo cat "$RAPL_RAM")

DURATION_MS=$(( (TIME_END - TIME_START) / 1000000 ))
DURATION_S=$(echo "scale=3; $DURATION_MS / 1000" | bc)

# Arrêt propre des sondes ecofloc
sleep 1
sudo pkill -2 -f "ecofloc --cpu" 2>/dev/null
sudo pkill -2 -f "ecofloc --ram" 2>/dev/null
sudo pkill -2 -f "ecofloc --sd"  2>/dev/null
sudo pkill -2 -f "ecofloc --nic" 2>/dev/null
$NVIDIA_OK && sudo pkill -2 -f "ecofloc --gpu" 2>/dev/null
sleep 2

# ==============================================================================
# PHASE 4 — Calcul RAPL
# ==============================================================================
calc_rapl() {
    local before=$1 after=$2
    echo "scale=6; ($after - $before) / 1000000" | bc
}

if $RAPL_CPU_OK; then
    RAPL_CPU_J=$(calc_rapl "$RAPL_CPU_BEFORE" "$RAPL_CPU_AFTER")
    RAPL_CPU_W=$(echo "scale=4; $RAPL_CPU_J / $DURATION_S" | bc 2>/dev/null || echo "0")
else
    RAPL_CPU_J="N/A"; RAPL_CPU_W="N/A"
fi

if $RAPL_GPU_OK; then
    RAPL_GPU_J=$(calc_rapl "$RAPL_GPU_BEFORE" "$RAPL_GPU_AFTER")
    RAPL_GPU_W=$(echo "scale=4; $RAPL_GPU_J / $DURATION_S" | bc 2>/dev/null || echo "0")
else
    RAPL_GPU_J="N/A"; RAPL_GPU_W="N/A"
fi

if $RAPL_RAM_OK; then
    RAPL_RAM_J=$(calc_rapl "$RAPL_RAM_BEFORE" "$RAPL_RAM_AFTER")
    RAPL_RAM_W=$(echo "scale=4; $RAPL_RAM_J / $DURATION_S" | bc 2>/dev/null || echo "0")
else
    RAPL_RAM_J="N/A"; RAPL_RAM_W="N/A"
fi

# ==============================================================================
# PHASE 5 — Parse résultats ecofloc
# ==============================================================================
parse_ecofloc() {
    local mod=$1
    local pid=$2
    local csv

    csv=$(sudo ls "${METRICS_DIR}/ECOFLOC_${mod}_PID_${pid}"*.csv 2>/dev/null | head -n 1)

    if [ -n "$csv" ] && [ -s "$csv" ]; then
        sudo awk -F',' '
            /^[0-9]/ { sum_p += $3; sum_e += $4; n++ }
            END {
                if (n > 0) printf "%.4f %.4f %d\n", sum_p/n, sum_e, n
                else        printf "NONE NONE 0\n"
            }
        ' "$csv"
        echo "$csv"  # retourne aussi le chemin pour nettoyage
    else
        echo "NONE NONE 0"
        echo ""
    fi
}

read ECO_CPU_W ECO_CPU_J ECO_CPU_N ECO_CPU_FILE <<< $(parse_ecofloc "CPU" "$JOB_PID")
read ECO_RAM_W ECO_RAM_J ECO_RAM_N ECO_RAM_FILE <<< $(parse_ecofloc "RAM" "$JOB_PID")
read ECO_SD_W  ECO_SD_J  ECO_SD_N  ECO_SD_FILE  <<< $(parse_ecofloc "SD"  "$JOB_PID")
read ECO_NIC_W ECO_NIC_J ECO_NIC_N ECO_NIC_FILE <<< $(parse_ecofloc "NIC" "$JOB_PID")
$NVIDIA_OK && read ECO_GPU_W ECO_GPU_J ECO_GPU_N ECO_GPU_FILE <<< $(parse_ecofloc "GPU" "$JOB_PID")

# Détermine la méthode utilisée selon les résultats ecofloc
if [ "$ECO_CPU_N" -gt 0 ] 2>/dev/null; then
    METHOD="ECOFLOC+RAPL"
else
    METHOD="RAPL_ONLY"
fi

# ==============================================================================
# PHASE 6 — Affichage
# ==============================================================================
[ $EXIT_CODE -ne 0 ] && echo -e "\n[!] Commande échouée (code: $EXIT_CODE)"

echo ""
echo "============================================================"
echo " RÉSULTATS : $JOB_NAME"
echo " Durée     : ${DURATION_MS}ms (${DURATION_S}s)"
echo " Méthode   : $METHOD"
echo "============================================================"

# Fonction d'affichage : préfère ecofloc si dispo, sinon RAPL
display_row() {
    local name=$1
    local eco_w=$2 eco_j=$3 eco_n=$4
    local rapl_w=$5 rapl_j=$6

    if [ "$eco_n" -gt 0 ] 2>/dev/null && [ "$eco_w" != "NONE" ]; then
        printf "%-8s | %-12s | %-14s | %-8s | %-10s\n" \
            "$name" "$eco_w" "$eco_j" "$eco_n" "ecofloc"
    elif [ "$rapl_w" != "N/A" ] && [ "$rapl_w" != "0" ]; then
        printf "%-8s | %-12s | %-14s | %-8s | %-10s\n" \
            "$name" "$rapl_w" "$rapl_j" "-" "RAPL"
    else
        printf "%-8s | %-12s | %-14s | %-8s | %-10s\n" \
            "$name" "N/A" "N/A" "0" "N/A"
    fi
}

printf "%-8s | %-12s | %-14s | %-8s | %-10s\n" \
    "COMPOS." "PUISS. (W)" "ÉNERGIE (J)" "MESURES" "MÉTHODE"
echo "------------------------------------------------------------"
display_row "CPU"  "$ECO_CPU_W" "$ECO_CPU_J" "$ECO_CPU_N" "$RAPL_CPU_W" "$RAPL_CPU_J"
display_row "RAM"  "$ECO_RAM_W" "$ECO_RAM_J" "$ECO_RAM_N" "$RAPL_RAM_W" "$RAPL_RAM_J"
display_row "SD"   "$ECO_SD_W"  "$ECO_SD_J"  "$ECO_SD_N"  "N/A"         "N/A"
display_row "NIC"  "$ECO_NIC_W" "$ECO_NIC_J" "$ECO_NIC_N" "N/A"         "N/A"

if $NVIDIA_OK; then
    display_row "GPU" "$ECO_GPU_W" "$ECO_GPU_J" "$ECO_GPU_N" "N/A" "N/A"
else
    display_row "GPU(iGPU)" "N/A" "$RAPL_GPU_J" "-" "$RAPL_GPU_W" "$RAPL_GPU_J"
fi
echo "------------------------------------------------------------"

# ==============================================================================
# PHASE 7 — Archivage CSV
# ==============================================================================
archive_row() {
    local mod=$1 power=$2 energy=$3 count=$4 method=$5 temp_file=$6
    local final_csv="${METRICS_DIR}/${JOB_NAME}_${mod,,}.csv"

    [ "$power" = "NONE" ] && power="0.0000"
    [ "$energy" = "NONE" ] && energy="0.0000"

    if [ ! -f "$final_csv" ]; then
        echo "date,timestamp,duration_ms,average_power_watt,total_energy_joule,samples,method" \
            | sudo tee "$final_csv" > /dev/null
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S'),$START_TS,$DURATION_MS,$power,$energy,$count,$method" \
        | sudo tee -a "$final_csv" > /dev/null

    # Nettoyage fichier temporaire ecofloc
    [ -n "$temp_file" ] && sudo rm -f "$temp_file"
}

# Détermine méthode et valeurs finales par composant
CPU_METHOD=$([ "$ECO_CPU_N" -gt 0 ] 2>/dev/null && echo "ECOFLOC" || echo "RAPL")
RAM_METHOD=$([ "$ECO_RAM_N" -gt 0 ] 2>/dev/null && echo "ECOFLOC" || echo "RAPL")

archive_row "cpu" \
    "$([ "$ECO_CPU_N" -gt 0 ] 2>/dev/null && echo $ECO_CPU_W || echo $RAPL_CPU_W)" \
    "$([ "$ECO_CPU_N" -gt 0 ] 2>/dev/null && echo $ECO_CPU_J || echo $RAPL_CPU_J)" \
    "$ECO_CPU_N" "$CPU_METHOD" "$ECO_CPU_FILE"

archive_row "ram" \
    "$([ "$ECO_RAM_N" -gt 0 ] 2>/dev/null && echo $ECO_RAM_W || echo $RAPL_RAM_W)" \
    "$([ "$ECO_RAM_N" -gt 0 ] 2>/dev/null && echo $ECO_RAM_J || echo $RAPL_RAM_J)" \
    "$ECO_RAM_N" "$RAM_METHOD" "$ECO_RAM_FILE"

archive_row "sd"  "$ECO_SD_W"  "$ECO_SD_J"  "$ECO_SD_N"  "ECOFLOC" "$ECO_SD_FILE"
archive_row "nic" "$ECO_NIC_W" "$ECO_NIC_J" "$ECO_NIC_N" "ECOFLOC" "$ECO_NIC_FILE"

if $NVIDIA_OK; then
    archive_row "gpu" "$ECO_GPU_W" "$ECO_GPU_J" "$ECO_GPU_N" "ECOFLOC" "$ECO_GPU_FILE"
else
    archive_row "gpu" "$RAPL_GPU_W" "$RAPL_GPU_J" "0" "RAPL_iGPU" ""
fi

echo ">>> Archivé dans : $METRICS_DIR"
echo ">>> Méthode finale : $METHOD"
echo "============================================================"
exit ${EXIT_CODE:-0}
