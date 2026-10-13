#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "================================================================"
echo " Building and Executing INT8 PE Simulation (Icarus Verilog)"
echo "================================================================"

# Check for iverilog
if ! command -v iverilog &> /dev/null; then
    echo "Error: iverilog is not found in PATH."
    echo "Check if Homebrew installed it in /opt/homebrew/bin or /Users/aditisharma/.local/bin"
    exit 1
fi

mkdir -p "$ROOT_DIR/build"

# Compile with SystemVerilog-2012 support
iverilog -g2012 \
    -o "$ROOT_DIR/build/pe_sim" \
    "$ROOT_DIR/rtl/pe.sv" \
    "$ROOT_DIR/tb/tb_pe.sv"

echo "Compilation successful. Running simulation..."
cd "$ROOT_DIR/build"
vvp pe_sim

echo ""
echo "Simulation completed. Waveform generated at: $ROOT_DIR/build/pe_waves.vcd"
