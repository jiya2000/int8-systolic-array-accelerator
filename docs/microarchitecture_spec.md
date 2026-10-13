# Micro-Architecture Specification: INT8 Systolic Array Processing Element (PE)

**Version:** 1.1  
**Target:** High-Throughput Deep Learning Inference Compute Unit (Stage 1)  
**Implementation Language:** Synthesizable SystemVerilog (IEEE 1800-2017)

---

## 1. Architectural Overview & Dataflow

The **Processing Element (PE)** is the fundamental compute tile of a 2D **Weight-Stationary (WS)** Systolic Array. In deep learning inference workloads (e.g., GEMM, convolution, projection layers), stationary weights maximize energy efficiency by eliminating repetitive weight loads from SRAM or global memory.

```
                      Weight Load (Config Phase)
                            w_in [7:0]
                                |
                                v
               +----------------------------------+
               |        Stationary Weight         |
               |          Register (W)            |
               +----------------+-----------------+
                                |
                                v
Activation In  |---> [ Signed 8x8 Multiplier ]     |
 a_in [7:0]    |                  |                |
(West Port)    |            16-bit Product         |
               |                  |                |
               |                  v                |
Partial Sum In |---> [ 32-bit Signed Adder ]       |---> Partial Sum Out
 c_in [31:0]   |                  |                |      c_out [31:0]
(North Port)   |         32-bit Accumulator        |     (South Port)
               |                  |                |      (Registered)
               |                  v                |
               |         [ Output Registers ]      |
               +------------------+---------------+
                                  |
                                  v
                            Activation Out
                              a_out [7:0]
                              (East Port)
                              (Registered)
```

### Key Design Principles:
1. **Signed Two's Complement Arithmetic:** Inputs $A$ and $W$ are 8-bit signed values (`signed [7:0]`), ranging from $-128$ to $+127$.
2. **Product Precision:**
   - An $8 \times 8$ signed multiplication produces a 16-bit signed product (`signed [15:0]`).
   - Extreme negative corner case: $(-128) \times (-128) = +16,384$ (`0x4000`), which fits within a 16-bit signed integer.
3. **Partial Sum Propagation:**
   - $c\_out$ is a **registered partial-sum result passed to the south neighbor**, not a feedback accumulator internal to the PE.
   - The product is sign-extended to 32 bits and added to $c\_in$.
   - **Overflow Semantics:** 32-bit accumulation wraps around in standard two's complement arithmetic unless saturation is deliberately added.
4. **Pipelining & Systolic Propagation:**
   - Both $a\_out$ (moving East) and $c\_out$ (moving South) are strictly registered at the positive clock edge to break combinational paths and ensure high $F_{max}$.

---

## 2. Port Definitions

| Signal Name | Direction | Width | Type | Description |
| :--- | :---: | :---: | :---: | :--- |
| `clk` | Input | 1 | Clock | Master positive-edge clock |
| `rst_n` | Input | 1 | Async Reset | Active-low asynchronous reset |
| `weight_en` | Input | 1 | Control | Stationary weight write enable (Highest active priority) |
| `en` | Input | 1 | Control | Compute datapath enable |
| `clr` | Input | 1 | Control | Synchronous accumulator clear (overrides accumulation when computing) |
| `w_in` | Input | 8 | Signed | Weight data input (latched during weight configuration) |
| `a_in` | Input | 8 | Signed | Activation input from West neighbor |
| `c_in` | Input | 32 | Signed | Partial sum accumulation input from North neighbor |
| `a_out` | Output | 8 | Signed | Registered activation passed to East neighbor |
| `c_out` | Output | 32 | Signed | Registered partial sum passed to South neighbor |

---

## 3. Explicit Control Priority & Register Behavior

To guarantee deterministic, glitch-free behavior across all corner cases, the PE sequential registers strictly adhere to the following control priority hierarchy:

| Operating Condition | `weight_reg` | `a_out` | `c_out` | Functional Description |
| :--- | :---: | :---: | :---: | :--- |
| **`rst_n == 0`** | `8'sd0` | `8'sd0` | `32'sd0` | Asynchronous power-on / hardware reset |
| **`weight_en == 1`** | **Load `w_in`** | **Hold** | **Hold** | Weight configuration phase (prioritized over compute) |
| **`weight_en == 0, en == 0`** | Hold | Hold | Hold | Datapath stall / idle (zero dynamic switching) |
| **`weight_en == 0, en == 1, clr == 1`** | Hold | Pass `a_in` | **Set to `32'sd0`** | Synchronous clear (resets partial sum chain) |
| **`weight_en == 0, en == 1, clr == 0`** | Hold | Pass `a_in` | **`c_in + (a_in * weight_reg)`** | Normal active MAC operation |

### Priority Rationales:
1. **Weight Configuration Isolation:** Asserting `weight_en` halts datapath progression (`a_out` and `c_out` hold). This cleanly decouples the array programming phase from execution.
2. **Synchronous Clear Definition:** When computing (`en = 1`), asserting `clr = 1` forces $c\_out$ to `0` at the rising clock edge while passing $a\_in \rightarrow a\_out$, enabling systolic pipeline flushing without losing activation alignment.
3. **Datapath Stalling:** When `en = 0`, all outputs hold their previous values, suppressing dynamic switching activity.

---

## 4. Arithmetic Corner Cases to Verify

| Test Case | $a\_in$ | $w\_in$ | $c\_in$ | Expected $c\_out$ | Verification Objective |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **Zero Weight** | $50$ | $0$ | $25$ | $25$ | Multiplication by zero |
| **Zero Activation** | $0$ | $-128$ | $100$ | $100$ | Zero operand pass-through |
| **Pos $\times$ Pos** | $+10$ | $+5$ | $0$ | $+50$ | Standard positive quadrant |
| **Pos $\times$ Neg** | $+12$ | $-4$ | $+10$ | $-38$ | Mixed quadrant multiplication |
| **Neg $\times$ Neg** | $-7$ | $-8$ | $-20$ | $+36$ | Negative product cancellation |
| **Max Positive Boundary** | $+127$ | $+127$ | $0$ | $+16,129$ | Positive saturation limits |
| **Extreme Two's Complement** | $-128$ | $-128$ | $0$ | $+16,384$ | Two's-complement $-2^{7}$ edge case |
| **Mixed Extreme** | $+127$ | $-128$ | $0$ | $-16,256$ | Negative boundary limit |
| **Two's Complement Wrap** | $+10$ | $+10$ | `0x7FFFFFF0` | `0x80000054` | 32-bit standard modular overflow |
