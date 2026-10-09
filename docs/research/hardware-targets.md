# Hardware targets: the reference machine and the first two arm64 boards

Date: 2026-10-09. Source: AbyssBSD's bring-up notes,
`/home/jkane/Projects/OS/AbyssBSD` (`docs/boards/radxa-dragon-q8b/`,
`docs/boards/orangepi-6-plus/`, `desktop/docs/API-STUDY.md`,
`desktop/docs/reports/q8b-bench-2026-10-01.md`). AbyssBSD is a FreeBSD
distribution that brought up both boards from 2026-09-25 by porting Linux's
drivers through LinuxKPI. Todhchai can't follow that route (principle 29),
but its findings about the hardware hold whatever OS runs on it. Claims
taken from those notes, which were verified on the boards, are tagged `[V]`.

The order (decided 2026-10-09): Todhchai works first on the amd64 reference
machine. The boards follow once that code works.

| Order | Machine | Why |
|---|---|---|
| 1 | **i7-12700KF + Radeon RX 6750 XT** (amd64) | AbyssBSD's test box; RDNA 2 is the best-documented GPU family; standard device classes |
| 2 | **Orange Pi 6 Plus** (CIX P1 "Sky1", arm64) | SystemReady-style ACPI, SCMI, mostly standard device classes |
| 3 | **Radxa Dragon Q8B** (Qualcomm SC8280XP, arm64) | Windows-on-Arm firmware: almost everything beyond NVMe, USB and the framebuffer is Qualcomm-specific |

---

## 1. Reference machine: i7-12700KF, RX 6750 XT

- **CPU:** Alder Lake, 8 P-cores (with SMT) and 4 E-cores, so 20 threads of
  two core types. "KF" means no integrated GPU: the UEFI GOP framebuffer
  comes from the Radeon's option ROM. `[V]` for the model; the core counts
  are Intel's published configuration `[K]`.
- **GPU:** RX 6750 XT, RDNA 2 (Navi 22). On FreeBSD it runs on drm-kmod
  (Linux 6.6 DRM) with RADV and radeonsi `[V]`.
- **IOMMU:** Intel VT-d. croi has no reference code for it (the Fuchsia
  snapshot has only an ARM SMMU driver; see item 14 in
  [croi-assessment.md](croi-assessment.md)).
- **Hybrid scheduling:** FreeBSD's ULE doesn't know the core types; the
  kernel reads them only for its own workarounds `[V]`. The same question
  that the arm64 boards raise (§4.4) is already present on the reference
  machine.
- **Frame pacing:** AbyssBSD's compositor missed 0 of 1800 flips at about a
  2 ms margin, after five fixes; composite cost p99 18–21 µs `[V]`.
- Still to record for the hardware list: the motherboard, its audio codec,
  its NIC, the NVMe drive, and the firmware's ACPI tables.

## 2. Orange Pi 6 Plus (CIX Sky1)

12 Armv9.2 cores: 4 A720 up to 2.6 GHz, 4 A720 up to 2.5 GHz, 4 A520, in
six frequency domains. 32 GB. Mali-G720 Immortalis MC10 (CSF). Linlon
(Arm China, "komeda") display controllers. Zhouyi NPU, Mali-V video codec,
two RTL8126 5 GbE, NVMe. The Radxa Orion O6 uses the same SoC.

