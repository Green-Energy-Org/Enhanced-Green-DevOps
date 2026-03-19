#!/bin/bash
# ==============================================================================
# green_runner.sh — Mesure énergétique GitHub Actions Self-Hosted Runner
# ==============================================================================
# Architecture réelle du runner :
#   Runner.Worker (PID) ← pas de GITHUB_JOB ici
#       └── bash (PID)  ← GITHUB_JOB injecté ici
#               └── steps...
#
# Stratégie :
#   1. Cherche les process bash/sh ayant GITHUB_JOB dans leur environ
#   2. Remonte au Runner.Worker parent → c'est lui qu'on mesure
#   3. RAPL avant/après pour CPU+GPU (capture tous les enfants)
#   4. ecofloc -n Runner.Worker pour RAM/SD/NIC
#   5. Append CSV par job + energy_pipeline_total.csv
#
# Fichiers générés :
#   job_<pid>_<job_name>_cpu.csv
#   job_<pid>_<job_name>_ram.csv
#   job_<pid>_<job_name>_sd.csv
#   job_<pid>_<job_name>_nic.csv
#   job_<pid>_<job_name>_gpu.csv
#   energy_pipeline_total.csv
#
# Usage :
#   sudo bash green_runner.sh [metrics_dir] [interval_ms]
# ==============================================================================

METRICS_DIR=${1:-"/home/medyassine/GreenDevOps/energy_metrics"}
INTERVAL=${2:-1000}
POLL=2   # secondes entre chaque scan (2s suffit, réduit la charge)

mkdir -p "$METRICS_DIR"
sudo modprobe msr 2>/dev/null

# RAPL paths (Intel i5-8250U)
RAPL_PKG="/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj"
RAPL_CORE="/sys/class/powercap/intel-rapl/intel-rapl:0/intel-rapl:0:0/energy_uj"
RAPL_IGPU="/sys/class/powercap/intel-rapl/intel-rapl:0/intel-rapl:0:1/energy_uj"

RAPL_OK=false; [ -r "$RAPL_PKG" ]  && RAPL_OK=true
CORE_OK=false; [ -r "$RAPL_CORE" ] && CORE_OK=true
IGPU_OK=false; [ -r "$RAPL_IGPU" ] && IGPU_OK=true

# Tableaux associatifs
declare -A ACTIVE_JOBS         # worker_pid → job_name
declare -A ACTIVE_RUN_IDS      # worker_pid → run_id
declare -A ACTIVE_ECOFLOC      # worker_pid → "eco_ram eco_sd eco_nic"
declare -A JOB_START_TS        # worker_pid → timestamp début
declare -A JOB_RAPL_PKG        # worker_pid → RAPL avant
declare -A JOB_RAPL_CORE       # worker_pid → RAPL avant
declare -A JOB_RAPL_IGPU       # worker_pid → RAPL avant
declare -A SEEN_BASH_PIDS      # bash_pid → 1 (déjà traité)

# Accumulateurs pipeline
declare -A RUN_CPU_J
declare -A RUN_RAM_J
declare -A RUN_SD_J
declare -A RUN_NIC_J
declare -A RUN_GPU_J
declare -A RUN_TOTAL_J
declare -A RUN_JOB_COUNT
declare -A RUN_START_TS
declare -A RUN_JOBS_LIST

echo "================================================================"
echo "  GREEN RUNNER — Mesure énergétique GitHub Actions"
echo "  Metrics  : $METRICS_DIR"
echo "  Interval : ${INTERVAL}ms"
echo "  RAPL     : PKG=$RAPL_OK CORE=$CORE_OK iGPU=$IGPU_OK"
echo "  PID      : $$"
echo "  Démarré  : $(date)"
echo "================================================================"
echo "[*] Stratégie : détecte bash avec GITHUB_JOB → remonte au Runner.Worker"

# ==============================================================================
# Utilitaires
# ==============================================================================

# Lit une variable depuis /proc/PID/environ
env_var() {
    local pid=$1 var=$2
    sudo cat /proc/$pid/environ 2>/dev/null \
        | tr '\0' '\n' | grep "^${var}=" | cut -d'=' -f2 | head -1
}

