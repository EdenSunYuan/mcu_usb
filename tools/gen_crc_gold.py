#!/usr/bin/env python3
#============================================================================
# gen_crc_gold.py — USB 1.1 CRC5 / CRC16 黄金向量生成器
#
# 严格按 USB 1.1 规范 §8.3.5 实现:
#   - 移位寄存器种子 = 全 1 (CRC5:0x1F, CRC16:0xFFFF)
#   - 每个数据位: fb = crc[MSB]^d; crc = (crc<<1)&mask; if fb: crc ^= poly
#   - poly: CRC5 = x^5+x^2+1  (00101B),  CRC16 = x^16+x^15+x^2+1 (0x8005)
#   - 数据字段发送序 = LSb first (ADDR/ENDP 逐位, DATA 逐字节内 LSB first)
#   - CRC 发送前取反, 发送序 = MSb first
#   - 接收残差: CRC5 = 01100B(0x0C), CRC16 = 1000000000001101B(0x800D)
#
# 已用规范残差校验: 全部向量残差 == 0x0C / 0x800D
#============================================================================

def crc_step(crc, width, poly, d):
    fb = (crc >> (width-1)) & 1
    crc = (crc << 1) & ((1 << width) - 1)
    if fb ^ d:
        crc ^= poly
    return crc


def crc_run(width, poly, bits):
    crc = (1 << width) - 1                      # 种子 = 全 1
    for d in bits:
        crc = crc_step(crc, width, poly, d)
    return crc


def crc5_token(addr, endp):
    """CRC5 覆盖 ADDR[6:0]+ENDP[3:0], 返回发送值 (已取反)."""
    bits = [(addr >> i) & 1 for i in range(7)] + [(endp >> i) & 1 for i in range(4)]
    return (~crc_run(5, 0x05, bits)) & 0x1F


def crc5_residual(addr, endp):
    """数据+CRC 通过 CRC5, 应得残差 0x0C."""
    bits = [(addr >> i) & 1 for i in range(7)] + [(endp >> i) & 1 for i in range(4)]
    c = crc5_token(addr, endp)
    bits += [(c >> (4 - i)) & 1 for i in range(5)]   # CRC 发送序 MSB first
    return crc_run(5, 0x05, bits)


def crc16_data(payload):
    """CRC16 覆盖 DATA 字节流, 返回发送值 (已取反)."""
    bits = [(b >> i) & 1 for b in payload for i in range(8)]
    return (~crc_run(16, 0x8005, bits)) & 0xFFFF


def crc16_residual(payload):
    """数据+CRC 通过 CRC16, 应得残差 0x800D."""
    bits = [(b >> i) & 1 for b in payload for i in range(8)]
    c = crc16_data(payload)
    bits += [(c >> (15 - i)) & 1 for i in range(16)]  # CRC 发送序 MSB first
    return crc_run(16, 0x8005, bits)


# ---------------------------------------------------------------------------
# 字节并行版 (usb_crc5_byte.v / usb_crc16_byte.v) 的更新方程推导
#
# 把逐位算法展开 8 拍 (1 字节/拍), 合并同类项 —— 余数对「余数位 + 数据位」是
# GF(2) 线性函数, 每位只需列出若干 tap。变量编号 0..W-1 = 余数位,
# W..W+7 = 数据位 (先喂的在前, 即 d_in[0])。
# ---------------------------------------------------------------------------

def byte_parallel_taps(width, poly, nbits=8):
    """返回 [每位余数的 tap 下标列表] (tap 是变量编号, 见上)."""
    nv  = width + nbits
    var = [1 << i for i in range(nv)]
    st  = var[:width]
    for k in range(nbits):
        fb    = st[width-1] ^ var[width + k]
        nxt   = [0] + st[:width-1]
        for i in range(width):
            if (poly >> i) & 1:
                nxt[i] ^= fb
        st = nxt
    return [[i for i in range(nv) if (m >> i) & 1] for m in st]


