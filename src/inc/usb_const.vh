//============================================================================
// usb_const.vh — USB 1.1 Device Controller 全局常量定义
//
// 位序：USB 规范要求所有字段 LSb-first（线上先发低 bit）
// 语法：Verilog-2001 宏定义，供全工程 include
//============================================================================

`ifndef USB_CONST_VH
`define USB_CONST_VH

//--------------------------------------------------------------------------
// 时钟参数（USB Full-Speed = 12 Mbit/s）
//--------------------------------------------------------------------------
`define USB_FS_BIT_RATE      12_000_000    // 12 MHz
`define USB_REF_CLK_FREQ     48_000_000    // ref_clk 48 MHz（4x 过采样）
`define USB_REF_CLK_PER_BIT  4             // 每 bit = 4 个 ref_clk 周期
`define USB_BYTE_CLK_PERIOD  32            // 每字节 = 32 个 ref_clk 周期 (=8bit*4)

//--------------------------------------------------------------------------
// PID 类型（线上传输字节值, LSb-first）
//--------------------------------------------------------------------------
`define PID_OUT      8'hE1     // 0001 1110b(补) -> wire 0xE1
`define PID_IN       8'h69     // 1001 0110b(补) -> wire 0x69
`define PID_SOF      8'hA5     // 0101 1010b(补) -> wire 0xA5
`define PID_SETUP    8'h2D     // 1101 0010b(补) -> wire 0x2D
`define PID_DATA0    8'hC3     // 0011 1100b(补) -> wire 0xC3
`define PID_DATA1    8'h4B     // 1011 0100b(补) -> wire 0x4B
`define PID_ACK      8'hD2     // 0010 1101b(补) -> wire 0xD2
`define PID_NAK      8'h5A     // 1010 0101b(补) -> wire 0x5A
`define PID_STALL    8'h1E     // 1110 0001b(补) -> wire 0x1E
`define PID_NYET     8'h96     // 0110 1001b(补) -> wire 0x96
`define PID_PRE      8'h3C     // 1100 0011b(补) -> wire 0x3C

// PID 类型号（低 4 位 = type, 高 4 位 = ~type）
`define PID_TYPE_OUT    4'h1
`define PID_TYPE_IN     4'h9
`define PID_TYPE_SOF    4'h5
`define PID_TYPE_SETUP  4'hD
`define PID_TYPE_DATA0  4'h3
`define PID_TYPE_DATA1  4'hB
`define PID_TYPE_ACK    4'h2
`define PID_TYPE_NAK    4'hA
`define PID_TYPE_STALL  4'hE
`define PID_TYPE_NYET   4'h6
`define PID_TYPE_PRE    4'hC

// PID 类型分类
`define PID_CLS_TOKEN    2'h0   // OUT/IN/SOF/SETUP
`define PID_CLS_DATA     2'h1   // DATA0/DATA1
`define PID_CLS_HANDSHAKE 2'h2  // ACK/NAK/STALL/NYET
`define PID_CLS_SPECIAL  2'h3   // PRE

//--------------------------------------------------------------------------
// USB 状态/包结构常量
//--------------------------------------------------------------------------
`define SYNC_BYTE    8'h80    // 同步头 00000001b（LSb-first 线上的 7个0+1个1）
`define EOP_SE0_BITS 2        // EOP = SE0 至少 2 bit
`define MAX_PKT      64       // 全速最大包长（控制 8B 取大, bulk/intr 64B）

//--------------------------------------------------------------------------
// 寄存器地址偏移（APB 12-bit 地址 / 32-bit 数据, 字对齐）
//--------------------------------------------------------------------------
`define REG_DEV_ID     12'h000
`define REG_CTRL       12'h004
`define REG_ADDR       12'h008
`define REG_STATUS     12'h00C
`define REG_FRAME      12'h010
`define REG_INTR_EN    12'h014
`define REG_INTR_ST    12'h018
`define REG_EP0_CSR    12'h01C
`define REG_EP0_COUNT  12'h020
`define REG_EP0_DATA   12'h024
`define REG_EP1_CSR    12'h080
`define REG_EP1_COUNT  12'h084
`define REG_EP1_DATA   12'h088
`define REG_EP2_CSR    12'h100
`define REG_EP2_COUNT  12'h104
`define REG_EP2_DATA   12'h108

// CTRL 寄存器位域
`define CTRL_ENABLE_BIT    0
`define CTRL_SUSPEND_BIT   1
`define CTRL_SWRST_BIT     7

// STATUS 寄存器位域
`define STAT_SOF_RCVD_BIT  0
`define STAT_RESET_BIT     1
`define STAT_SUSPEND_BIT   2
`define STAT_RESUME_BIT    3
`define STAT_SETUP_BIT     4

// 端点 CSR 位域（EP0/EP1/EP2 共用）
`define EP_CSR_STALL_BIT   0     // 置1 = STALL
`define EP_CSR_SETUP_BIT   1     // EP0: 收到 SETUP 包
`define EP_CSR_RX_RDY_BIT  2     // 有收到的数据待固件读
`define EP_CSR_TX_RDY_BIT  3     // 固件已写入数据待 SIE 发送
`define EP_CSR_DIR_BIT     4     // EP1/EP2: 1=IN 0=OUT（EP0 固定双向）
`define EP_CSR_ACK_BIT     5     // 本次事务已 ACK

//--------------------------------------------------------------------------
// 通用
//--------------------------------------------------------------------------
`define USB_DEV_ADDR_WIDTH  7     // USB 设备地址 7-bit
`define USB_ENDP_NUM_WIDTH  4     // 端点数 4-bit
`define USB_FRAME_WIDTH     11    // 帧号 11-bit

`endif
