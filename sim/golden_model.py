#!/usr/bin/env python3
"""
golden_model.py
Bit-exact software reference model for the INT8 Processing Element (PE).
Enforces exact hardware control priority:
  1. Asynchronous Reset (rst_n == 0)
  2. Weight Configuration (weight_en == 1, holds datapath)
  3. Datapath Stall (weight_en == 0, en == 0, holds state)
  4. Synchronous Clear (weight_en == 0, en == 1, clr == 1, c_out = 0)
  5. Compute MAC (weight_en == 0, en == 1, clr == 0, c_out = c_in + a*w)
"""

def int8_clamp(val: int) -> int:
    """Clamps to signed 8-bit range [-128, 127] in two's complement."""
    val = val & 0xFF
    return val - 256 if val >= 128 else val

def int32_clamp(val: int) -> int:
    """Clamps to signed 32-bit range [-2^31, 2^31 - 1] in two's complement."""
    val = val & 0xFFFFFFFF
    return val - 0x100000000 if val >= 0x80000000 else val

class PEGoldenModel:
    def __init__(self):
        self.reset()

    def reset(self):
        self.weight_reg = 0
        self.a_out = 0
        self.c_out = 0

    def step(self,
             rst_n: bool,
             weight_en: bool,
             en: bool,
             clr: bool,
             w_in: int,
             a_in: int,
             c_in: int) -> tuple[int, int]:
        """
        Executes one clock cycle step adhering to exact control priority.
        Returns: (a_out, c_out)
        """
        if not rst_n:
            self.reset()
            return self.a_out, self.c_out

        if weight_en:
            # Condition 2: Weight Configuration Phase (holds datapath)
            self.weight_reg = int8_clamp(w_in)
            return self.a_out, self.c_out

        if not en:
            # Condition 3: Datapath Stall (holds state)
            return self.a_out, self.c_out

        # Compute Phase (en == 1)
        a_signed = int8_clamp(a_in)
        c_signed = int32_clamp(c_in)

        if clr:
            # Condition 4: Synchronous Clear
            self.a_out = a_signed
            self.c_out = 0
        else:
            # Condition 5: Normal MAC
            product = a_signed * self.weight_reg
            self.a_out = a_signed
            self.c_out = int32_clamp(c_signed + product)

        return self.a_out, self.c_out


def run_comprehensive_validation():
    print("================================================================")
    print(" Running Comprehensive Python Golden Model Self-Validation")
    print("================================================================")
    pe = PEGoldenModel()

    # 1. Reset
    a, c = pe.step(rst_n=False, weight_en=False, en=False, clr=False, w_in=0, a_in=0, c_in=0)
    assert (a, c) == (0, 0), "Reset failure"

    # 2. Weight load priority over compute
    a, c = pe.step(rst_n=True, weight_en=True, en=True, clr=False, w_in=10, a_in=25, c_in=500)
    assert (a, c) == (0, 0), "weight_en priority failure"
    assert pe.weight_reg == 10, "Weight load failure"

    # 3. Compute Pos x Pos
    a, c = pe.step(rst_n=True, weight_en=False, en=True, clr=False, w_in=0, a_in=5, c_in=20)
    assert (a, c) == (5, 70), f"Pos x Pos mismatch: got ({a}, {c})"

    # 4. Clear Priority
    a, c = pe.step(rst_n=True, weight_en=False, en=True, clr=True, w_in=0, a_in=42, c_in=999)
    assert (a, c) == (42, 0), f"Clear mismatch: got ({a}, {c})"

    # 5. Extreme Two's Complement: -128 * -128
    pe.step(rst_n=True, weight_en=True, en=False, clr=False, w_in=-128, a_in=0, c_in=0)
    a, c = pe.step(rst_n=True, weight_en=False, en=True, clr=False, w_in=0, a_in=-128, c_in=0)
    assert (a, c) == (-128, 16384), f"Extreme negative mismatch: got ({a}, {c})"

    # 6. Two's Complement Overflow Wrapping
    pe.step(rst_n=True, weight_en=True, en=False, clr=False, w_in=10, a_in=0, c_in=0)
    # 0x7FFFFF00 (2147483392) + (100 * 10) = 2147484392 -> wraps to -2147482904 (0x800002E8)
    a, c = pe.step(rst_n=True, weight_en=False, en=True, clr=False, w_in=0, a_in=100, c_in=0x7FFFFF00)
    assert (a, c) == (100, -2147482904), f"Overflow mismatch: got ({a}, {c})"

    print(">>> Python Golden Reference Model: 100% Validated! <<<")

if __name__ == "__main__":
    run_comprehensive_validation()
