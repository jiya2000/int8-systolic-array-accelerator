"""
test_pe.py
Cocotb-driven verification for the INT8 Processing Element (PE).
Verifies reset, weight configuration, clear semantics, and runs 1,000+ randomized vectors.
"""
import cocotb
from cocotb.triggers import RisingEdge, FallingEdge
from cocotb.clock import Clock
import random

def int8_clamp(val: int) -> int:
    val = val & 0xFF
    return val - 256 if val >= 128 else val

def int32_clamp(val: int) -> int:
    val = val & 0xFFFFFFFF
    return val - 0x100000000 if val >= 0x80000000 else val

def get_signed(signal, width=8) -> int:
    raw = int(signal.value)
    if width == 8:
        return int8_clamp(raw)
    elif width == 32:
        return int32_clamp(raw)
    return raw

@cocotb.test()
async def test_pe_control_and_randomized(dut):
    """Exhaustive test for Processing Element using Cocotb."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    # 1. Asynchronous Reset
    dut.rst_n.value = 0
    dut.weight_en.value = 0
    dut.en.value = 0
    dut.clr.value = 0
    dut.w_in.value = 0
    dut.a_in.value = 0
    dut.c_in.value = 0

    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await FallingEdge(dut.clk)

    assert get_signed(dut.a_out, 8) == 0, f"Expected a_out=0 after reset, got {dut.a_out.value}"
    assert get_signed(dut.c_out, 32) == 0, f"Expected c_out=0 after reset, got {dut.c_out.value}"
    dut._log.info("Reset test passed.")

    # 2. Directed Extreme Cases
    test_cases = [
        # (weight, a_in, c_in, exp_a, exp_c, desc)
        (5, 10, 20, 10, 70, "Pos x Pos"),
        (-6, 8, 100, 8, 52, "Pos x Neg"),
        (-7, -8, -40, -8, 16, "Neg x Neg"),
        (127, 127, 0, 127, 16129, "Max Pos (+127 * +127)"),
        (-128, -128, 0, -128, 16384, "Extreme Neg (-128 * -128)"),
        (-128, 127, 0, 127, -16256, "Mixed Extreme (-128 * 127)"),
        (0, 50, 25, 50, 25, "Zero Weight"),
        (50, 0, 25, 0, 25, "Zero Activation")
    ]

    for w, a, c, exp_a, exp_c, desc in test_cases:
        # Load weight
        dut.weight_en.value = 1
        dut.en.value = 0
        dut.w_in.value = w
        await FallingEdge(dut.clk)

        dut.weight_en.value = 0
        dut.en.value = 1
        dut.a_in.value = a
        dut.c_in.value = c
        dut.clr.value = 0

        await FallingEdge(dut.clk)
        val_a = get_signed(dut.a_out, 8)
        val_c = get_signed(dut.c_out, 32)
        assert val_a == exp_a, f"{desc}: a_out mismatch got {val_a}, exp {exp_a}"
        assert val_c == exp_c, f"{desc}: c_out mismatch got {val_c}, exp {exp_c}"

    dut._log.info("All 8 directed test cases passed.")

    # 3. Synchronous Clear Test
    dut.clr.value = 1
    dut.a_in.value = 42
    dut.c_in.value = 999
    await FallingEdge(dut.clk)
    val_a = get_signed(dut.a_out, 8)
    val_c = get_signed(dut.c_out, 32)
    assert val_c == 0, f"Clear failed: c_out expected 0, got {val_c}"
    assert val_a == 42, f"Clear failed: a_out expected 42, got {val_a}"
    dut.clr.value = 0

    # 4. 1,000 Randomized Transactions
    random.seed(42)
    dut._log.info("Starting 1,000 randomized transactions...")

    running_weight = 10
    dut.weight_en.value = 1
    dut.w_in.value = running_weight
    await FallingEdge(dut.clk)
    dut.weight_en.value = 0

    for i in range(1000):
        # 10% chance to update weight
        if random.random() < 0.10:
            running_weight = random.randint(-128, 127)
            dut.weight_en.value = 1
            dut.w_in.value = running_weight
            await FallingEdge(dut.clk)
            dut.weight_en.value = 0

        rand_a = random.randint(-128, 127)
        rand_c = random.randint(-1000000, 1000000)

        dut.en.value = 1
        dut.a_in.value = rand_a
        dut.c_in.value = rand_c

        await FallingEdge(dut.clk)

        expected_prod = int8_clamp(rand_a) * int8_clamp(running_weight)
        expected_c = int32_clamp(int32_clamp(rand_c) + expected_prod)

        val_a = get_signed(dut.a_out, 8)
        val_c = get_signed(dut.c_out, 32)

        assert val_a == rand_a, f"Iter {i}: a_out mismatch got {val_a}, exp {rand_a}"
        assert val_c == expected_c, f"Iter {i}: c_out mismatch got {val_c}, exp {expected_c}"

    dut._log.info(">>> 1,000 Randomized Transactions Completed with 100% Integrity! <<<")