**Firmware.** UEFI hands over ACPI only, with no devicetree. The tables are
written for an OS (unlike the Q8B's) `[V]`:
- power domains are ACPI power resources (`_PR0`/`_PR3`);
- clocks are AML methods that call the power-management firmware over
  **SCMI** (SCMI v2.0, protocols 0x13 performance and 0x14 clock);
- CPU performance is `_CPC` with SystemMemory registers (the SCMI
  fastchannel) and AMU counters;
- idle is `_LPI`: standby, core power-down (360 µs), cluster power-down
  (500 µs);
- 13 thermal zones with `_TMP`, `_PSV`, `_CRT`, `_PSL`.

The firmware enters the OS at **EL2**, with no vendor hypervisor; Linux runs
KVM there `[V]`.

**Standard devices** `[V]`: PCIe ECAM (3 root ports), NVMe, xHCI ×10 (ACPI
`PNP0D10` platform devices, not PCI), an HDA controller as an ACPI platform
device (`CIXH6020`) with a Realtek ALC269VC codec, 4 PL011/SBSA UARTs, an
SBSA generic watchdog, GICv3 + ITS (GICv4.1), a UEFI GOP framebuffer
(1920×1080 at `0x84800000`).

**Quirks and hazards** `[V]`:
- **No SPCR.** DBG2 names the console UART (COM2, PL011 at `0x40d0000`).
  The debug header is 3.3 V: UART2 is the BIOS and kernel log, UART4 the
  power-management firmware's.
- **The cores' generic timers stop in both power-down states**, and the GTDT
  has no memory-mapped timer. The only always-on wake timer is CIX's GPT
  (`CIXH1007`, 25 MHz).
- The firmware leaves `_LPI`'s "context lost" flag clear on its power-down
  states; the PSCI state's type bit is what tells.
- With SVE and VHE, the power-down path must also restore the SVE vector
  length (and EL2 state if the kernel stays at EL2).
- Linux applies a workaround for Arm erratum 2941627 (GIC).
- The SBSA watchdog's refresh frame doesn't refresh it; refresh through
  `WOR` instead. A driver that refreshes the standard way resets the board.
- The DSDT names objects that don't exist (`I2C0.UXC0`–`UXC3`).
- Some boots lose the HDA codec (not understood).

**IOMMU** `[V]`: two SMMUv3 instances (PCIe; display, NPU and others), with
IORT RMRs (identity regions that must stay mapped). Linux needed a fix for
an event-queue interrupt storm. Mapping DMA as **Device** memory made the
NPU ten times slower (7.2 ms against 0.68 ms an inference); it must be
Normal memory, write-back for coherent devices and non-cacheable for the
others.

**GPU** `[V]`: Mali-G720, CSF (Arm's firmware runs the command-stream
scheduler, from linux-firmware). Its own MMU, no SMMU. Nothing answers at
its registers until five steps are done in order, and any earlier read
hangs the bus (SError) and needs a power cycle:
1. SCMI power domain 21 on, over an SMC (`0xc2000001`);
2. clocks `gpu_top` and `gpu_core` through the SCMI agent at `CIXHA006`
   (the AML's own SCMI agent answers NOT_FOUND for them);
3. the power resource's `_ON` (memory repair);
4. a reset pulse;
5. Q-channel clock gating.

The DSDT says coherent, but CIX treats it as non-coherent: GPU mappings
non-cacheable, CPU mappings write-combining. DVFS is SCMI performance
domain 0 (72–1000 MHz). Arm publishes no Mali ISA.

**Display** `[V]`: Linlon DP ×5 plus a DP transmitter; HDMI is DP-4
through a PS185 bridge that passes no EDID. A separate device from the GPU,
behind the second SMMU.

**Video codec and NPU** `[V]`: Mali-V (4 cores, decode H.264/HEVC/VP9/AV1
and more, encode H.264/HEVC/VP8/VP9), **not behind an SMMU**: it has its own
MMU and takes 40-bit physical addresses, `_CCA` 0. Firmware per codec, no
licence file. The NPU (Zhouyi X2) drives 32 address bits and is
non-coherent.

**CPU placement** `[V]`: glmark2 under sway scored 711 as FreeBSD placed
the work (on little cores) and 2,600 pinned to big cores.

## 3. Radxa Dragon Q8B (Qualcomm SC8280XP)

4 Cortex-A78C and 4 Cortex-X1C (Armv8.2: NEON, no SVE). Adreno 690 GPU. Two
2.5 GbE on a Toshiba TC956x behind a PCIe switch. NVMe.

**Firmware** `[V]`: Qualcomm UEFI provides both ACPI and a DTB. The ACPI is
the Windows reference design's: every device `_DEP`s on PEP (`QCOM0617`),
the Windows power engine, and clocks, regulators, temperatures and power go
through it. There is **no `_CPC`, `_PSS` or `_TMP`**. So CPU frequency
(EPSS), temperature (TSENS), the GPU's clocks, the video codec's clocks and
RPMh votes are all SoC-specific drivers with register tables. The kernel
runs at **EL1** under Qualcomm's hypervisor, which owns stage 2.

**Hazards that reset the SoC with no dump** `[V]`:
- SMMU programming the hypervisor doesn't expect: a CBAR written with type
  0, SMR id/mask pairs other than Linux's, a GMU stream left unmatched.
- Reading a clock controller while its power domain is off.
- Shutting down a running DSP without the SMEM stop handshake (hangs).
- A DSP given an address without the stream ID's low bits above bit 32
  (hangs, no SMMU fault).

**Console** `[V]`: SPCR names a Qualcomm GENI UART (interface type 0x13,
`0x884000`) with an invalid access width and a wrong IRQ (the DSDT's
`UARD` has GSIV 615). The header pads are 1.8 V.

**Timers and idle** `[V]`: `_LPI` per CPU, cluster and system; core
power-down (C3) has a minimum residency of about 4 ms and an exit of about
910 µs. The per-core timers stop in power-down; the MMIO generic timer
(GTDT `0x17C20000`, GSIV 40) is always on, but its SPI doesn't wake a
powered-down core: AbyssBSD binds it to CPU 0 and never lets CPU 0 power
down.

**IOMMU** `[V]`: PCIe behind a firmware-reserved SMMUv3. Two MMU-500
(SMMUv2) instances, apps and GPU, whose stage 2 the hypervisor owns. UEFI
leaves identity banks for display, USB and PCIe in the apps SMMU: leave
them alone. The video codec's IOVA window is `0x25800000`–`0xe0000000`
(TrustZone protects the range below).

**Display** `[V]`: MDSS DPU → DP2 → a Chrontel CH7218A → HDMI. UEFI leaves
the pipeline running at 1080p60 on an HBR3 link. AbyssBSD's `msmfb` takes
that pipeline over instead of porting Linux's DPU and DP drivers: a flip
writes the SSPP address and a flush bit, vsync is INTF6's interrupt,
hotplug and EDID come over polled AUX, and mode changes follow Linux's
disable order exactly. **Scan-out buffers must be physically contiguous,
below 4 GB (32-bit SSPP address registers, display streams in SMMU
bypass) and write-combining.** After a 5-hour build left low memory
fragmented, every allocation failed until a 64 MB pool was reserved at boot.

**GPU** `[V]`: Adreno 690, its own SMMU with per-process page tables
(switched by the GPU's command processor), GMU firmware, and a zap shader
authenticated by TrustZone (SCM). Fully off at boot. Qualcomm publishes no
Adreno ISA.

**Everything else is behind DSPs and SMC calls** `[V]`:
- Audio goes through the ADSP (GLINK, GPR, AudioReach, SoundWire, a WCD938x
  codec). **Blocks must be whole milliseconds** (multiples of 48 frames at
  48 kHz); 1024-byte blocks buzzed at the block rate.
- USB-C orientation and DP alt mode are reported by the ADSP over GLINK
  (pmic_glink).
- **The fan is run by Radxa's firmware on the ADSP.** Until the OS starts
  the ADSP (TrustZone PAS, firmware from linux-firmware), the fan runs at
  full speed.
- The RTC is an M41T11 on I²C that ACPI doesn't describe; the DSDT's GPIO
  consumers are the reference design's and would misconfigure USB-C pins if
  applied.
- The NPU is the compute DSP, reached through FastRPC.

**Frame pacing and deep idle** `[V]`: with C3 allowed, the compositor
missed 4, 1 and 2 of 300 flips; with C1, none. The cause was the display's
vsync and the GPU's interrupt being routed to powered-down big cores, each
910 µs from waking. Binding both to the core that stays awake fixed it.

## 4. What this means for Todhchai

Each item names the design change it drove.

1. **GPU.** Neither Arm GPU has public ISA documentation, so under principle
   29 each is a reverse-engineering project with its own compiler back end.
   AMD stays the first and only GPU family through M8. On the boards, the
   desktop runs on the CPU path and the framebuffer first. On the Sky1,
   which gives the OS EL2, Todhchai in a KVM guest with a Venus client
   driver over the host's panvk is a way to get Vulkan on arm64 silicon
   early. Check first whether panvk on the G720 meets Prism's floor.
   ([roadmap.md](../roadmap.md) M10.)
2. **Display is its own device.** On both boards the display controller is
   a different device (and vendor) from the GPU. There is also a useful
   middle tier: taking over the pipeline UEFI left running.
   ([architecture.md](../architecture.md) §10, [desktop.md](../desktop.md)
   §1.)
3. **Power management.** Deep idle stops per-core timers, takes 360–910 µs
   to leave, and costs frames when device interrupts land on sleeping
   cores. Budgets measured in microseconds only hold at a known clock.
   ([architecture.md](../architecture.md) §8,
   [croi-requirements.md](../croi-requirements.md) items 2, 5 and §3.)
4. **Heterogeneous cores** on all three machines: P/E cores on the
   reference machine, three core types on the Sky1, two on the Q8B.
   (croi-requirements item 5.)
5. **DMA.** IOMMU-less DMA masters, non-coherent devices, address windows,
   per-device memory types, firmware-owned and hypervisor-policed IOMMUs.
   (architecture §9 and §17, croi-requirements items 3, 7 and 14.)
6. **Firmware calls.** SCMI over SMC, TrustZone firmware authentication.
   (croi-requirements item 13.)
7. **Firmware tables that are wrong.** A board database, as data, keyed on
   SMBIOS and SoC id. (architecture §9.)
8. **Audio periods** come from the device. (architecture §12.)
9. **Console:** DBG2 and the GENI UART. (croi-requirements item 1.)
10. **Fault containment** stops at the bus. (architecture §3 and §17.)
