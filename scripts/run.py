#!/usr/bin/env python3
"""Dependency-free Icarus/Vivado runner; all generated files live in build/."""

import argparse
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
DEFAULT_PART = "xc7z020clg400-1"


def local_path(value):
    """Accept either E:/... or /mnt/e/... tool overrides under WSL."""
    value = os.path.expandvars(os.path.expanduser(value.strip('"')))
    match = re.match(r"^([A-Za-z]):[\\/](.*)$", value)
    if os.name != "nt" and match:
        return Path("/mnt") / match[1].lower() / match[2].replace("\\", "/")
    return Path(value)


def find_tool(name):
    override = os.environ.get(name.upper())
    if override:
        candidate = local_path(override)
        if candidate.is_file():
            return candidate.resolve()
        located = shutil.which(override)
        if located:
            return Path(located).resolve()
        raise RuntimeError(f"{name.upper()} does not name a file or PATH command: {override}")

    names = [name, name + (".bat" if name == "vivado" else ".exe")]
    for entry in names:
        located = shutil.which(entry)
        if located:
            return Path(located).resolve()

    defaults = {
        "iverilog": ["E:/iverilog/bin/iverilog.exe"],
        "vvp": ["E:/iverilog/bin/vvp.exe"],
        "vivado": ["E:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat"],
    }
    for entry in defaults[name]:
        candidate = local_path(entry)
        if candidate.is_file():
            return candidate.resolve()
    raise RuntimeError(
        f"Cannot find {name}. Add it to PATH or set {name.upper()} to its executable path."
    )


def is_windows_tool(tool):
    return tool.suffix.lower() in (".exe", ".bat", ".cmd")


def tool_path(path, windows):
    """Paths passed to a Windows process must be Windows paths, even under WSL."""
    value = str(Path(path).resolve())
    if windows and os.name != "nt":
        match = re.match(r"^/mnt/([A-Za-z])/(.*)$", value)
        if match:
            return f"{match[1].upper()}:/{match[2]}"
        converter = shutil.which("wslpath")
        if not converter:
            raise RuntimeError(f"Cannot convert {value} to a Windows path; wslpath is missing.")
        return subprocess.check_output([converter, "-w", value], text=True).strip().replace("\\", "/")
    return value.replace("\\", "/") if windows else value


def launch_command(tool, args, cwd):
    """Run executables directly; use a generated launcher for Windows batch files."""
    windows = is_windows_tool(tool)
    executable = tool_path(tool, windows)
    if not windows or tool.suffix.lower() == ".exe":
        # WSL launches a Windows .exe by its Linux path, while that process needs
        # Windows-form source/output arguments. Avoid cmd's distinct quote parser.
        return [str(tool), *args], None
    cmd = os.environ.get("COMSPEC") or shutil.which("cmd.exe")
    if not cmd and Path("/mnt/c/Windows/System32/cmd.exe").is_file():
        cmd = "/mnt/c/Windows/System32/cmd.exe"
    if not cmd:
        raise RuntimeError("Windows tools require cmd.exe (Windows or WSL interoperability).")
    # Keep the quoted command inside a .cmd file: passing embedded quotes through
    # WSL's argv conversion to cmd /c gives a different interpretation than CRT.
    words = [executable, *args]
    if any(any(char in value for char in '\r\n\x00"%') for value in words):
        raise RuntimeError('Windows tool paths/arguments cannot contain quotes, %, or newlines.')
    command = "call " + " ".join('"' + value + '"' for value in words)
    launcher = cwd / ("launch_" + tool.stem + ".cmd")
    content = "@echo off\n" + command + "\nexit /b %ERRORLEVEL%\n"
    return [str(cmd), "/d", "/c", tool_path(launcher, True)], (launcher, content)


