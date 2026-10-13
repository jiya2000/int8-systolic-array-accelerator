# INT8 Systolic Array Accelerator IP

[![Hardware Verification](https://img.shields.io/badge/Verification-100%25%20PASS%20(1%2C785%20SV%20%7C%201%2C008%20Cocotb%20%7C%208%2C016%20Python)-brightgreen)](#verification--test-results)
[![Synthesis](https://img.shields.io/badge/Yosys%20Synthesis-12%2C894%20Cells%20%7C%201%2C424%20DFFs%20%7C%200%20Latches-blue)](#logic-synthesis--gate-level-metrics)
[![Language](https://img.shields.io/badge/RTL-SystemVerilog%20IEEE%201800--2017-orange)](#system-architecture)
[![Verification Flow](https://img.shields.io/badge/Testbench-SV%20%2B%20Cocotb%20Python-yellow)](#verification-methodology)

A complete, production-grade, synthesizable **4×4 Weight-Stationary (WS) INT8 Systolic Array Accelerator IP** implemented in SystemVerilog. Designed for high-efficiency General Matrix Multiplication (GEMM) acceleration in deep learning inference workloads.

This project features synthesizable RTL, an AXI4-Stream-compatible point-to-point streaming protocol with backpressure handling, an autonomous FSM controller, dual-flow verification (SystemVerilog + Cocotb Python co-simulation + independent integer reference models), and automated Yosys gate-level logic synthesis.

---

## 1. Architectural Highlights

- **Weight-Stationary Dataflow:** Maximizes energy efficiency by holding weights in stationary processing element registers during compute, eliminating redundant SRAM accesses.
- **Signed Two's Complement Arithmetic:** 
  - Input operands: Signed 8-bit ($A, W \in [-128, 127]$).
  - Multiplier precision: Exact 16-bit signed products ($P = A \times W$). Handles extreme negative corner cases without overflow ($(-128) \times (-128) = +16,384$).
  - Accumulation: 32-bit signed accumulators ($C \in [-2^{31}, 2^{31}-1]$) with deterministic two's complement wraparound.
- **Top-Level Weight-Loading Protocol:**
  - Handshake-driven row loading: a weight row is accepted strictly on clock edges where `s_weight_valid && s_weight_ready`.
  - Row targeting: the controller asserts a one-hot `weight_en` mask matching the current `weight_row_cnt`, loading weights into the designated systolic array row.
  - Completion detection: after 4 consecutive rows are accepted, the controller asserts `weights_loaded` and transitions to ready state.
  - Backpressure safety: `s_weight_ready = 0` during active compute and output streaming, protecting stationary weights from corruption.
- **Deterministic Control Priority:** Strict control precedence (`rst_n` > `weight_en` > `en` > `clr` > stall) eliminates race conditions and ensures glitch-free pipeline flushing.
- **AXI4-Stream-Compatible Flow Control:** Point-to-point streaming interfaces (`tvalid`, `tready`, `tdata`, `tlast`) with full backpressure tolerance. Output data, valid, and last signals remain glitch-free and rock-solid during downstream stalls. (Implements core valid/ready handshake and frame boundary rules without unneeded bus sideband signals).
- **Autonomous Controller:** 4-state FSM (`IDLE`, `LOAD_WEIGHTS`, `FEED_AND_DRAIN`, `COMPLETE`) handling weight configuration, activation skew scheduling, and output collection.
- **Universal EDA Portability:** Implemented with packed multi-dimensional array ports and `genvar` generate constructs, eliminating array slicing synthesis errors across Icarus Verilog, Yosys, and commercial ASIC toolchains.
- **Modular IP Ecosystem:** Includes `rtl/input_buffer.sv`, an independently verified, parameterizable circular FIFO core with AXI-Stream flow control for optional upstream interface decoupling.

---

## 2. System Architecture

```
                    +-------------------------------------------------------------+
                    |                 int8_accelerator_top                        |
                    |                                                             |
s_weight_data [3:0] |===> [ Weight Configuration Port ]                           |
s_weight_valid/ready|       - Synchronized valid/ready handshake per row          |
                    |       - Decoded one-hot enables per PE row                  |
                    |       - Automatically protected while busy                  |
                    |                                                             |
                    |     +-------------------------------------------------+     |
s_axis_tdata [3:0]  |===> | Activation Staging Bank (4x4 Matrix A)          |     |
s_axis_tvalid/ready |     +-------------------------------------------------+     |
s_axis_tlast        |                       |                                     |
                    |                       v                                     |
                    |     +-------------------------------------------------+     |
                    |     | Activation Skew Generator                       |     |
                    |     | Row k delayed by k clock cycles                 |     |
                    |     +-------------------------------------------------+     |
                    |                       | (a_in)                              |
                    |                       v                                     |
                    |     +-------------------------------------------------+     |
                    |     | 4x4 Weight-Stationary Systolic Array Grid       |     |
                    |     | 16 PEs (West->East Activations, North->South Psum)|     |
                    |     +-------------------------------------------------+     |
                    |                       | (c_out)                             |
                    |                       v                                     |
                    |     +-------------------------------------------------+     |
                    |     | Output De-skew & Capture Logic                  |     |
                    |     | Captures C[i][j] at cycle (i + 4 + j)           |     |
                    |     +-------------------------------------------------+     |
                    |                       |                                     |
                    |                       v                                     |
                    |     +-------------------------------------------------+     |
                    |     | Output Streaming Engine (AXI-Stream Compatible) |     |
m_axis_tvalid/ready | <===|   - Row-by-row readout                          |     |
m_axis_tdata [3:0]  |     |   - Backpressure tolerant (freezes on stall)    |     |
m_axis_tlast        |     +-------------------------------------------------+     |
                    |                                                             |
                    |  +-------------------------------------------------------+  |
clk, rst_n          |  | FSM Accelerator Controller                            |  |
busy, done          |  | Manages 11-cycle compute schedule & status flags      |  |
                    |  +-------------------------------------------------------+  |
                    +-------------------------------------------------------------+
```

### Processing Element (PE) Micro-Architecture
```
                      w_in [7:0]
                          |
                          v
               +----------------------+
               |  Stationary Weight   |
               |     Register (W)     |
               +----------+-----------+
                          |
                          v
a_in [7:0] ---> [ Signed 8x8 Multiplier ]
(West)                    |
                    16-bit Product
                          |
                          v
c_in [31:0] --> [ 32-bit Signed Adder ] ----> c_out [31:0]
(North)                   |                   (South, Registered)
                          v
                 [ a_out Register ] ---------> a_out [7:0]
                                              (East, Registered)
```

---

## 3. Systolic Dataflow & Timing Math

In a 2D weight-stationary systolic array, compute synchronization requires deliberate spatial data skewing:

1. **Activation Staggering:**
   $$\text{Arrival cycle of } A[i][k] \text{ at array row } k = i + k$$
   Row 0 enters with delay 0, Row 1 with delay 1, Row 2 with delay 2, Row 3 with delay 3. Active feeding requires 7 clock cycles ($t \in [0..6]$).

2. **Output Accumulation & Retirement:**
   $$t_{\text{retire}}(i, j) = i + 4 + j$$
   Element $C[0][0]$ exits at cycle 4; final element $C[3][3]$ exits at cycle 10. De-skewing registers latch each partial sum into `result_matrix` on cycle 11.
   Total compute latency is exactly **11 clock cycles**, eliminating unnecessary dead cycles.

---

## 4. Directory Structure

```
int8-systolic-array-accelerator/
├── Makefile                        # Master test & synthesis automation flow
├── README.md                       # Architectural documentation & reproduction guide
├── docs/
│   ├── microarchitecture_spec.md   # Full hardware specification & timing equations
│   ├── verification_plan.md        # Test matrix, corner cases, and acceptance criteria
│   └── results.md                  # Comprehensive verification & synthesis report
├── rtl/
│   ├── pe.sv                       # Synthesizable INT8 Processing Element tile
│   ├── systolic_array.sv           # Parameterized 4x4 PE grid with packed ports
│   ├── input_buffer.sv             # Standalone streaming FIFO with backpressure
│   ├── accelerator_controller.sv   # Reconciled 4-state FSM controller
│   └── int8_accelerator_top.sv     # Top-level IP integration with skew/de-skew logic
├── tb/
│   ├── tb_pe.sv                    # PE exhaustive directed unit testbench (25 tests)
│   ├── test_pe.py                  # Cocotb Python randomized testbench (1,008 vectors)
│   ├── Makefile.pe                 # Cocotb test runner Makefile
│   ├── reference_model.py          # Independent integer reference model (8 phases, 513 GEMMs)
│   ├── tb_systolic_array.sv        # 4x4 array GEMM verification testbench (16 elements)
│   ├── tb_input_buffer.sv          # FIFO handshake & backpressure testbench (14 tests)
│   ├── tb_accelerator_top.sv       # Top-level integration & stall testbench (130 asserts, 6 GEMMs)
│   └── tb_accelerator_randomized.sv# 100-matrix randomized regression suite (1,600 outputs)
├── sim/
│   ├── golden_model.py             # Software GEMM reference and matrix generator
│   └── run_pe_sim.sh               # Standalone shell simulation runner
├── scripts/
│   ├── synth_accelerator.ys        # Yosys logic synthesis script
│   └── compare_power_opt.ys        # Optimization comparison script
└── reports/
    └── synthesis_stats.txt         # Full Yosys cell count and transistor report
```

---

## 5. Verification & Test Results

The IP is verified using a dual-track methodology combining IEEE 1800-2017 SystemVerilog self-checking testbenches, Cocotb Python co-simulation, and an independent Python integer reference model. Metrics are explicitly separated into **Transactions**, **Matrix Elements Checked**, and **Assertions / Protocol Checks**:

| Test Suite | Scope | Target | Transactions | Output Elements Checked | Assertions / Protocol Checks | Pass Rate |
| :--- | :--- | :--- | :---: | :---: | :---: | :---: |
| `sim_pe` | Directed Unit Test | `pe.sv` | 25 steps | 25 scalar values | 25 assertions | **100% PASS** |
| `test_cocotb` | Randomized Co-Simulation | `pe.sv` | 1,008 trans | 1,008 scalar values | 1,008 assertions | **100% PASS** |
| `sim_array` | Core Compute Grid | `systolic_array.sv` | 1 GEMM | 16 elements | 16 assertions | **100% PASS** |
| `sim_fifo` | Buffer Handshake (Standalone IP)| `input_buffer.sv` | 24 words | 8 FIFO entries | 14 assertions | **100% PASS** |
| `sim_top` | Integration, Stalls & Extremes | `int8_accelerator_top.sv` | 6 GEMMs (T1–T5) | 96 elements | 130 assertions | **100% PASS** |
| `sim_randomized` | 100-Matrix Stress | `int8_accelerator_top.sv` | 100 GEMMs | 1,600 elements | 1,700 assertions | **100% PASS** |
| `reference_model.py` | Python Reference Model | GEMM & Boundaries | 513 GEMMs | 8,016 elements | 8,016 element checks | **100% PASS** |
| `golden_model.py` | Golden Architecture Model | Timing & Matrices | Directed suites | All elements | Directed validations | **100% PASS** |
| **SystemVerilog Suite** | **Hardware Sim** | **Core Design** | **107 GEMMs + 49 Unit** | **1,737 Elements** | **1,785 Assertions** | **100% PASS** |
| **Complete Verification**| **Dual-Flow & Reference** | **All Verification** | **1,628 Transactions** | **10,761 Elements** | **10,809 Evaluations** | **100% PASS** |

---

## 6. Logic Synthesis & Gate-Level Metrics

Synthesized using **Yosys 0.69+post** targeting a generic standard-cell CMOS technology library (`scripts/synth_accelerator.ys`):

- **Total Standard Cells:** 12,894 gates
- **Sequential Flip-Flops:** 1,424 DFFs (`$_DFFE_PN0P_` / `$_DFF_PN0_`)
- **Combinational Logic:**
  - 4,138 NAND gates
  - 2,940 AND gates
  - 1,858 XOR gates
  - 817 XNOR gates
  - 602 OR gates
  - 587 NOR gates
  - 265 ANDNOT gates
  - 162 ORNOT gates
  - 81 Multiplexers (`$_MUX_`)
  - 20 Inverters
- **Estimated Transistor Equivalent:** 75,826+ transistors
- **Latch Count:** 0 (Zero unintended latches verified by Yosys check pass)

*Engineering Note on PPA:* In compliance with professional ASIC design practices, physical area ($\mu m^2$), clock frequency ($F_{max}$), and power consumption ($mW$) are not fabricated; genuine PPA signoff requires a foundry PDK (e.g., TSMC N5/N7 or SkyWater 130nm) with physical floorplanning, clock tree synthesis, and static timing analysis.

---

## 7. Quickstart & Build Instructions

### Prerequisites
- **Simulator:** Icarus Verilog (`iverilog` v13.0+)
- **Synthesis:** Yosys (`yosys` v0.69+)
- **Python:** Python 3.9+ with `cocotb` and `pytest`

### Commands
```bash
# Clone the repository
git clone https://github.com/jiya2000/int8-systolic-array-accelerator.git
cd int8-systolic-array-accelerator

# Run full verification regression (SystemVerilog + Python Reference + Cocotb)
make test

# Run only SystemVerilog testbenches
make test_sv

# Run Cocotb Python co-simulation and Python reference validation
make test_cocotb

# Run Yosys logic synthesis and generate report
make synth

# Clean temporary build and simulation artifacts
make clean
```

