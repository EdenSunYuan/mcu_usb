# sim/busstate — usb_bus_state 单元测试

被测：`src/phy/usb_bus_state.v`（一条计数器 + 两个标志位 + 两个翻转位，无状态机；
判据跑 `ref_clk` 4×，四个事件脉冲在 `clk12m` 1× 组合直出）。
设计报告：`doc/design_rpt/bus_state_design.md`；验证报告：`doc/design_rpt/bus_state_verification.md`。

## 跑法

```bash
make -C sim/busstate run          # 14 用例全跑（约 20 秒，含 3ms 挂起窗）
make -C sim/busstate build        # 只编译
make -C sim/busstate clean        # 清 .vvp/.log（保留 .vcd）

# 根入口
make busstate                     # 等价于 make -C sim/busstate run（已进 MODULES）
make cov     MOD=busstate         # Verilator 覆盖率 + 标志位状态/迁移覆盖（14 用例合并）
make covclean MOD=busstate        # 删 cov/
make -C sim/busstate fsmcov       # 只跑标志位状态/迁移那一维（根 Makefile 无此入口）
make debugwave MOD=busstate CASE=bs_connect     # 出 VCD + 打开 wave_debugger
```

`bs_clk_jitter` 需要 `+jit=1`（clk12m 周期按 3/4/5 拍轮转），Makefile 只对这个用例自动加。

## 用例

| 用例 | 考什么 |
|---|---|
| `bs_reset_default` | 复位清零；冷启动长 SE0 不报总线复位（没连过谈不上复位） |
| `bs_connect` | J ≥2.5µs 报一次 `connect_evt`；不到 3ms 不报挂起、不重报 |
| `bs_suspend` | 空闲 J ≥3ms 报一次 `suspend_evt`；再等 3ms 不重复 |
| `bs_resume` | 挂起中主机 K ≥2.5µs 报一次 `resume_evt`，挂起随之解除 |
| `bs_short_k` | 挂起中短 K（包内数据 28 拍）不报 resume，挂起保持 |
| `bs_threshold_scan` | 2.5µs 门限扫描：SE0 与 K 各 116..130 拍，逐段隔离 |
| `bs_self_drive` | 自驱 K（远程唤醒）/ 自驱 SE0（包尾 EOP）都不报事件 |
| `bs_bus_rst` | 已附着后 SE0 ≥2.5µs 报 `usb_bus_rst`；长 SE0 里只报一次 |
| `bs_two_resets` | 两次总线复位各报一次（翻转通知不会两翻相消） |
| `bs_usb_rst` | `usb_rst` 清两个标志位、不动两个翻转位（不造假脉冲），清后重连 |
| `bs_k_when_awake` | 未挂起时的长 K 不报 resume；回 J 后仍能正常挂起 |
| `bs_se1_stuck` | SE1 持续（PHY 异常）不报任何事件 |
| `bs_clk_jitter` | clk12m 周期 3/4/5 拍轮转时四类事件照常 |
| `bs_latency_phase` | 触发沿平移 0..3 拍扫 clk12m 四相位，延迟全落在 1..4 ref 拍 |

每条用例的判据都写在文件头（因 → 变 → 果 + 前后文窗口 + 量化判据），见
`sim/common/README.md` 的仿真规范。

## 三层判据（本 TB 的核心）

**① 三处计数相等**：每类事件在三个位置各数一遍，必须相等——
判据次数 `n_cond[i]`（ref 域，单拍）== 载体次数 `n_mid[i]`（ref 域，标志位取上升沿 /
翻转位取变化）== 脉冲个数 `n_pulse[i]`（clk12m 域，输出的上升沿）。
相等就证明了「一次判据 → 一次翻转或置位 → 恰好一个脉冲」，多一个少一个都算挂。

**② 脉冲形状**：四个输出的高电平最宽恒为 1 个 clk12m 拍（`wmax[i] <= 1`），
且任意 clk12m 拍至多一路为高。

**②′ 第五个输出 `bus_suspended`（电平，给 `usb_tx_serial` 的唤醒旁路）**：整轮逐拍
等于 `sus_s[0]`，且它的上升沿与 `suspend_evt` 同拍（`n_bsus_ne` / `n_bsus_edge` 必须
都是 0）。这两条一起把「错接成 `ref_clk` 域那个 `suspended`」挡住——那样电平会早
一个 clk12m 拍起跳，也成了没同步的跨域。

**③ 跨域延迟**：判据起拍 → 脉冲起拍逐事件记录，打印 min..max。实测 1..4 个 ref 拍，
随判据落在 clk12m 的哪个相位而变（`bs_latency_phase` 扫四相位得 3/2/1/4），
上界 4 拍 = 一个 clk12m 周期 ≈83ns。

## 四类事件的载体不同，判据也不同

`connected` / `suspended` 是**标志位**，连上或挂起之后一直是长电平，取上升沿即事件；
`rst_cond` / `rsm_cond` 是 ref 域的**单拍脉冲**，取不了沿，改用翻转位（`rst_tgl` /
`rsm_tgl`）通知：翻一次 = 发生过一次。所以 `bs_two_resets` 与 `bs_usb_rst` 专门盯
「翻转位会不会两翻相消 / 会不会被 `usb_rst` 造出假脉冲」。

## clk12m 为什么要做成抖动

`+jit=1` 时周期按 3/4/5 拍轮转，与 `dclk` 经 `usb_clk_mux` 切过来的样子同构。
两拍同步链只依赖「边沿对齐 ref_clk」，不依赖周期恒定；抖动模式跑通才算这条性质成立。

## 覆盖率

```bash
make cov MOD=busstate                  # 报数口径看 u_dut 模块那一行, 不是全层级 summary
make -C sim/busstate fsmcov            # 无状态机, 改数 {connected,suspended} 的组合与迁移
                                       # (profile 见 tools/merge_fsm_cov.py)
```

数字与未覆盖项定性见 `doc/design_rpt/bus_state_verification.md` 的覆盖率章节。