def run(tool, args, cwd, log_path, dry_run=False):
    command, launcher = launch_command(tool, args, cwd)
    display = subprocess.list2cmdline(command) if os.name == "nt" else shlex.join(command)
    print(f"+ {display}", flush=True)
    if dry_run:
        if launcher:
            print(launcher[1].strip())
        return
    cwd.mkdir(parents=True, exist_ok=True)
    if launcher:
        with launcher[0].open("w", encoding="utf-8", newline="\r\n") as stream:
            stream.write(launcher[1])
    with log_path.open("w", encoding="utf-8") as log:
        log.write(f"Command: {display}\nWorking directory: {cwd}\n\n")
        log.flush()
        try:
            with subprocess.Popen(
                command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace", bufsize=1,
            ) as process:
                for line in process.stdout:
                    print(line, end="", flush=True)
                    log.write(line)
                code = process.wait()
        except OSError as error:
            raise RuntimeError(
                f"Could not launch {tool}: {error}. "
                "For Windows tools, run from Windows or a WSL session with interoperability enabled."
            ) from error
    if code:
        raise RuntimeError(f"{tool.name} exited with status {code}; see {log_path}")


def hdl_files(directory):
    files = sorted(path for path in directory.rglob("*") if path.is_file())
    legacy = [path for path in files if path.suffix.lower() == ".v"]
    if legacy:
        raise RuntimeError(
            "This project uses SystemVerilog .sv sources only. "
            f"Convert or remove legacy .v sources in {directory}: "
            + ", ".join(str(path) for path in legacy)
        )
    return [path for path in files if path.suffix.lower() == ".sv"]


def check_sources():
    sources = hdl_files(ROOT / "rtl")
    testbench = hdl_files(ROOT / "tb")
    if not sources:
        raise RuntimeError(f"No SystemVerilog .sv RTL sources found in {ROOT / 'rtl'}")
    if not testbench:
        raise RuntimeError(f"No SystemVerilog .sv simulation sources found in {ROOT / 'tb'}")
    return sources, testbench


def simulate(args, output=None):
    sources, testbench = check_sources()
    compiler, runtime = find_tool("iverilog"), find_tool("vvp")
    output = output or BUILD / "sim"
    executable = output / (args.top + ".vvp")
    windows = is_windows_tool(compiler)
    parameters = []
    if args.top == "tb_apb_spi_master":
        parameters = [f"-P{args.top}.FIFO_DEPTH={args.fifo_depth}", f"-P{args.top}.NUM_CS={args.num_cs}"]
    elif args.top == "tb_sync_fifo":
        parameters = [f"-P{args.top}.DEPTH={args.fifo_depth}"]
    compile_args = [
        "-g2012", "-Wall", "-s", args.top, *parameters,
        "-o", tool_path(executable, windows),
        *[tool_path(source, windows) for source in sources + testbench],
    ]
    run(compiler, compile_args, output, output / "compile.log", args.dry_run)
    runtime_args = [tool_path(executable, is_windows_tool(runtime)), f"+SEED={args.seed}"]
    if args.waves:
        runtime_args.append("+WAVES")
    run(runtime, runtime_args, output, output / "simulation.log", args.dry_run)


def regression(args):
    # Exercise the minimum depth, pointer wrap at the default depth, every engine
    # mode, and integration at three FIFO/CS parameter combinations.
    cases = [
        ("fifo_depth2", "tb_sync_fifo", 2, 1, args.seed),
        ("fifo_depth16", "tb_sync_fifo", 16, 4, args.seed),
        ("spi_shift", "tb_spi_shift", 16, 4, args.seed),
        ("apb_collisions", "tb_apb_spi_corner", 16, 4, args.seed),
        ("apb_depth2_cs1", "tb_apb_spi_master", 2, 1, args.seed),
        ("apb_depth4_cs2", "tb_apb_spi_master", 4, 2, args.seed + 1),
        ("apb_depth16_cs4", "tb_apb_spi_master", 16, 4, args.seed + 2),
    ]
    for label, top, depth, count, seed in cases:
        case = argparse.Namespace(**vars(args))
        case.top, case.fifo_depth, case.num_cs, case.seed = top, depth, count, seed
        print(f"\nRegression case: {label} (seed {seed})", flush=True)
        simulate(case, BUILD / "regression" / label)
    if not args.dry_run:
        print(f"PASS: all {len(cases)} regression configurations completed.")


