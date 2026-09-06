# APB SPI Master

面向 `xc7z020clg400-1` 的可综合 SPI 主机 IP。RTL 和自检查测试均使用
SystemVerilog（`.sv`），配套 Icarus Verilog 和 Vivado 脚本。
项目使用独立 APB3 接口，可作为 Zynq PL 中的外设控制模块。

## 目录

```text
apb-spi/
├── rtl/             可综合设计：APB 控制器、SPI 移位引擎、同步 FIFO
├── tb/              自检查仿真：独立 SPI 从机模型、APB 主机激励、单元测试
├── constraints/     IP 独立实现所需的 PCLK 约束
├── scripts/         Python 构建入口、Vivado Tcl
├── docs/            所有使用说明、设计规格、教学材料和验证记录
├── Makefile         可选的命令别名
└── build/           自动生成的仿真文件、波形、Vivado 工程和报告（已忽略）
```

## 功能

- APB3，32 位数据、8 位字节地址、零等待周期，支持非法访问错误响应。
- SPI Mode 0/1/2/3、8 位全双工、MSB/LSB 优先、内部回环。
- 可配置 16 位分频系数：`SCLK = PCLK / (2 × DIVIDER)`，DIVIDER 最小为 1。
- 默认 16 字节 TX FIFO 和 RX FIFO；深度可配置为 2～32768 的 2 次幂。
- 默认 4 路低有效片选，可配置 1～4 路，同一时刻只选择一路。
- 一次命令传输 1～65535 字节，整个事务保持片选；FIFO 缺数据或缺空间时在字节边界暂停。
- 完成、TX 溢出访问、RX 空读、命令错误、中止事件；中断屏蔽与写 1 清除。
- 支持空闲清 FIFO、传输中中止、传输中复位。

## 快速开始

在项目根目录 `E:\fpga\apb-spi` 打开 PowerShell：

```powershell
cd E:\fpga\apb-spi
python scripts/run.py test --seed 20261020
python scripts/run.py sim --waves
python scripts/run.py synth --implement
python scripts/run.py project
python scripts/run.py xsim
```

如果 Python 使用 Windows 启动器，把 `python` 替换成 `py -3`；在 WSL 中使用
`python3`。不需要 pip 包、第三方 Python 库或网络下载。脚本自动查找 PATH，
并兼容这台机器的安装位置：

```text
E:/iverilog/bin/iverilog.exe
E:/iverilog/bin/vvp.exe
E:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat
```

也可以用 `IVERILOG`、`VVP`、`VIVADO` 环境变量指定工具的完整路径。
Windows 工具从 WSL 启动需要启用 WSL 互操作；受限终端不能启动时，可直接在
Windows PowerShell 中运行同一脚本。

`test` 执行单元测试和多组参数回归；`sim` 只运行默认的系统级测试。失败以非零
退出码结束。日志在 `build/regression/` 或 `build/sim/`，波形为
`build/sim/waves.vcd`，可用 GTKWave 打开（如已安装）。

```powershell
# 最小参数组合
python scripts/run.py sim --fifo-depth 2 --num-cs 1 --seed 7
# 单独检查 SPI 位级引擎
python scripts/run.py sim --top tb_spi_shift
# 默认目标已经是这颗 Zynq，也可显式指定
python scripts/run.py synth --part xc7z020clg400-1 --implement
```

## 在 Vivado 中打开

运行 `project` 后，打开 `build/vivado/apb_spi_master.xpr`。

- `Design Sources` 顶层为 `apb_spi_master`。
- `Simulation Sources` 顶层为 `tb_apb_spi_master`；Run Behavioral Simulation
  并运行到结束，可看到自检查结果。
- `synth --implement` 执行独立 IP 的综合、优化、布局、布线，报告位于
  `build/synth/`。默认 PCLK 为 100 MHz。
- 该工程没有开发板封装引脚约束，不生成可直接下载的 bitstream。

器件型号只确定芯片，不能确定开发板的时钟、连接器和 SPI 引脚。
接入实际 Zynq 系统时，可采用 `PS AXI GP → AXI-to-APB bridge → 本 IP`，
由系统提供时钟和复位，再补充板卡 XDC 和从机的 SPI 外部时序约束。
本 IP 使用 APB 地址偏移，系统总线基地址由集成工程分配。

## 软件访问顺序

1. 空闲时配置 CTRL、DIVIDER、CS_SELECT、LENGTH。
2. 清除旧 IRQ_STATUS，根据需要写 IRQ_ENABLE。
3. 将首批数据写入 TXDATA，写 COMMAND=1 启动。
4. 传输期间按 STATUS/FIFO_LEVEL 补充 TX、读取 RX。
5. 等待 DONE 或 BUSY 清零，读完剩余 RX 数据，写 1 清除 DONE。

若发送长度超过 RX FIFO 深度，软件必须在事务进行时读取 RX，不能一直等 DONE
再读，否则事务会在 RX 满时暂停。仅接收场景也要写入 dummy TX 字节产生时钟。
仅发送场景仍会产生 RX 字节，同样需要处理 RX 数据。

## 阅读入口

- [设计规格与完整寄存器表](specification.md)
- [结构与时序说明](design.md)
- [学习顺序和练习](learning.md)
- [验证结果及适用边界](verification.md)
- [简历表述与面试准备](resume.md)
- [提交整理与日期说明](history.md)

全部生成文件可用 `python scripts/run.py clean` 清除；源码和 `docs/` 保留。
