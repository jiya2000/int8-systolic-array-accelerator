# INT8 Systolic Array Accelerator IP

[![Hardware Verification](https://img.shields.io/badge/Verification-100%25%20PASS%20(2%2C690%20Checks)-brightgreen)](#verification--test-results)
[![Synthesis](https://img.shields.io/badge/Yosys%20Synthesis-12%2C905%20Cells%20%7C%201%2C424%20DFFs-blue)](#logic-synthesis--gate-level-metrics)
[![Language](https://img.shields.io/badge/RTL-SystemVerilog%20IEEE%201800--2017-orange)](#system-architecture)
[![Verification Flow](https://img.shields.io/badge/Testbench-SV%20%2B%20Cocotb%20Python-yellow)](#verification-methodology)

A complete, production-grade, synthesizable **4×4 Weight-Stationary (WS) INT8 Systolic Array Accelerator IP** implemented in SystemVerilog. Designed for high-efficiency General Matrix Multiplication (GEMM) acceleration in deep learning inference workloads.

This project features synthesizable RTL, an AXI-Stream-inspired input/output streaming protocol with backpressure handling, an autonomous FSM controller, dual-flow verification (SystemVerilog + Cocotb Python co-simulation), and automated Yosys gate-level logic synthesis.

---

## 1. Architectural Highlights

- **Weight-Stationary Dataflow:** Maximizes energy efficiency by holding weights in stationary processing element registers during compute, eliminating redundant SRAM accesses.
- **Signed Two's Complement Arithmetic:** 
  - Input operands: Signed 8-bit ($A, W \in [-128, 127]$).
  - Multiplier precision: Exact 16-bit signed products ($P = A \times W$). Handles extreme negative corner cases without overflow ($(-128) \times (-128) = +16,384$).
  - Accumulation: 32-bit signed accumulators ($C \in [-2^{31}, 2^{31}-1]$) with deterministic two's complement wraparound.
- **Deterministic Control Priority:** Strict control precedence (`rst_n` > `weight_en` > `en` > `clr` > stall) eliminates race conditions and ensures glitch-free pipeline flushing.
- **AXI-Stream Compliant Streaming:** Master/slave streaming interfaces with full backpressure tolerance (`tvalid`, `tready`, `tdata`, `tlast`).
- **Autonomous Controller:** 4-state FSM (`IDLE`, `LOAD_WEIGHTS`, `FEED_AND_DRAIN`, `COMPLETE`) handling weight configuration, activation skew scheduling, and output collection.
- **Universal EDA Portability:** Implemented with packed multi-dimensional array ports and `genvar` generate constructs, eliminating array slicing synthesis errors across Icarus Verilog, Yosys, and commercial ASIC toolchains.

---

## 2. System Architecture

```
                    +-------------------------------------------------------------+
                    |                 int8_accelerator_top                        |
                    |                                                             |
s_weight_data [3:0] |===> [ Weight Configuration Port ]                           |
s_weight_valid/ready|       - Row-by-row stationary weight load                   |
                    |       - Decoded one-hot enables per PE row                  |
                    |                                                             |
                    |     +-------------------------------------------------+     |
s_axis_tdata [3:0]  |===> | Activation Input Buffer (4x4 Matrix A)          |     |
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
                    |     | Output Streaming Engine (AXI-Stream Slave Ready)|     |
m_axis_tvalid/ready | <===|   - Row-by-row readout                          |     |
m_axis_tdata [3:0]  |     |   - Supports downstream stalls and backpressure |     |
m_axis_tlast        |     +-------------------------------------------------+     |
                    |                                                             |
                    |  +-------------------------------------------------------+  |
clk, rst_n          |  | FSM Accelerator Controller                            |  |
busy, done          |  | Manages compute cycle count, enables, and status flags |  |
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
   Element $C[0][0]$ exits at cycle 4; final element $C[3][3]$ exits at cycle 10. De-skewing registers latch each partial sum at its exact retirement cycle.

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
│   ├── input_buffer.sv             # Synchronous FIFO with backpressure handshaking
│   ├── accelerator_controller.sv   # 4-state FSM controller
│   └── int8_accelerator_top.sv     # Top-level IP integration with skew/de-skew logic
├── tb/
│   ├── tb_pe.sv                    # PE exhaustive directed unit testbench (25 tests)
│   ├── test_pe.py                  # Cocotb Python randomized testbench (1,000 vectors)
│   ├── Makefile.pe                 # Cocotb test runner Makefile
│   ├── reference_model.py          # Bit-exact Python model with signed modulo 2^32 math
│   ├── tb_systolic_array.sv        # 4x4 array GEMM verification testbench
│   ├── tb_input_buffer.sv          # FIFO handshake & backpressure testbench
│   ├── tb_accelerator_top.sv       # Top-level streaming & stall testbench (35 tests)
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

The IP is verified using a dual-track methodology combining IEEE 1800-2017 SystemVerilog self-checking testbenches and Cocotb Python co-simulation.

| Test Suite | Scope | Target | Checks | Pass Rate |
| :--- | :--- | :--- | :---: | :---: |
| `sim_pe` | Directed Unit Test | `pe.sv` | 25 tests | **100% PASS** |
| `test_cocotb` | Randomized Co-Simulation | `pe.sv` | 1,000 vectors | **100% PASS** |
| `sim_array` | Core Compute Grid | `systolic_array.sv` | 16 elements | **100% PASS** |
| `sim_fifo` | Buffer Handshake | `input_buffer.sv` | 14 tests | **100% PASS** |
| `sim_top` | Integration & Stalls | `int8_accelerator_top.sv` | 35 tests | **100% PASS** |
| `sim_randomized` | 100-Matrix Stress | `int8_accelerator_top.sv` | 1,600 elements | **100% PASS** |
| **Total** | **Master Regression** | **Entire Core** | **2,690 Checks** | **100% PASS** |

---

## 6. Logic Synthesis & Gate-Level Metrics

Synthesized using **Yosys 0.69+post** targeting a generic standard-cell CMOS technology library:

- **Total Standard Cells:** 12,905 gates
- **Sequential Flip-Flops:** 1,424 DFFs (`$_DFFE_PN0P_` / `$_DFF_PN0_`)
- **Combinational Logic:**
  - 3,879 NAND gates
  - 2,822 AND gates
  - 1,857 XOR gates
  - 817 XNOR gates
  - 600 OR gates
  - 595 NOR gates
  - 338 Multiplexers (`$_MUX_`)
  - 292 ORNOT gates
  - 261 ANDNOT gates
  - 20 Inverters
- **Estimated Transistor Equivalent:** 77,930+ transistors
- **Latch Count:** 0 (Zero unintended latches)

*Engineering Note on PPA:* In compliance with professional ASIC design practices, physical area ($\mu m^2$), clock frequency ($F_{max}$), and power consumption ($mW$) are not fabricated; genuine PPA signoff requires a foundry PDK (e.g., TSMC N5/N7) with physical layout, clock tree synthesis, and static timing analysis.

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

# Run full verification regression (SystemVerilog + Cocotb)
make test

# Run only SystemVerilog testbenches
make test_sv

# Run Cocotb Python co-simulation (1,000 randomized vectors)
make test_cocotb

# Run Yosys logic synthesis and generate report
make synth

# Clean temporary build and simulation artifacts
make clean
```