def vivado(args):
    check_sources()
    tool = find_tool("vivado")
    windows = is_windows_tool(tool)
    action = args.command
    script_names = {"project": "create_project.tcl", "synth": "synth.tcl", "xsim": "xsim.tcl"}
    script = ROOT / "scripts" / script_names[action]
    output = BUILD / ("vivado" if action == "project" else action)
    if action == "xsim":
        project_file = BUILD / "vivado" / "apb_spi_master.xpr"
        if not project_file.is_file():
            raise RuntimeError("Vivado project is missing. Run 'python scripts/run.py project' first.")
        script_args = [tool_path(ROOT, windows), str(args.seed)]
    else:
        script_args = [tool_path(ROOT, windows), args.part, str(args.fifo_depth), str(args.num_cs)]
    tool_args = [
        "-mode", "batch", "-nojournal", "-notrace",
        "-log", tool_path(output / "vivado.log", windows),
        "-source", tool_path(script, windows),
        "-tclargs", *script_args,
    ]
    if action == "synth":
        tool_args.append("1" if args.implement else "0")
    run(tool, tool_args, output, output / "console.log", args.dry_run)
    if not args.dry_run:
        # Vivado may return status 0 after a sourced Tcl error. Require both a
        # clean transcript and an explicit marker emitted after all Tcl work.
        transcript = (output / "console.log").read_text(encoding="utf-8", errors="replace")
        errors = re.findall(r"^\s*ERROR:.*$", transcript, flags=re.MULTILINE)
        if errors:
            raise RuntimeError(f"Vivado reported {errors[0].strip()}; see {output / 'console.log'}")
        marker = f"APB_SPI_TOOL_SUCCESS: {action}"
        if marker not in transcript.splitlines():
            raise RuntimeError(f"Vivado did not finish {action}; see {output / 'console.log'}")


def positive(value):
    result = int(value, 0)
    if result < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return result


def parse_args():
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog="Tool overrides: IVERILOG, VVP, VIVADO (executable paths). No dependencies are downloaded.",
    )
    subcommands = parser.add_subparsers(dest="command", required=True)
    sim = subcommands.add_parser("sim", help="compile and run one self-checking Icarus testbench")
    test = subcommands.add_parser("test", help="run FIFO, SPI engine, and parameterized APB regressions")
    synth = subcommands.add_parser("synth", help="Vivado OOC synthesis and reports")
    project = subcommands.add_parser("project", help="create a reopenable Vivado project in build/vivado")
    xsim = subcommands.add_parser("xsim", help="run Vivado behavioral simulation of the generated project")
    subcommands.add_parser("clean", help="remove only this project's build directory")
    for command in (sim, synth, project):
        command.add_argument("--fifo-depth", type=positive, default=16, help="FIFO depth, a power of two >= 2 (default: 16)")
        command.add_argument("--num-cs", type=positive, choices=range(1, 5), default=4, help="number of chip selects (default: 4)")
        command.add_argument("--dry-run", action="store_true", help="print tool commands without running them")
    sim.add_argument("--top", choices=("tb_apb_spi_master", "tb_apb_spi_corner", "tb_spi_shift", "tb_sync_fifo"),
                     default="tb_apb_spi_master", help="simulation top (default: tb_apb_spi_master)")
    test.add_argument("--dry-run", action="store_true", help="print tool commands without running them")
    xsim.add_argument("--dry-run", action="store_true", help="print tool commands without running them")
    for command in (sim, test):
        command.add_argument("--seed", type=lambda value: int(value, 0), default=1, help="testbench random seed (default: 1)")
        command.add_argument("--waves", action="store_true", help="request VCD output from the integration testbench")
    xsim.add_argument("--seed", type=lambda value: int(value, 0), default=1, help="testbench random seed (default: 1)")
    for command in (synth, project):
        command.add_argument("--part", default=DEFAULT_PART, help=f"FPGA part (default: {DEFAULT_PART})")
    synth.add_argument("--implement", action="store_true", help="also place/route OOC and check internal setup/hold slack")
    args = parser.parse_args()
    if hasattr(args, "fifo_depth"):
        depth = args.fifo_depth
        if depth < 2 or depth & (depth - 1):
            parser.error("--fifo-depth must be a power of two >= 2")
        if depth > 32768:
            parser.error("--fifo-depth must fit the 16-bit FIFO level register (maximum 32768)")
    return args


def main():
    args = parse_args()
    if args.command == "clean":
        if BUILD.is_symlink():
            raise RuntimeError("Refusing to clean a build directory that is a symbolic link.")
        if BUILD.exists():
            shutil.rmtree(BUILD)
        print(f"Cleaned {BUILD}")
    elif args.command == "sim":
        simulate(args)
    elif args.command == "test":
        regression(args)
    else:
        vivado(args)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        sys.exit(130)
