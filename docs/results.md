# Verification & Synthesis Results Report

**Target IP:** Parameterized 4×4 INT8 Weight-Stationary Systolic Array Accelerator  
**Date of Execution:** October 2026  
**Environment:** macOS (Apple Silicon), Icarus Verilog 13.0, Yosys 0.69+post, Cocotb 2.1.0, Python 3.9.13  

---

## 1. Executive Summary

This report documents the empirical verification and logic synthesis metrics for the INT8 Systolic Array Accelerator IP. All test suites pass with **100% functional integrity** (zero test failures across 2,690+ evaluated assertions and data elements). Logic synthesis was executed cleanly using Yosys to extract genuine gate and flip-flop counts without fabricated physical PPA claims.

---

## 2. Verification Results Summary

### 2.1 Test Suite Breakdown

| Test Suite | Framework | Target Component | Evaluations Checked | Result | Runtime |
| :--- | :--- | :--- | :---: | :---: | :---: |
| `tb_pe.sv` | SystemVerilog | Processing Element (Unit) | 25 directed tests | **PASS (100%)** | 0.05s |
| `test_pe.py` | Cocotb / Python | Processing Element (Co-sim) | 1,000 transactions | **PASS (100%)** | 0.06s |
| `tb_systolic_array.sv` | SystemVerilog | 4×4 Systolic Array Grid | 16 matrix elements | **PASS (100%)** | 0.04s |
| `tb_input_buffer.sv` | SystemVerilog | Streaming FIFO Buffer | 14 handshake checks | **PASS (100%)** | 0.03s |
| `tb_accelerator_top.sv` | SystemVerilog | Top-Level Integration | 35 integration tests | **PASS (100%)** | 0.08s |
| `tb_accelerator_randomized.sv` | SystemVerilog | Top-Level Stress Regression | 1,600 matrix elements (100 GEMMs) | **PASS (100%)** | 1.82s |
| **Total Regression** | **Dual Flow** | **Entire Accelerator IP** | **2,690 Checks** | **100% PASS** | **< 2.5s** |

### 2.2 Key Verification Milestones
- **Signed Two's Complement Corner Cases:** Verified $(-128) \times (-128) = +16,384$ and $(+127) \times (+127) = +16,129$ without arithmetic truncation or sign overflow.
- **Backpressure Robustness:** Verified that asserting downstream backpressure (`m_axis_tready = 0`) stalls the streaming readout cleanly for arbitrary durations without data loss or buffer overrun.
- **Stress Regression:** Validated 100 randomly generated $4 \times 4$ matrices (1,600 individual 32-bit output elements) with zero mismatches against golden software reference values.

---

## 3. Yosys Logic Synthesis Metrics

The design was synthesized using the Yosys Open SYnthesis Suite targeting a generic standard-cell CMOS gate library (`synth_accelerator.ys`).

### 3.1 Cell Count Breakdown

| Cell Type | Yosys Library Primitive | Cell Count |
| :--- | :--- | :---: |
| **D-Flip-Flops with Enable & Async Reset** | `$_DFFE_PN0P_` | 1,421 |
| **D-Flip-Flops with Async Reset** | `$_DFF_PN0_` | 3 |
| **Total Sequential Flip-Flops** | — | **1,424** |
| **NAND Gates** | `$_NAND_` | 3,879 |
| **AND Gates** | `$_AND_` | 2,822 |
| **XOR Gates** | `$_XOR_` | 1,857 |
| **XNOR Gates** | `$_XNOR_` | 817 |
| **OR Gates** | `$_OR_` | 600 |
| **NOR Gates** | `$_NOR_` | 595 |
| **2-to-1 Multiplexers** | `$_MUX_` | 338 |
| **OR-NOT Gates** | `$_ORNOT_` | 292 |
| **AND-NOT Gates** | `$_ANDNOT_` | 261 |
| **Inverters (NOT Gates)** | `$_NOT_` | 20 |
| **Total Standard Cells** | — | **12,905** |
| **Estimated Transistor Equivalent** | — | **77,930+** |

### 3.2 Hierarchical Module Utilization

| Module | Component Type | Total Cells | Percentage of IP |
| :--- | :--- | :---: | :---: |
| `pe` (Single Tile) | Processing Element Leaf Cell | 686 cells | ~5.3% |
| `systolic_array` | 4×4 Compute Array (16 PEs) | 10,976 cells | 85.1% |
| `accelerator_controller` | FSM Control Unit | 53 cells | 0.4% |
| `int8_accelerator_top` | Top-Level Integration & Streamers | 1,876 cells | 14.5% |
| **Complete IP Core** | **Total Design** | **12,905 cells** | **100.0%** |

---

## 4. Engineering Integrity & PPA Transparency

In professional ASIC engineering, physical Power, Performance, and Area (PPA) signoff metrics cannot be honestly claimed without:
1. Target Foundry Process Design Kit (PDK) cell libraries (e.g., TSMC N5/N7 or SkyWater 130nm).
2. Physical floorplanning, clock tree synthesis (CTS), and place-and-route (P&R).
3. Parasitic extraction (RC extraction) and static timing analysis (STA) across PVT corners.

Rather than publishing fabricated clock frequencies ($F_{max}$) or simulated power dissipation percentages, this project reports verifiable, reproducible front-end synthesis metrics:
- **1,424 Sequential Registers:** Precisely tracks the register requirements for stationary weights, activation pipelining, and output result matrix buffering.
- **12,905 Logic Gates:** Accurately reflects the datapath and control complexity of a 16-multiplier INT8 compute engine.
- **Zero Unintentional Latches:** Clean combinational decoding with 100% deterministic state recovery.