# Lit un compteur RAPL
rapl_read() { sudo cat "$1" 2>/dev/null || echo "0"; }

# Calcule Joules depuis deux lectures RAPL en µJ
rapl_joules() {
    echo "scale=6; ($2 - $1) / 1000000" | bc 2>/dev/null || echo "0"
}

# Additionne deux floats
fadd() {
    local a=${1:-0} b=${2:-0}
    [[ "$a" =~ ^[0-9] ]] || a=0
    [[ "$b" =~ ^[0-9] ]] || b=0
    echo "scale=6; $a + $b" | bc 2>/dev/null || echo "0"
}

# Divise deux floats
fdiv() {
    local a=${1:-0} b=${2:-1}
    [ "$b" = "0" ] && echo "0" && return
    echo "scale=4; $a / $b" | bc 2>/dev/null || echo "0"
}

# Trouve le PID Runner.Worker parent d'un PID bash
find_worker_parent() {
    local pid=$1
    local current=$pid
    local max_depth=10

    for i in $(seq 1 $max_depth); do
        local ppid=$(awk '{print $4}' /proc/$current/stat 2>/dev/null)
        [ -z "$ppid" ] && break

        local comm=$(cat /proc/$ppid/comm 2>/dev/null)
        if echo "$comm" | grep -qi "Runner.Worker\|runner.worker"; then
            echo "$ppid"
            return
        fi
        current=$ppid
    done
    echo ""
}

