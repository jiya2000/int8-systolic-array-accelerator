# Micro-Architecture Specification: INT8 Systolic Array Accelerator IP

**Document Version:** 2.0  
**Target:** High-Throughput Deep Learning Inference Accelerator IP  
**Standard:** IEEE 1800-2017 SystemVerilog (Synthesizable RTL)  
**Reference Design:** 4×4 Weight-Stationary (WS) 2D Systolic Array  

---

## 1. Executive Summary & Architectural Overview

The **INT8 Systolic Array Accelerator IP** is a synthesizable, high-efficiency digital compute block optimized for General Matrix Multiplication (GEMM) operations in deep learning inference workloads. The micro-architecture employs a **2D Weight-Stationary (WS)** dataflow that minimizes SRAM memory bandwidth by keeping weights stationary inside processing element (PE) registers while activations stream horizontally (West-to-East) and partial sums accumulate vertically (North-to-South).

### Primary Architectural Highlights:
1. **Arithmetic Precision:** Signed 8-bit two's complement inputs ($A \in [-128, 127]$, $W \in [-128, 127]$) producing exact 16-bit signed products, accumulated in 32-bit signed registers ($C \in [-2^{31}, 2^{31}-1]$) with standard modular two's complement wrap-around.
2. **Pipelined Compute Grid:** Parameterized $4 \times 4$ array of 16 identical PEs. Each PE houses stationary weight storage, signed multiplier, partial sum accumulator, and registered East/South boundary flip-flops.
3. **Streaming Interface:** AXI-Stream-inspired input and output interfaces (`tvalid`, `tready`, `tdata`, `tlast`) supporting backpressure handling and stall tolerance.
4. **Autonomous Control FSM:** 4-state controller (`IDLE`, `LOAD_WEIGHTS`, `FEED_AND_DRAIN`, `COMPLETE`) managing weight programming, activation skew scheduling, and output de-skew collection.
5. **Synthesis Compatibility:** Universal EDA tool support (Yosys, Synopsys Design Compiler, Cadence Genus) utilizing packed multidimensional arrays for clean elaboration without flattened port mismatches.

---

## 2. Top-Level IP Architecture

The top-level accelerator IP (`int8_accelerator_top`) integrates the core compute grid with memory buffering, control logic, and streaming interconnects.

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

---

## 3. Submodule Specifications

### 3.1 Processing Element (`pe.sv`)

The PE is the foundational leaf cell. Each PE contains:
- **Stationary Weight Register (`weight_reg`):** Holds an 8-bit signed weight.
- **Signed Multiplier:** Computes 16-bit signed product $P = A \times W$.
- **32-Bit Adder:** Computes $P_{ext} + c\_in$, where $P_{ext} = \text{sign\_extend}_{32}(P)$.
- **Registered Outputs:** `a_out` (passes activation East) and `c_out` (passes partial sum South).

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

#### Control Priority Hierarchy
To prevent timing glitches and ensure deterministic behavior across corner cases, the control signals adhere to strict precedence:

1. **`rst_n == 0` (Asynchronous Active-Low Reset):**
   - Clears `weight_reg <= 8'sd0`, `a_out <= 8'sd0`, `c_out <= 32'sd0`.
2. **`weight_en == 1` (Weight Configuration):**
   - Latches `weight_reg <= w_in`.
   - Datapath holds state (`a_out` and `c_out` remain frozen).
3. **`weight_en == 0 && en == 0` (Stall / Clock Gating):**
   - All registers maintain state. Zero dynamic switching activity.
4. **`weight_en == 0 && en == 1 && clr == 1` (Synchronous Clear):**
   - `c_out <= 32'sd0` (resets partial sum chain).
   - `a_out <= a_in` (activation continues flowing).
5. **`weight_en == 0 && en == 1 && clr == 0` (Active Compute):**
   - `a_out <= a_in`.
   - `c_out <= c_in + 32'(signed'(a_in) * signed'(weight_reg))`.

---

### 3.2 4×4 Systolic Array Grid (`systolic_array.sv`)

The array arranges 16 PEs in a $4 \times 4$ 2D mesh:
- Rows are indexed $r \in [0..3]$, Columns are indexed $c \in [0..3]$.
- **Activation Flow (Horizontal):**
  - $a\_wire[r][0] = a\_in[r]$ (West array inputs).
  - $a\_wire[r][c+1] = PE[r][c].a\_out$.
  - $a\_out[r] = a\_wire[r][4]$ (East array outputs).
- **Partial Sum Flow (Vertical):**
  - $c\_wire[0][c] = c\_in[c]$ (North array inputs, tied to 0 for standard GEMM).
  - $c\_wire[r+1][c] = PE[r][c].c\_out$.
  - $c\_out[c] = c\_wire[4][c]$ (South array outputs).
- **Weight Loading (Row-Broadcast):**
  - Column inputs $w\_in[c]$ connect to column $c$ across all rows.
  - One-hot enable $weight\_en[r]$ activates only row $r$ during configuration cycle $r$.

---

### 3.3 Streaming Input Buffer FIFO (`input_buffer.sv`)

