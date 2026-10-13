# Verification Plan: INT8 Systolic Array Accelerator IP

**Document Version:** 2.0  
**Target:** 4×4 Weight-Stationary INT8 Systolic Array Accelerator  
**Methodology:** Dual-Flow Verification (SystemVerilog Self-Checking Testbenches + Cocotb Python Co-Simulation)  
**Tools:** Icarus Verilog v13.0, Cocotb v2.1.0, Python 3.9+  

---

## 1. Verification Strategy & Objectives

The primary objective is to verify functional correctness, cycle-accurate timing, mathematical precision, and interface robustness of the INT8 Systolic Array Accelerator IP across all operational corner cases.

### Verification Flow Architecture:
```
+--------------------------------------------------------------------------------+
|                             Verification Flow Architecture                     |
|                                                                                |
|  +---------------------------+                +-----------------------------+  |
|  | SystemVerilog Testbenches |                | Cocotb Python Co-Simulation |  |
|  | (IEEE 1800-2017)          |                | (cocotb v2.1.0 + GPI/VPI)   |  |
|  +-------------+-------------+                +--------------+--------------+  |
|                |                                             |                 |
|                v                                             v                 |
|  +---------------------------+                +-----------------------------+  |
|  | Directed & Randomized     |                | Bit-Exact Reference Model   |  |
|  | - tb_pe.sv (25 tests)     |                | - reference_model.py        |  |
|  | - tb_systolic_array.sv    |                | - test_pe.py (1000 vectors) |  |
|  | - tb_input_buffer.sv      |                | - golden_model.py           |  |
|  | - tb_accelerator_top.sv   |                +-----------------------------+  |
|  | - tb_randomized.sv (100m) |                               |                 |
|  +-------------+-------------+                               v                 |
|                \                                            /                  |
|                 \                                          /                   |
|                  v                                        v                    |
|        +--------------------------------------------------------+              |
|        |           Icarus Verilog Simulator (iverilog / vvp)    |              |
|        +---------------------------+----------------------------+              |
|                                    |                                           |
|                                    v                                           |
|        +--------------------------------------------------------+              |
|        | Pass/Fail Regression Report & VCD Waveform Generation  |              |
|        +--------------------------------------------------------+              |
+--------------------------------------------------------------------------------+
```

---

## 2. Test Hierarchy & Testbench Suite

| Testbench File | Target Module | Scope | Transactions | Matrix Elements Checked | Assertions / Protocol Checks | Pass Criteria |
| :--- | :--- | :--- | :---: | :---: | :---: | :--- |
| `tb/tb_pe.sv` | `pe.sv` | Processing Element Directed Unit Tests | 25 steps | 25 scalar values | 25 assertions | All signed arithmetic & control priorities match expected |
| `tb/test_pe.py` | `pe.sv` | Cocotb Random & Directed Verification | 1,008 trans | 1,008 scalar values | 1,008 assertions | 1,000 randomized transactions match Python bit-exact model |
| `tb/tb_systolic_array.sv` | `systolic_array.sv` | 4×4 Core Grid GEMM Test | 1 GEMM | 16 elements | 16 assertions | All 16 output matrix elements match golden matrix |
| `tb/tb_input_buffer.sv` | `input_buffer.sv` | FIFO Handshake & Backpressure (Standalone IP) | 24 words | 8 FIFO entries | 14 assertions | Zero data corruption under full, empty, backpressure stalls |
| `tb/tb_accelerator_top.sv` | `int8_accelerator_top.sv` | Top-Level Integration, Stalls & Extremes | 6 GEMMs (T1–T5) | 96 elements | 130 assertions | End-to-end streaming GEMM + 4-cycle stall resilience + input backpressure + extremes |
| `tb/tb_accelerator_randomized.sv` | `int8_accelerator_top.sv` | 100-Matrix Stress Regression | 100 GEMMs | 1,600 elements | 1,700 assertions | 100 random 4×4 GEMMs (1,600 elements) computed bit-accurately |
| `tb/reference_model.py` | Python Reference | Independent Integer Reference Model | 513 GEMMs | 8,016 elements | 8,016 element checks | 8 phases including 500 GEMMs, signed corners, and modulo arithmetic |
| `sim/golden_model.py` | Python Reference | Golden Architecture Reference Suite | Directed suites | All elements | Directed validations | Verification of timing skew, de-skew, and signed INT8 math |

