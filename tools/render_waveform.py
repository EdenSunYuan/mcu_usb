#!/usr/bin/env python3
"""
render_waveform.py — 用 wave_debugger 离屏渲染波形并导出 PNG

复用 wave_debugger.py 的渲染引擎 (WaveformScene / WaveformPanel)，在离屏
(offscreen) 模式下加载 VCD、添加信号、设置时间窗口，然后 grab() 出位图保存。

用途: 把交互式波形调试器的显示结果截图到验证报告等文档中，无需人工操作 GUI。

用法:
    python3 tools/render_waveform.py <vcd> <out.png> \
        --signals tb_cdr.rxdp,tb_cdr.clk12m,tb_cdr.d_out \
        --start 0 --end 4000000 \
        [--radix "tb_cdr.dut.state=hex,tb_cdr.bus=dec"] \
        [--full-window] [--width 1500 --height 950]

    --start/--end 单位: ps (VCD timescale 1ps)
    --radix       按信号全路径指定多 bit 总线显示进制, 逗号分隔 "路径=hex"
                  可选 hex/bin/dec/oct/unsigned (默认 bin, 同 GUI 右键菜单)
    --full-window  截整个主窗口 (含模块树/信号列表/代码), 否则只截波形面板
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtWidgets import QApplication  # noqa: E402
import wave_debugger  # noqa: E402

# 合法进制取值 (与 WaveformScene.RADIX_* 对应)
VALID_RADIX = {wave_debugger.WaveformScene.RADIX_HEX,
               wave_debugger.WaveformScene.RADIX_BIN,
               wave_debugger.WaveformScene.RADIX_DEC,
               wave_debugger.WaveformScene.RADIX_OCT,
               wave_debugger.WaveformScene.RADIX_UNSIGNED}


def parse_radix_map(spec: str) -> dict:
    """解析 '--radix' 字符串 'path=hex,path2=dec' 为 {full_path: radix}."""
    out: dict[str, str] = {}
    for item in [x for x in spec.split(",") if x.strip()]:
        if "=" not in item:
            print(f"WARN: --radix '{item}' 缺少 '=' (应为 路径=进制), 忽略", file=sys.stderr)
            continue
        path, _, radix = item.partition("=")
        path, radix = path.strip(), radix.strip().lower()
        if radix not in VALID_RADIX:
            print(f"WARN: --radix 进制 '{radix}' 非法 (可选 {sorted(VALID_RADIX)}), 忽略", file=sys.stderr)
            continue
        out[path] = radix
    return out


def render(vcd_path, out_png, signal_paths, start_ps, end_ps,
           full_window=False, width=1500, height=950, radix_map=None):
    app = QApplication.instance() or QApplication(sys.argv)

    window = wave_debugger.WaveDebuggerMain(vcd_path)
    window._open_vcd(vcd_path)          # 直接加载 (不依赖 showEvent)
    window.resize(width, height)
    window.show()
    app.processEvents()

    # 全路径 -> VCD id 映射
    path2id = {s.full_path: s.vcd_id
               for s in window._analyzer.header.get("signals", [])}
    vcd_ids = [path2id[p] for p in signal_paths if p in path2id]
    missing = [p for p in signal_paths if p not in path2id]
    if missing:
        print(f"WARN: signals not found: {missing}", file=sys.stderr)

    window._on_add_signals(vcd_ids)
    app.processEvents()

    # 按需设置单信号显示进制 (--radix "path=hex,..."), 默认 bin
    ws = window.wave_panel.wave_scene
    for path, radix in (radix_map or {}).items():
        vid = path2id.get(path)
        if vid is None:
            print(f"WARN: --radix 信号未找到: {path}", file=sys.stderr)
            continue
        ws.set_signal_radix(vid, radix)

    # 设置时间窗口 (ps)
    wv = window.wave_panel.wave_view
    vp_w = wv.viewport().width()
    span_ps = max(1, end_ps - start_ps)
    ws.pixels_per_ps = max(5e-7, vp_w / span_ps)
    ws._update_scene_rect()
    h_sb = wv.horizontalScrollBar()
    h_sb.setValue(int(start_ps * ws.pixels_per_ps))
    window.wave_panel._update_visible_range()
    ws._redraw()
    app.processEvents()

    # 截图
    widget = window if full_window else window.wave_panel
    pixmap = widget.grab()
    ok = pixmap.save(out_png)
    window.close()
    return ok


def main():
    import argparse
    p = argparse.ArgumentParser(description="Render VCD waveform to PNG via wave_debugger")
    p.add_argument("vcd", help="VCD file path")
    p.add_argument("out", help="output PNG path")
    p.add_argument("--signals", required=True,
                   help="comma-separated signal full paths (in display order)")
    p.add_argument("--start", type=float, default=0, help="visible start time (ps)")
    p.add_argument("--end", type=float, required=True, help="visible end time (ps)")
    p.add_argument("--full-window", action="store_true",
                   help="capture whole main window instead of waveform panel only")
    p.add_argument("--width", type=int, default=1500)
    p.add_argument("--height", type=int, default=950)
    p.add_argument("--radix", default="",
                   help="per-signal bus radix: path=hex[,path2=dec] (default bin), "
                        "e.g. tb_cdr.dut.state=hex")
    a = p.parse_args()

    sigs = [s.strip() for s in a.signals.split(",") if s.strip()]
    radix_map = parse_radix_map(a.radix)
    ok = render(a.vcd, a.out, sigs, a.start, a.end, a.full_window,
                a.width, a.height, radix_map)
    extra = f", radix {radix_map}" if radix_map else ""
    print(f"{'OK' if ok else 'FAIL'}: {a.out} ({a.start:.0f}–{a.end:.0f} ps, "
          f"{len(sigs)} signals{extra})")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
