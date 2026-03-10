#!/bin/bash
JOB_NAME=$1
COMMAND=$2

# Identify the root of the monorepo (assuming script is in /scripts)
REPO_ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
METRICS_DIR="$REPO_ROOT/green_metrics"

# Ensure the metrics directory exists outside the scripts folder
mkdir -p "$METRICS_DIR"

# 1. Start EcoFloc (Points to the absolute metrics path)
sudo ecofloc --cpu --ram --sd --nic --gpu -L "Runner.Worker" -i 1000 -t -1 -f "$METRICS_DIR/${JOB_NAME}_$(date +%s).csv" &
ECO_PID=$!

# 2. Run your actual pipeline job
echo "Starting Job: $JOB_NAME"
eval $COMMAND

# 3. Stop EcoFloc gracefully
sudo kill -SIGINT $ECO_PID
echo "Job $JOB_NAME finished. Metrics saved to $METRICS_DIR"