def byte_parallel_apply(width, taps, state, byte):
    """按推导出的 tap 表算一拍更新的结果 (逐位串行算法的对照)."""
    v = 0
    for i, row in enumerate(taps):
        b = 0
        for j in row:
            b ^= (state >> j) & 1 if j < width else (byte >> (j - width)) & 1
        v |= b << i
    return v


def verify_byte_parallel(width, poly, seed_list, byte_list):
    """展开式与逐位算法逐点等价自检; 不等价直接 assert 失败."""
    taps = byte_parallel_taps(width, poly)
    for st in seed_list:
        for b in byte_list:
            bits = [(b >> k) & 1 for k in range(8)]
            ref  = crc_run_from(st, width, poly, bits)
            got  = byte_parallel_apply(width, taps, st, b)
            assert ref == got, f"并行展开与逐位不符: W={width} st={st:04x} b={b:02x} {ref:04x}!={got:04x}"
    return taps


def crc_run_from(seed, width, poly, bits):
    """从任意种子跑一段位流 (crc_run 的种子固定为全 1, 这里要换种子)."""
    crc = seed
    for d in bits:
        crc = crc_step(crc, width, poly, d)
    return crc


def dump_verilog(width, poly, dname="d_in", cname="crc_out", wname="crc_out_nxt"):
    """打印字节并行更新方程的 Verilog 形式 (直接贴进 <模块>.v)."""
    taps = byte_parallel_taps(width, poly)
    print(f"// CRC{width} 字节并行更新 (poly = 0x{poly:0{width//4}x}, 1 字节/拍)")
    for i, row in enumerate(taps):
        terms = [f"{cname}[{j}]" if j < width else f"{dname}[{j-width}]" for j in row]
        print(f"assign {wname}[{i}] = " + " ^ ".join(terms) + ";")


if __name__ == "__main__":
    import sys

    if "--eq" in sys.argv:
        import random
        random.seed(0)
        for w, p in [(5, 0x05), (16, 0x8005)]:
            seeds = [0, (1 << w) - 1, 0x0C & ((1 << w) - 1)] + \
                    [random.getrandbits(w) for _ in range(64)]
            verify_byte_parallel(w, p, seeds, list(range(256)))
            dump_verilog(w, p)
            print()
        print("BYTE-PARALLEL UPDATE EQUATIONS VERIFIED (== bit-serial)")
        sys.exit(0)

    print("== CRC5 向量 (addr, endp) -> tx_crc, residual ==")
    for a, e in [(0,0),(5,0),(0x12,1),(0x7F,0xF),(1,0),(0x7F,0)]:
        assert crc5_residual(a, e) == 0x0C, "CRC5 residual mismatch!"
        print(f"  addr={a:02x} endp={e:x} tx=0x{crc5_token(a,e):02x} residual=0x{crc5_residual(a,e):02x}")

    print("== CRC16 向量 (data) -> tx_crc, residual ==")
    for p in [bytes(5), bytes([0x02,0,0,0,0]), bytes([0x80,0,0,0,0,0,0,0]),
              bytes([0,1,2,3,4,5,6,7]), bytes(64)]:
        assert crc16_residual(p) == 0x800D, "CRC16 residual mismatch!"
        print(f"  {p.hex()} tx=0x{crc16_data(p):04x} residual=0x{crc16_residual(p):04x}")

    # 字节并行更新方程与逐位算法等价 (usb_crc5_byte.v / usb_crc16_byte.v 的依据)
    for w, p in [(5, 0x05), (16, 0x8005)]:
        verify_byte_parallel(w, p, [0, (1 << w) - 1, 0x0C, 0x800D & ((1 << w) - 1)],
                             [0x00, 0xFF, 0x01, 0x80, 0xA5])
    print("BYTE-PARALLEL UPDATE EQUATIONS VERIFIED (== bit-serial)")

    print("\nALL GOLD VECTORS VERIFIED (residual 0x0C / 0x800D)")
    sys.exit(0)