The synchronous circular FIFO decouples upstream data production from downstream compute consumption:
- **Depth:** Parameterized (default 8 entries).
- **Width:** Parameterized (default 32 bits = 4 packed INT8 values).
- **Handshaking:** AXI-Stream compatible `s_valid`/`s_ready` (write port) and `m_valid`/`m_ready` (read port).
- **Simultaneous Access:** Read and write pointers advance concurrently when both interfaces handshake on the same clock edge without losing data integrity or corrupting occupancy counters.

---

### 3.4 Accelerator FSM Controller (`accelerator_controller.sv`)

The controller orchestrates operational phases via a 4-state Mealy/Moore FSM:

```
                  +--------------+
                  |     IDLE     | <-------------------------+
                  +-------+------+                           |
                          | start_compute                    |
                          v                                  |
               +----------------------+                      |
               |     LOAD_WEIGHTS     |                      |
               | (Cycles 0..3: Rows)  |                      |
               +----------+-----------+                      |
                          | 4 cycles complete                |
                          v                                  |
               +----------------------+                      |
               |    FEED_AND_DRAIN    |                      |
               | (Cycles 0..15: GEMM) |                      |
               +----------+-----------+                      |
                          | Pipeline drain finished          |
                          v                                  |
               +----------------------+                      |
               |       COMPLETE       | ---------------------+
               +----------------------+   m_axis stream done
```

- **`IDLE` (State `00`):** Ready for weight configuration or activation streaming.
- **`LOAD_WEIGHTS` (State `01`):** Steps `cycle_cnt` from 0 to 3, asserting one-hot $weight\_en[r]$ sequentially.
- **`FEED_AND_DRAIN` (State `10`):** Compute phase. Enables the systolic array datapath (`array_en = 1`) for 16 cycles while tracking activation feed and accumulation drain.
- **`COMPLETE` (State `11`):** Asserts `ctrl_done`, transitioning to output streaming.

---

## 4. Systolic Timing & Skewing Equations

In a 2D weight-stationary systolic array, compute synchronization requires deliberate spatial data skewing.

### 4.1 Activation Feeding Schedule
To ensure activation row $A[i]$ meets the correct stationary weight row $B[k]$, input rows must be staggered:
$$\text{Arrival cycle of } A[i][k] \text{ at array row } k = i + k$$
Since row $k$ receives $A[i][k]$, row 0 receives data with zero delay, row 1 is delayed by 1 cycle, row 2 by 2 cycles, and row 3 by 3 cycles.
- Active feeding duration spans 7 clock cycles ($t \in [0..6]$).
- After cycle 6, inputs are zero-padded to allow partial sums to flush South.

### 4.2 Output Retirement Schedule
The partial sum for element $C[i][j] = \sum_{k=0}^{3} A[i][k] \times B[k][j]$ accumulates down column $j$:
- Row 0 calculates $A[i][0] \times B[0][j]$ at cycle $i + 0 + j$.
- Row 1 accumulates $A[i][1] \times B[1][j]$ at cycle $i + 1 + j$.
- Row 2 accumulates $A[i][2] \times B[2][j]$ at cycle $i + 2 + j$.
- Row 3 finalizes $C[i][j]$ at cycle $i + 3 + j$.
- Registered exit at South port occurs at cycle:
$$t_{\text{retire}}(i, j) = i + 4 + j$$

#### Cycle Retirement Matrix for $4 \times 4$ Array:
| Row $i$ \ Col $j$ | Col 0 | Col 1 | Col 2 | Col 3 |
| :---: | :---: | :---: | :---: | :---: |
| **Row 0** | Cycle 4 | Cycle 5 | Cycle 6 | Cycle 7 |
| **Row 1** | Cycle 5 | Cycle 6 | Cycle 7 | Cycle 8 |
| **Row 2** | Cycle 6 | Cycle 7 | Cycle 8 | Cycle 9 |
| **Row 3** | Cycle 7 | Cycle 8 | Cycle 9 | Cycle 10 |

The de-skewing logic inside `int8_accelerator_top` samples South port $c\_out[j]$ exactly when `feed_cycle == (i + 4 + j)`, capturing all 16 results into the unskewed result matrix register `result_matrix[i][j]`.

---

## 5. Streaming Output Protocol & Backpressure

Output streaming begins upon completion of compute (`ctrl_done = 1`):
1. Accelerator asserts `m_axis_tvalid = 1`.
2. Output matrix rows are streamed sequentially ($r \in [0..3]$).
3. On the final row ($r = 3$), `m_axis_tlast = 1` asserts.
4. **Backpressure Compliance:** If the downstream receiver de-asserts `m_axis_tready`, the output engine freezes `out_stream_idx`, holding valid data stable until the receiver resumes ready assertion.

---

## 6. Synthesis Design Rules & Port Convention

To prevent port compatibility issues across EDA synthesis tools:
- **Packed Array Ports:** Replaced unpacked arrays (`[7:0] data [3:0]`) with packed multi-dimensional vectors (`[3:0][7:0] data`).
- **Generate Blocks for Part Selects:** Replaced procedural loops with `genvar` generate constructs for multidimensional register slicing, guaranteeing 100% compatibility across Icarus Verilog and Yosys.
