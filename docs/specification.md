# APB SPI 主机设计规格

本文规定 RTL 实现和测试平台共同遵守的接口行为。可综合顶层为
`apb_spi_master`，位于 SystemVerilog 源文件 `rtl/apb_spi_master.sv`。
所有内部逻辑使用 `pclk`，`presetn` 为低有效异步复位。

APB 接口采用 APB3，数据宽度为 32 位，字节地址宽度为 8 位，不提供字节写选通，
采用零等待周期响应。仅在 `pclk` 上升沿满足 `psel && penable && pready` 时，
一次访问才产生实际操作；SETUP 阶段不产生寄存器或 FIFO 副作用。
`pslverr` 仅在 ACCESS 阶段有效。

未按 4 字节对齐、未映射或不符合权限/参数要求的访问返回错误，不执行所请求的
操作，但会记录下文规定的错误事件。

## 顶层参数和端口

| 参数 | 默认值 | 合法范围 |
|---|---:|---|
| `FIFO_DEPTH` | 16 | 2～32768，且必须为 2 的幂；TX 和 RX 使用相同深度 |
| `NUM_CS` | 4 | 1～4 |

输入端口：`pclk`、`presetn`、`paddr[7:0]`、`psel`、`penable`、`pwrite`、
`pwdata[31:0]`、`spi_miso`。

输出端口：`prdata[31:0]`、`pready`、`pslverr`、`irq`、`spi_sclk`、`spi_mosi`、
`spi_cs_n[NUM_CS-1:0]`。片选为低有效，空闲时全部为高。

## 寄存器表

以下地址均为相对 IP 基地址的字节偏移。`RW` 表示可读写，`RO` 表示只读，
`WO` 表示只写，`RW1C` 表示可读、写 1 清除对应状态位。

| 偏移 | 寄存器 | 权限 | 复位值 | 定义 |
|---|---|---|---|---|
| 0x00 | CTRL | RW | 0 | bit 0：使能；bit 1：CPOL；bit 2：CPHA；bit 3：LSB 优先；bit 4：内部回环 |
| 0x04 | DIVIDER | RW | 2 | bits 15:0：每个 SCLK 半周期包含的 PCLK 周期数，范围 1～65535 |
| 0x08 | CS_SELECT | RW | 0 | 被选中的从机编号，范围 0～NUM_CS-1 |
| 0x0c | LENGTH | RW | 1 | bits 15:0：下一次事务的字节数，范围 1～65535 |
| 0x10 | COMMAND | WO | — | 仅允许写入一个完整命令值：1 为 START，2 为 FLUSH，4 为 ABORT；不能按位组合命令 |
| 0x14 | STATUS | RO | 动态状态 | bit 0：忙；bit 1：TX 空；bit 2：TX 满；bit 3：RX 空；bit 4：RX 满；bit 5：等待 TX 数据；bit 6：等待 RX 空位 |
| 0x18 | TXDATA | WO | — | 将低 8 位压入 TX FIFO；忽略高 24 位 |
| 0x1c | RXDATA | RO | — | 弹出 RX FIFO 队首，返回值低 8 位为接收数据，高 24 位为零 |
| 0x20 | FIFO_LEVEL | RO | 0 | bits 15:0：TX 字节数；bits 31:16：RX 字节数 |
| 0x24 | IRQ_STATUS | RW1C | 0 | bit 0：DONE；bit 1：TX_OVERFLOW；bit 2：RX_UNDERFLOW；bit 3：COMMAND_ERROR；bit 4：ABORTED |
| 0x28 | IRQ_ENABLE | RW | 0 | 对应上述五个中断状态位的使能掩码；1 表示允许该事件拉高 irq |

复位后的 `STATUS` 为 `0x0000000a`，即 TX 空、RX 空，其余状态为零。

忙状态下拒绝写入 `CTRL`、`DIVIDER`、`CS_SELECT` 和 `LENGTH`，即使写入值与当前值
相同也不接受。配置寄存器及中断寄存器的保留位必须写零；`DIVIDER`、`LENGTH` 写零，
以及 `CS_SELECT` 写入越界编号均返回错误。读取只写寄存器或写入只读寄存器也返回错误。

错误事件与返回值如下：

- 非法配置、命令、地址或访问权限错误：置位 `COMMAND_ERROR`。
- TX FIFO 已满时写入 `TXDATA`：置位 `TX_OVERFLOW`，不压入数据。
- RX FIFO 为空时读取 `RXDATA`：置位 `RX_UNDERFLOW`，返回零，不弹出数据。
- 其他失败的读访问也返回零。

