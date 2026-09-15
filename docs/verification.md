# 验证记录

验证日期：2026-10-22。以下为 RTL 统一为 SystemVerilog 后的本机实际运行结果。
首次验证记录（2026-10-20）保留在 Git 历史中。

## 环境与复现

- Icarus Verilog：12.0 (devel)，`s20150603-1539-g2693dd32b`，Windows 版本。
- Vivado / XSim：2025.2，Build 6299465。
- 目标器件：`xc7z020clg400-1`。
- 默认参数：FIFO_DEPTH=16，NUM_CS=4。
- 内部 PCLK：10 ns；setup uncertainty：0.250 ns。
- OOC 参考时钟缓冲位置：BUFGCTRL_X0Y0，属于独立评估假设。

```powershell
python scripts/run.py test --seed 20261020
python scripts/run.py sim --seed 20261022 --waves
python scripts/run.py synth --implement
python scripts/run.py project
python scripts/run.py xsim --seed 1
```

构建输出保留在 `build/`。交付时的报告、仿真日志副本保存在 `docs/reports/`；
`source_sha256.txt` 记录对应源码、约束和脚本的 SHA-256，便于识别后续修改。

## Icarus 回归

| 测试 | 参数 | 实际结果 |
|---|---|---|
| FIFO 单元 | DEPTH=2 | PASS，2009 次操作 |
| FIFO 单元 | DEPTH=16 | PASS，2037 次操作 |
| SPI 引擎 | 全模式、双位序、外部输入/回环、分频 1/2/7 | PASS，493 个传输/中止用例 |
| 精确同周期边界 | FIFO=2、CS=1 | PASS，6 个冲突场景、184 次检查 |
| APB/SPI 系统 | FIFO=2、CS=1、seed=20261020 | PASS，8439 次检查、35 次正常完成事务、67 字节 |
| APB/SPI 系统 | FIFO=4、CS=2、seed=20261021 | PASS，11247 次检查、35 次正常完成事务、97 字节 |
| APB/SPI 系统 | FIFO=16、CS=4、seed=20261022 | PASS，13566 次检查、35 次正常完成事务、133 字节 |

7 组配置全部通过。编译启用 `-g2012 -Wall`。Icarus 12.0 在 APB 地址译码的
`always_comb` 中对常量位选择给出 5 条敏感列表提示：将所读总线的全部位纳入
敏感列表。这会扩大触发范围，不改变本模块的组合逻辑结果；原始提示保留在
系统级和冲突测试的编译日志中。
这里的“检查次数”是测试平台实际执行的条件检查计数，不是功能覆盖率百分比。
FIFO 和 SPI 单元测试使用固定的确定性伪随机序列；命令行 seed 用于系统级测试。

系统级检查范围：

- 4 种 SPI 模式 × 2 种位序 × 3 种分频（1/2/5），使用独立 SPI 从机。
- 检查 MOSI 每一位、MISO 回读值、字节内每半周期长度、片选选择与保持时间。
- APB SETUP 不产生副作用、连续 PSEL 的背靠背访问、错误响应阶段。
- 不对齐/未知地址、方向错误、无效配置、忙时修改配置或重复 START。
- FIFO 满写/空读、回绕、长于 FIFO 的事务、TX 饥饿与 RX 满暂停、恢复后数据顺序。
- 中断屏蔽、状态粘滞、W1C、START 保留 FIFO 内容和旧事件。
- 中途 ABORT/reset、清空、恢复后重新传输。

精确冲突测试还覆盖 DONE 与 W1C 同拍，ABORT 遇到最终边沿、完成等待和结果交接，
满 TX 写入与硬件出队同拍，以及空 RX 读取与硬件入队同拍。该定向测试仅使用层次
引用确认目标时刻确实发生，功能结果仍通过外部 APB 和引脚检查。主系统测试不读取
DUT 内部状态。

## Vivado XSim

生成的原生工程实际完成了行为仿真，默认参数、seed=1 的结果为：

```text
PASS ALL checks=13566 APB_accesses=2197 transactions=35 serial_bytes=133 seed=1
```

入口是 `python scripts/run.py xsim`，需先执行 `project`。
脚本要求本次新生成的仿真日志出现 PASS ALL，并检查错误信息；Vivado 退出码为 0
但 Tcl 报错的情况不会被误报为成功。

## Vivado 综合与布局布线

流程为 `synth_design -mode out_of_context → opt_design → place_design →
phys_opt_design → route_design`。下表来自最终布局布线报告：

| 指标 | 实际值 |
|---|---:|
| Slice LUTs | 285 |
| LUT as Logic | 273 |
| LUT as Memory | 12 |
| Slice Registers / FF | 142 |
| Latch | 0 |
| Block RAM | 0 |
| DSP | 0 |
| WNS，最差建立裕量 | +2.421 ns |
| WHS，最差保持裕量 | +0.034 ns |
| TNS / THS | 0 / 0 ns |
| 不满足建立/保持的内部端点 | 0 / 0 |
| 未约束内部端点 | 0 |
| 需要布线 / 已完成布线网络 | 358 / 358 |
| 布线错误网络 | 0 |

原始报告：[资源](reports/utilization_route.rpt)、[时序](reports/timing_route.rpt)、
[布线状态](reports/route_status.rpt)、[DRC](reports/drc_route.rpt)。

FIFO 的存储写过程与指针/计数复位过程分开，最终推断为分布式 RAM，避免了整段
存储器使用触发器。没有综合黑盒或锁存器。

## 结果边界与已知信息

上述时序通过只适用于已声明时钟与缓冲位置假设下的 **IP 内部路径**。
APB 外部路径、SPI 外部建立保持时间和复位释放尚未做板级约束；报告明确列出
45 个未设输入延迟、29 个未设输出延迟的端口。不应把它表述成完整板级时序收敛。

Vivado 日志存在可解释的警告：PREADY 恒为 1 和 PRDATA 保留高位恒为 0；OOC
端口没有顶层连接位置；Zynq 独立 IP 没有 PS7 实例，DRC 会报告 ZPS7-1。
没有通过降低警告级别掩盖这些信息。最终实现没有 Critical Warning 或 Error。

当前没有生成板卡 bitstream、连接真实 SPI 从机或完成上板测量；没有声明最高
工作频率、功耗、形式验证结果或覆盖率百分比。后续接入 Zynq PS 时，应补齐
AXI-to-APB 桥、系统复位/时钟、具体板卡管脚和外设时序，再做完整系统实现。
