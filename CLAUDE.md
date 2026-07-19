# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A port of the MiSTer MSX1 core to the MEGA65 FPGA computer, built on the
MiSTer2MEGA65 (M2M) framework. The FPGA design combines the MiSTer core
(SystemVerilog) with VHDL glue logic and a QNICE soft-CPU that runs the
on-screen menu / file browser firmware ("Shell") written in QNICE assembly.

Beware: this repo was forked from the C16/VIC20 M2M ports, so many comments,
strings, and docs still say "C16", "Plus4", or "VIC20" (e.g. `make_rom.sh`,
`tests/README.md`, `VERSIONS.md`, VHDL headers). They refer to this MSX1 core
unless context clearly says otherwise — don't treat them as meaningful.

## Build

There is no automated test suite and no CLI bitstream build script; the
bitstream is built from the Vivado GUI.

1. `git submodule update --init --recursive` — pulls `M2M/QNICE`
   (QNICE-FPGA, CPU + toolchain) and `CORE/MSX1_MiSTer`
   (https://github.com/piso77/MSX1_MiSTer, a fork of the MiSTer core,
   branch `spram`).
2. Build the QNICE toolchain (once): `cd M2M/QNICE/tools && ./make-toolchain.sh`
   (answer prompts with ENTER). Produces the `qasm`/`asm` assembler and
   `monitor.rom`.
3. Build the Shell firmware: `cd CORE/m2m-rom && ./make_rom.sh` →
   `m2m-rom.rom`. Vivado also runs this automatically before synthesis via
   the TCL.PRE hook `CORE/m2m-rom/synth_pre.tcl`.
4. Open `CORE/CORE-R6.xpr` in Vivado 2025.2 and run synthesis /
   implementation / bitstream. `CORE-R6` targets MEGA65 board revision R6
   (`CORE-R3.xpr` exists for R3); the top module is
   `M2M/vhdl/top_mega65-r6.vhd`.

Manual regression checklists live in `tests/` (with `Disk-Write-Test.d64`);
`doc/inofficial.md` tracks WIP build names vs. commits for regression hunting.

## Architecture

Two layers:

- `M2M/` — the MiSTer2MEGA65 framework (mostly don't touch): `vhdl/` has
  `framework.vhd`, per-board tops, the QNICE wrapper, virtual drives
  (`vdrives.vhd`), the HDMI/VGA video pipeline (`av_pipeline/`), and CDC
  helpers (`cdc_*.vhd`). `M2M/rom/` is the framework side of the Shell
  firmware. Per-board XDC constraints are here too.
- `CORE/` — everything MSX1-specific.

### CORE/vhdl — the glue layer

- `mega65.vhd` — core-side top. Bridges the M2M framework and the core, and
  defines the `C_MENU_*` OSM menu-index constants. Signal prefixes indicate
  clock domain: `qnice_*` (QNICE/Shell domain), `main_*` (core domain).
- `main.vhd` — wrapper that instantiates the MiSTer `msx1` SystemVerilog
  entity; runs entirely in the core clock domain.
- `config.vhd` — declarative OSM menu definition (`OPTM_*` constants, menu
  strings, `OPTM_SIZE`).
- `globals.vhd` — clock speeds (core clock is exactly 42_954_550 Hz — the
  core depends on exact values), virtual-drive count (`C_VDNUM`), manual
  cart/ROM slot count (`C_CRTROMS_MAN_NUM`), and the `QNICE_FIRMWARE`
  selector (release `m2m-rom.rom` vs. QNICE `monitor.rom` for firmware
  debugging over a serial terminal).
- `clk.vhd` — MMCM clock generation.
- `keyboard.vhd` — MEGA65 keyboard → MSX matrix.
- `prg_loader.vhd`, `crtrom_loader.vhd` — QNICE-attached loaders (via
  `qnice_csr`) that let the Shell stream cart ROM files into the core. The
  core uses 512KB BRAM instead of the MiSTer SDRAM controller.

### The VHDL ↔ firmware constant coupling

`CORE/m2m-rom/make_rom.sh` scrapes constants out of the VHDL with awk and
generates assembly includes before assembling `m2m-rom.asm`:

- `C_MENU_*` from `mega65.vhd` and `OPTM_G_*` from `config.vhd` →
  `osm_const.asm`
- `C_VDNUM` / `C_CRTROMS_MAN_NUM` from `globals.vhd` → `globals.asm`,
  `shell_fhandles.asm`, `shell_fh_ptrs.asm`

So whenever you change menu items or drive/ROM-slot counts in the VHDL, the
firmware must be rebuilt (the Vivado pre-synth hook handles this, but rerun
`make_rom.sh` manually if assembling standalone). Some indexes are
additionally hardcoded on the assembly side — e.g. `OPTM_G_LOAD_ROMA` in
`config.vhd` is duplicated in `CORE/m2m-rom/m2m-rom.asm` (see the comment at
its definition). The generated `.asm` files and `m2m-rom.{lis,out,rom,def}`
are build artifacts — never edit them by hand.