# Parse CSV ecofloc COMM Runner.Worker
parse_ecofloc_comm() {
    local mod=$1
    local csv
    csv=$(sudo ls "${METRICS_DIR}/ECOFLOC_${mod}_COMM_Runner.Worker"*.csv \
        2>/dev/null | head -1)
    if [ -n "$csv" ] && [ -s "$csv" ]; then
        local result
        result=$(sudo awk -F',' '
            /^[0-9]/ { sum_p+=$3; sum_e+=$4; n++ }
            END {
                if (n>0) printf "%.4f %.4f %d\n", sum_p/n, sum_e, n
                else     printf "0.0000 0.0000 0\n"
            }' "$csv")
        echo "$result $csv"
    else
        echo "0.0000 0.0000 0 "
    fi
}

# ==============================================================================
# Démarre la mesure sur un Runner.Worker
# ==============================================================================
start_measurement() {
    local worker_pid=$1 job_name=$2 run_id=$3
    local start_ts=$(date +%s)

    echo ""
    echo "┌────────────────────────────────────────────────────────"
    echo "│ [START] Job         : $job_name"
    echo "│         RunID       : $run_id"
    echo "│         Worker PID  : $worker_pid"
    echo "│         Heure       : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "└────────────────────────────────────────────────────────"

    # Snapshot RAPL AVANT
    JOB_RAPL_PKG[$worker_pid]=$(rapl_read "$RAPL_PKG")
    JOB_RAPL_CORE[$worker_pid]=$(rapl_read "$RAPL_CORE")
    JOB_RAPL_IGPU[$worker_pid]=$(rapl_read "$RAPL_IGPU")

    # Sync chemin ecofloc
    for conf in ram sd nic; do
        echo "$METRICS_DIR/" \
            | sudo tee /opt/ecofloc/${conf}_settings.conf > /dev/null 2>&1
    done

    # ecofloc -n Runner.Worker pour RAM/SD/NIC
    sudo ecofloc --ram -n "Runner.Worker" -i $INTERVAL -t 3600 \
        -f "$METRICS_DIR/" > /dev/null 2>&1 &
    local eco_ram=$!
    sudo ecofloc --sd -n "Runner.Worker" -i $INTERVAL -t 3600 \
        -f "$METRICS_DIR/" > /dev/null 2>&1 &
    local eco_sd=$!
    sudo ecofloc --nic -n "Runner.Worker" -i $INTERVAL -t 3600 \
        -f "$METRICS_DIR/" > /dev/null 2>&1 &
    local eco_nic=$!

    ACTIVE_JOBS[$worker_pid]="$job_name"
    ACTIVE_RUN_IDS[$worker_pid]="$run_id"
    ACTIVE_ECOFLOC[$worker_pid]="$eco_ram $eco_sd $eco_nic"
    JOB_START_TS[$worker_pid]="$start_ts"

    # Initialise accumulateurs pipeline si premier job du run
    if [ -z "${RUN_START_TS[$run_id]}" ]; then
        RUN_START_TS[$run_id]="$start_ts"
        RUN_CPU_J[$run_id]="0"; RUN_RAM_J[$run_id]="0"
        RUN_SD_J[$run_id]="0";  RUN_NIC_J[$run_id]="0"
        RUN_GPU_J[$run_id]="0"; RUN_TOTAL_J[$run_id]="0"
        RUN_JOB_COUNT[$run_id]="0"; RUN_JOBS_LIST[$run_id]=""
    fi

    echo "[*] RAPL_CORE avant : ${JOB_RAPL_CORE[$worker_pid]}µJ"
    echo "[*] ecofloc sondes  : RAM=$eco_ram SD=$eco_sd NIC=$eco_nic"
}

# ==============================================================================
# Arrête la mesure, calcule, archive
# ==============================================================================
stop_measurement() {
    local worker_pid=$1
    local job_name="${ACTIVE_JOBS[$worker_pid]}"
    local run_id="${ACTIVE_RUN_IDS[$worker_pid]}"
    local start_ts="${JOB_START_TS[$worker_pid]}"
    local eco_pids="${ACTIVE_ECOFLOC[$worker_pid]}"
    local end_ts=$(date +%s)
    local duration=$((end_ts - start_ts))

    # Snapshot RAPL APRÈS
    local rapl_pkg_after=$(rapl_read "$RAPL_PKG")
    local rapl_core_after=$(rapl_read "$RAPL_CORE")
    local rapl_igpu_after=$(rapl_read "$RAPL_IGPU")

    # Calcul CPU et GPU via RAPL
    local cpu_j=$(rapl_joules "${JOB_RAPL_CORE[$worker_pid]}" "$rapl_core_after")
    local gpu_j=$(rapl_joules "${JOB_RAPL_IGPU[$worker_pid]}" "$rapl_igpu_after")
    local pkg_j=$(rapl_joules "${JOB_RAPL_PKG[$worker_pid]}"  "$rapl_pkg_after")
    local cpu_w=$(fdiv "$cpu_j" "$duration")
    local gpu_w=$(fdiv "$gpu_j" "$duration")

    # Arrêt ecofloc
    for eco_pid in $eco_pids; do
        sudo kill -2 $eco_pid 2>/dev/null
    done
    sleep 2

    # Parse RAM/SD/NIC depuis ecofloc
    read ram_w ram_j ram_n ram_csv <<< $(parse_ecofloc_comm "RAM")
    read sd_w  sd_j  sd_n  sd_csv  <<< $(parse_ecofloc_comm "SD")
    read nic_w nic_j nic_n nic_csv <<< $(parse_ecofloc_comm "NIC")

    # Fallback RAM si ecofloc vide
    local ram_method="ecofloc-n"
    if [ "$ram_n" = "0" ] || [ "$ram_j" = "0.0000" ]; then
        ram_j=$(echo "scale=6; $pkg_j - $cpu_j - $gpu_j" | bc 2>/dev/null || echo "0")
        ram_j=$(echo "scale=6; if ($ram_j < 0) 0 else $ram_j" | bc 2>/dev/null || echo "0")
        ram_w=$(fdiv "$ram_j" "$duration")
        ram_n="-"; ram_method="RAPL_est"
    fi
    local sd_method="ecofloc-n";  [ "$sd_n"  = "0" ] && sd_method="N/A"
    local nic_method="ecofloc-n"; [ "$nic_n" = "0" ] && nic_method="N/A"

    local total_j=$(fadd \
        $(fadd $(fadd $(fadd "$cpu_j" "$ram_j") "$sd_j") "$nic_j") "$gpu_j")

    echo ""
    echo "┌────────────────────────────────────────────────────────"
    echo "│ [STOP]  Job        : $job_name"
    echo "│         RunID      : $run_id"
    echo "│         Worker PID : $worker_pid"
    echo "│         Durée      : ${duration}s"
    echo "│         Heure      : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "└────────────────────────────────────────────────────────"
    printf "\n  %-8s | %-12s | %-14s | %-8s | %-12s\n" \
        "COMPOS." "PUISS.(W)" "ENERGIE(J)" "MESURES" "METHODE"
    echo "  ──────────────────────────────────────────────────────"
    printf "  %-8s | %-12s | %-14s | %-8s | %-12s\n" \
        "CPU"   "$cpu_w"  "$cpu_j"  "-"      "RAPL_core"
    printf "  %-8s | %-12s | %-14s | %-8s | %-12s\n" \
        "RAM"   "$ram_w"  "$ram_j"  "$ram_n" "$ram_method"
    printf "  %-8s | %-12s | %-14s | %-8s | %-12s\n" \
        "SD"    "$sd_w"   "$sd_j"   "$sd_n"  "$sd_method"
    printf "  %-8s | %-12s | %-14s | %-8s | %-12s\n" \
        "NIC"   "$nic_w"  "$nic_j"  "$nic_n" "$nic_method"
    printf "  %-8s | %-12s | %-14s | %-8s | %-12s\n" \
        "GPU"   "$gpu_w"  "$gpu_j"  "-"      "RAPL_iGPU"
    echo "  ──────────────────────────────────────────────────────"
    printf "  %-8s | %-12s | %-14s\n" \
        "TOTAL" "$(fdiv $total_j $duration)" "$total_j"

    # Préfixe fichier : job_<worker_pid>_<job_name>
    local prefix="job_${worker_pid}_${job_name}"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    local header="date,run_id,worker_pid,job_name,duration_s,avg_power_w,total_energy_j,samples,method"

    # APPEND CSV par composant
    for entry in \
        "cpu:$cpu_w:$cpu_j:-:RAPL_core" \
        "ram:$ram_w:$ram_j:$ram_n:$ram_method" \
        "sd:$sd_w:$sd_j:$sd_n:$sd_method" \
        "nic:$nic_w:$nic_j:$nic_n:$nic_method" \
        "gpu:$gpu_w:$gpu_j:-:RAPL_iGPU"
    do
        IFS=: read mod pw ej sn mt <<< "$entry"
        local csv="${METRICS_DIR}/${prefix}_${mod}.csv"
        [ ! -f "$csv" ] && echo "$header" | sudo tee "$csv" > /dev/null
        echo "$ts,$run_id,$worker_pid,$job_name,$duration,$pw,$ej,$sn,$mt" \
            | sudo tee -a "$csv" > /dev/null
    done

    echo ""
    echo "  >>> Fichiers (append) :"
    echo "      ${prefix}_cpu.csv  ${prefix}_ram.csv (${ram_method})"
    echo "      ${prefix}_sd.csv (${sd_method})  ${prefix}_nic.csv (${nic_method})"
    echo "      ${prefix}_gpu.csv"

    # Nettoie CSVs temporaires ecofloc
    [ -n "$ram_csv" ] && sudo rm -f "$ram_csv"
    [ -n "$sd_csv"  ] && sudo rm -f "$sd_csv"
    [ -n "$nic_csv" ] && sudo rm -f "$nic_csv"

    # Accumule dans total pipeline
    RUN_CPU_J[$run_id]=$(fadd "${RUN_CPU_J[$run_id]}" "$cpu_j")
    RUN_RAM_J[$run_id]=$(fadd "${RUN_RAM_J[$run_id]}" "$ram_j")
    RUN_SD_J[$run_id]=$(fadd  "${RUN_SD_J[$run_id]}"  "$sd_j")
    RUN_NIC_J[$run_id]=$(fadd "${RUN_NIC_J[$run_id]}" "$nic_j")
    RUN_GPU_J[$run_id]=$(fadd "${RUN_GPU_J[$run_id]}" "$gpu_j")
    RUN_TOTAL_J[$run_id]=$(fadd "${RUN_TOTAL_J[$run_id]}" "$total_j")
    RUN_JOB_COUNT[$run_id]=$(( ${RUN_JOB_COUNT[$run_id]:-0} + 1 ))
    if [ -z "${RUN_JOBS_LIST[$run_id]}" ]; then
        RUN_JOBS_LIST[$run_id]="$job_name"
    else
        RUN_JOBS_LIST[$run_id]="${RUN_JOBS_LIST[$run_id]}|$job_name"
    fi

    # Nettoie tableaux du job
    unset ACTIVE_JOBS[$worker_pid] ACTIVE_RUN_IDS[$worker_pid]
    unset ACTIVE_ECOFLOC[$worker_pid] JOB_START_TS[$worker_pid]
    unset JOB_RAPL_PKG[$worker_pid] JOB_RAPL_CORE[$worker_pid]
    unset JOB_RAPL_IGPU[$worker_pid]
}

# ==============================================================================
# Archive total pipeline → energy_pipeline_total.csv (append)
# ==============================================================================
archive_pipeline_total() {
    local run_id=$1
    local duration=$(( $(date +%s) - ${RUN_START_TS[$run_id]} ))
    local cpu_j="${RUN_CPU_J[$run_id]:-0}"
    local ram_j="${RUN_RAM_J[$run_id]:-0}"
    local sd_j="${RUN_SD_J[$run_id]:-0}"
    local nic_j="${RUN_NIC_J[$run_id]:-0}"
    local gpu_j="${RUN_GPU_J[$run_id]:-0}"
    local total_j="${RUN_TOTAL_J[$run_id]:-0}"
    local job_count="${RUN_JOB_COUNT[$run_id]:-0}"
    local jobs_list="${RUN_JOBS_LIST[$run_id]}"

    echo ""
    echo "╔══════════════════════════════════════════════════════════"
    echo "║  PIPELINE TERMINÉ — RunID : $run_id"
    echo "║  Jobs ($job_count) : $jobs_list"
    echo "║  Durée : ${duration}s"
    echo "╠══════════════════════════════════════════════════════════"
    printf "║  %-6s : %s J\n" "CPU"   "$cpu_j"
    printf "║  %-6s : %s J\n" "RAM"   "$ram_j"
    printf "║  %-6s : %s J\n" "SD"    "$sd_j"
    printf "║  %-6s : %s J\n" "NIC"   "$nic_j"
    printf "║  %-6s : %s J\n" "GPU"   "$gpu_j"
    echo   "╠══════════════════════════════════════════════════════════"
    printf "║  %-6s : %s J\n" "TOTAL" "$total_j"
    echo   "╚══════════════════════════════════════════════════════════"

    local csv="${METRICS_DIR}/energy_pipeline_total.csv"
    [ ! -f "$csv" ] && echo \
        "date,run_id,duration_s,job_count,jobs_list,cpu_j,ram_j,sd_j,nic_j,gpu_j,total_j" \
        | sudo tee "$csv" > /dev/null

    echo "$(date '+%Y-%m-%d %H:%M:%S'),$run_id,$duration,$job_count,$jobs_list,$cpu_j,$ram_j,$sd_j,$nic_j,$gpu_j,$total_j" \
        | sudo tee -a "$csv" > /dev/null

    echo "[*] >>> energy_pipeline_total.csv (append) ✓"

    unset RUN_CPU_J[$run_id] RUN_RAM_J[$run_id] RUN_SD_J[$run_id]
    unset RUN_NIC_J[$run_id] RUN_GPU_J[$run_id] RUN_TOTAL_J[$run_id]
    unset RUN_JOB_COUNT[$run_id] RUN_START_TS[$run_id] RUN_JOBS_LIST[$run_id]
}

# ==============================================================================
# Cleanup
# ==============================================================================
cleanup() {
    echo ""
    echo "[*] Arrêt — finalisation des mesures actives..."
    for pid in "${!ACTIVE_JOBS[@]}"; do stop_measurement "$pid"; done
    for run_id in "${!RUN_START_TS[@]}"; do archive_pipeline_total "$run_id"; done
    sudo pkill -2 -f "ecofloc --ram" 2>/dev/null
    sudo pkill -2 -f "ecofloc --sd"  2>/dev/null
    sudo pkill -2 -f "ecofloc --nic" 2>/dev/null
    echo "[*] Green Runner arrêté."
    exit 0
}
trap cleanup SIGINT SIGTERM

# ==============================================================================
# BOUCLE PRINCIPALE
# Stratégie : cherche bash/sh avec GITHUB_JOB → remonte au Runner.Worker parent
# ==============================================================================
while true; do

    # Cherche tous les process bash/sh/python qui ont GITHUB_JOB dans leur env
    # Plus efficace que de scanner tous les Runner.Worker
    BASH_PIDS=$(
    pgrep -f "bash" 2>/dev/null
    pgrep -f "Runner.Worker" 2>/dev/null
    pgrep -f "/bin/sh" 2>/dev/null
)

    for bash_pid in $BASH_PIDS; do

        # Déjà traité → skip
        [ -n "${SEEN_BASH_PIDS[$bash_pid]}" ] && continue

        # Vérifie que le process existe
        kill -0 "$bash_pid" 2>/dev/null || continue

        # Lit GITHUB_JOB depuis l'environ de ce process
        github_job=$(env_var "$bash_pid" "GITHUB_JOB")

        if [ -z "$github_job" ]; then
            # Pas un process CI → ignore et mémorise
            SEEN_BASH_PIDS[$bash_pid]=1
            continue
        fi

        # ✅ GITHUB_JOB trouvé — c'est un vrai job CI
        run_id=$(env_var "$bash_pid" "GITHUB_RUN_ID")
        [ -z "$run_id" ] && run_id="run_$(date +%Y%m%d_%H%M%S)"

        job_name=$(echo "$github_job" \
            | tr '[:upper:]' '[:lower:]' \
            | tr ' ' '_' \
            | tr -cd '[:alnum:]_-')

        # Remonte au Runner.Worker parent pour mesurer à ce niveau
        worker_pid=$(find_worker_parent "$bash_pid")

        if [ -z "$worker_pid" ]; then
            # Pas de Runner.Worker parent trouvé → utilise bash_pid directement
            worker_pid="$bash_pid"
            echo "[WARN] Runner.Worker parent non trouvé pour PID $bash_pid"
        fi

        # Vérifie que ce worker n'est pas déjà suivi
        if [ -n "${ACTIVE_JOBS[$worker_pid]}" ]; then
            SEEN_BASH_PIDS[$bash_pid]=1
            continue
        fi

        echo "[*] GITHUB_JOB=$github_job détecté (bash=$bash_pid → worker=$worker_pid)"
        SEEN_BASH_PIDS[$bash_pid]=1
        start_measurement "$worker_pid" "$job_name" "$run_id"
    done

    # Nettoie les SEEN_BASH_PIDS morts
    for pid in "${!SEEN_BASH_PIDS[@]}"; do
        kill -0 "$pid" 2>/dev/null || unset SEEN_BASH_PIDS[$pid]
    done

    # Détecte les Runner.Worker morts → finalise
    for worker_pid in "${!ACTIVE_JOBS[@]}"; do
        kill -0 "$worker_pid" 2>/dev/null && continue

        run_id="${ACTIVE_RUN_IDS[$worker_pid]}"
        stop_measurement "$worker_pid"

        # Dernier job du run ?
        run_active=false
        for p in "${!ACTIVE_JOBS[@]}"; do
            [ "${ACTIVE_RUN_IDS[$p]}" = "$run_id" ] \
                && run_active=true && break
        done
        if [ "$run_active" = false ] && [ -n "${RUN_START_TS[$run_id]}" ]; then
            archive_pipeline_total "$run_id"
        fi
    done

    sleep $POLL
done