---

## 3. Test Coverage Matrix & Corner Cases

### 3.1 Arithmetic Corner Cases
- **Negative Extreme ($(-128) \times (-128)$):** Tests that $8\text{'sd}-128 \times 8\text{'sd}-128 = +16,384$ (`16'h4000`), properly sign-extended to 32 bits without sign-bit corruption.
- **Positive Extreme ($(+127) \times (+127)$):** Tests $127 \times 127 = +16,129$ (`16'h3F01`).
- **Mixed Extremes ($(+127) \times (-128)$):** Tests $127 \times (-128) = -16,256$ (`32'hFFFFC080`).
- **Zero Operands ($0 \times W$, $A \times 0$):** Verifies partial-sum bypass and multiplier suppression.
- **Signed 32-bit Accumulator Wraparound:** Tests that accumulating past $+2^{31}-1$ wraps predictably modulo $2^{32}$ according to two's complement arithmetic rules without causing simulation hangs or assertion errors.

### 3.2 Control Priority & State Invariance
- **Asynchronous Reset (`rst_n = 0`):** Immediate assertion forces `weight_reg = 0`, `a_out = 0`, `c_out = 0`.
- **Weight Write Priority (`weight_en = 1`):** Overrides `en`. Latches new weight while freezing `a_out` and `c_out`.
- **Datapath Stall (`en = 0`):** Freezes all output registers.
- **Synchronous Clear (`clr = 1`):** Resets `c_out` to 0 on the rising clock edge while passing `a_in` to `a_out`.
- **Weight Loading Flow Control:** One-hot `weight_en` asserted strictly during handshake cycles (`valid && ready`), auto-advancing row index, asserting `weights_loaded` upon 4 rows, and asserting backpressure (`ready = 0`) while busy.

### 3.3 Streaming & Backpressure Robustness
- **FIFO Boundary Conditions:** Write to full (dropped/refused), read from empty (suppressed), concurrent read/write at full and empty thresholds.
- **Downstream Backpressure (`m_axis_tready = 0`):**
  - Stalls output streaming for 4 consecutive clock cycles mid-stream (Row 1) and end-of-packet (Row 3 with `tlast = 1`).
  - Verifies that data remains stable on `m_axis_tdata`, `m_axis_tvalid`, and `m_axis_tlast` without skipping rows or duplicating transfers.
- **Input Backpressure (`s_axis_tready = 0`):**
  - Asserts backpressure while accelerator is busy. Arriving data is held stable until accelerator completes compute, verifying zero dropped or corrupted words.
- **Back-to-Back GEMM & Dynamic Reconfiguration:**
  - Validates sequential GEMMs with persistent weights, followed by dynamic reprogramming with an identity matrix.

---

## 4. Python Reference Models

Two bit-exact Python reference models are maintained:
1. `tb/reference_model.py`: Used in Python verification regression. Implements `int8_clamp` and `int32_clamp` functions that reproduce signed two's complement wrapping modulo $2^{32}$, verified against 500 randomized GEMMs (8,000 elements) and signed boundary conditions.
2. `sim/golden_model.py`: Provides software matrix multiplication reference generators, skew/de-skew timing simulators, and test vector generators.

---

## 5. Acceptance Criteria

- **Functional Regression:** 100% test pass rate across all SystemVerilog and Python test suites. Zero failures.
- **Warning Count:** Zero synthesis latch warnings, zero port width mismatch warnings (`CHECK pass: Found and reported 0 problems`).
- **Reproducibility:** Single-command execution via `make test` completes cleanly and non-interactively.