`IRQ_STATUS` 为粘滞状态：事件发生后保持置位，直到软件写 1 清除或复位。
写 0 不影响对应位。硬件新事件与软件写 1 清除发生在同一拍时，硬件事件优先，
对应状态仍为 1。`IRQ_ENABLE` 只屏蔽输出，不阻止事件记录：

```text
irq = |(IRQ_STATUS & IRQ_ENABLE)
```

## 事务行为

`START` 要求 `CTRL.enable=1` 且当前不忙。命令被接受后拉低选中的 CS，传输
`LENGTH` 个字节，并在整个事务期间保持该片选有效。允许 TX FIFO 为空时启动。

在字节边界，若 TX 为空或 RX 已满，控制器等待软件补充 TX 数据或取走 RX 数据，
此时 SCLK 保持 CPOL 空闲电平，CS 继续有效。软件可以在事务期间通过 APB 操作
两个 FIFO。仅当 RX 至少有一个空位时才启动一个字节，字节中途不因 FIFO 状态暂停。

FIFO 满空状态以每个 PCLK 有效沿之前的状态判断：若沿前 TX 已满，即使同一沿
硬件弹出 TX 数据，软件写 TX 仍返回错误；若沿前 RX 为空，即使同一沿硬件压入
接收数据，软件读 RX 仍返回错误。

正常完成时，最后一个 SCLK 尾沿之后至少再保持一个 PCLK 周期才释放 CS，并置位
`DONE`。`START` 不隐式清除中断状态，也不清除两个 FIFO；未使用的 TX 数据和之前
尚未读取的 RX 数据都会保留。

`FLUSH` 仅在空闲时接受，清空两个 FIFO，不隐式清除中断状态。

`ABORT` 在任何状态下均可接受。在该 APB 命令被接受的时钟沿，控制器结束当前事务、
释放 CS、使 SCLK 返回 CPOL 空闲电平，丢弃尚在传输的字节并清空两个 FIFO，置位
`ABORTED`。此次中止不产生新的 `DONE` 事件，之前已记录的其他中断状态仍保留。
这是恢复操作，可能截短一个 SCLK 脉冲。

复位将控制状态、配置寄存器、FIFO 指针/计数和中断状态恢复为默认值。

## SPI 时序与集成要求

串行引擎支持 SPI 四种模式，固定使用 8 位全双工字，支持 MSB 优先或 LSB 优先。
字节传输期间的时钟频率为：

```text
f_sclk = f_pclk / (2 * DIVIDER)
```

SCLK 是寄存器输出，不作为任何内部 RTL 逻辑的时钟。外部 MISO 在 PCLK 时钟域中，
按配置的 SPI 采样边沿采样。板级集成必须依据实际外设添加源同步接口时序约束。
内部回环模式以 MOSI 作为采样输入。

所连接的 SPI 从机必须能够容忍 CS 保持有效期间的字节间停顿。通用综合工程不假定
具体开发板引脚或外设时序；内部时序报告不能替代板级 SPI 接口的时序分析。

## 内部模块接口约定

### spi_shift

输入端口：`clk`、`rst_n`、`abort`、`start`、`divider[15:0]`、`cpol`、`cpha`、
`lsb_first`、`loopback`、`tx_data[7:0]`、`miso`。

输出端口：`busy`、`done`、`rx_data[7:0]`、`sclk`、`mosi`。

`start` 为单周期脉冲，仅在引擎空闲时接受；从接受开始到 `done` 有效期间，配置输入
必须保持稳定。接受 `start` 后经过 `DIVIDER` 个时钟周期产生第一个边沿，每个字节
总计产生 16 个交替边沿。最后一个尾沿后产生单周期 `done` 脉冲，此时 `rx_data`
有效。`abort` 的优先级高于启动和正常完成。

### sync_fifo

参数：`WIDTH=8`、`DEPTH=16`。

输入端口：`clk`、`rst_n`、`clear`、`push`、`pop`、`din[WIDTH-1:0]`。

输出端口：`dout[WIDTH-1:0]`、`empty`、`full`、`level[$clog2(DEPTH):0]`。

输出采用首字直通方式：非空时 `dout` 为队首数据，空时输出零。仅当非满时接受
`push`，仅当非空时接受 `pop`；两者同时被接受时，计数保持不变。`clear` 优先于
入队和出队。复位或清空只需使已有条目失效，不要求把存储阵列内容逐项清零。
