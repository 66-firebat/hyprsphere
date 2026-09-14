# MCE Storm Recon — AMD Ryzen 7 PRO 6850H (Rembrandt, Family 19h Model 44h)

**Subject host:** `fireshark` — Tianbei/AMI `GT68` mini‑PC, BIOS `1.00` dated `2025‑06‑19`, NixOS 26.11, Linux `6.18.38`, CPU microcode `0xa40410a`, 16 logical CPUs / 8 cores, ~31 GiB usable RAM (`MemTotal` ≈ 32,114,752 kB).
**Trigger:** a continuous flood of corrected Machine Check Exceptions (MCEs) from CPU:0, UMC banks MC15–MC18, from boot onward.
**Scope:** decode the event from primary sources and propose a no‑code‑change diagnostic/remediation procedure. No system changes were made in producing it.

---

## Summary

The machine is an **AMD Ryzen 7 PRO 6850H = Rembrandt, Zen 3+, Family 19h Model 44h (0x44), FP7/FP7r2 APU** — *not* a Ryzen 7000/8000 AM5 desktop part (those are different Family 19h models). CPU:0 is reporting a **corrected (UC=0, CECC) error from one of the four Unified Memory Controller (UMC) instances**; the kernel’s AMD decoder prints **“Unified Memory Controller Ext. Error Code: 12”** (XEC = 12). Critically, the Linux kernel treats a UMC error as a **DRAM ECC memory error only when XEC == 0**; **XEC 12 is not defined in any public UMC error‑code table (kernel or rasdaemon) and therefore cannot be attributed to a DRAM row/rank/DIMM from public sources (confidence: Low)**. The on‑host SMCA threshold counters corroborate that the hardware itself files these under the **`misc_umc`** (non‑DRAM) block while `dram_ecc` stays at 0. Because the same status is reported by **all four UMC instances** continuously, a systematic platform/BIOS‑training or link‑margin cause is more likely than four independently failing DIMMs; the storm is nonetheless a real hardware‑error signal that should be worked up with a BIOS/AGESA update and MemTest86+. Memory is soldered LPDDR5, so module isolation is impossible and the hardware remedy is the mini‑PC vendor.

---

## 0. What is actually running (observed on the host)

| Item | Observed value |
|---|---|
| CPU | `AuthenticAMD`, family `25` (0x19), model `68` (0x44), stepping `1`, microcode `0xa40410a`, 8C/16T |
| Kernel | `6.18.38 #1-NixOS SMP PREEMPT_DYNAMIC` |
| Board / BIOS | DMI product `GT68`, board `GT68`, BIOS `1.00`, date `06/19/2025` |
| MCE volume | `journalctl -k -b \| grep -c "Hardware Error"` = **42,462 lines this boot**; peaks ~**1,920 lines/min (~32 lines/s)** |
| Reporting CPU | `CPU:0` only |
| Banks | `MC15_STATUS` … `MC18_STATUS`, all `0xdc204000000c011b` |
| SMCA sysfs | `/sys/devices/system/machinecheck/machinecheck0/umc_0` … `umc_3` |
| UMC counters | `umc_*/misc_umc/error_count = 4095` (saturated at `threshold_limit`), `umc_*/dram_ecc/error_count = 0` |
| EDAC | `EDAC MC: Ver: 3.0.0` loaded, but `/sys/devices/system/edac/mc` has **no `mcX` devices** |
| DMI memory | 4 × DMI Type‑17 records (4 memory‑device entries) |
| Memory form factor | **Soldered onboard LPDDR5 (confirmed by owner)** — no SO‑DIMM slots; no user‑replaceable memory |
| Installed RAS tools | `rasdaemon`/`ras-mc-ctl`/`mcelog`/`edac-util` **not installed**; `lshw` present but shows no DIMM detail as non‑root |

Representative raw lines (verbatim, first burst on this host):

```
[Hardware Error]: Corrected error, no action required.
[Hardware Error]: CPU:0 (19:44:1) MC15_STATUS[Over|CE|MiscV|AddrV|-|-|SyndV|CECC|-|-|-]: 0xdc204000000c011b
[Hardware Error]: Error Addr: 0x000000003079f1c0
[Hardware Error]: IPID: 0x0000009600050f00, Syndrome: 0x000001bc0a258401
[Hardware Error]: Unified Memory Controller Ext. Error Code: 12
[Hardware Error]: cache level: L3/GEN, tx: GEN, mem-tx: RD
```

The four banks always report the same status value but *different* addresses that are frequently **consecutive cache lines within the same page** (e.g. `0x…f7ce8b00`, `0x…f7ce8bc0`, `0x…f7ce8b40`), which is a burst/stream signature rather than isolated random bit flips.

**Episodic, not constant (observed 2026‑09‑13).** On this boot the storm started **14:33:57** (~5 min 32 s after boot), ramped to a plateau of **240 events/min = one per UMC per second** by 15:09, ran until ~16:18, then **stopped on its own** — no further MCEs for 3+ hours (last event 16:30:49). Other boots range from a **single 28‑line burst** (boot −4, then ~35 h quiet) to **2,045,239 lines** (boot −1). The storm is therefore **intermittent and boot‑dependent**, which argues against a permanently dead DRAM cell and for a memory‑training/margin/firmware condition — or an intermittent reporting path. Practical consequences: (a) a quiet period does **not** prove a fix, so any change must be judged over multiple boots/episodes; (b) a **continuous recorder (rasdaemon)** is needed so the next episode is captured with full decode data.

---

## What the error means

### 1. The reporting banks: MC15–MC18 are the four UMC instances
- With Scalable MCA (SMCA), bank *names* come from the bank’s **MCA_IPID**, not the bank index. The four IPIDs are `0x0000009600050f00` (MC15), `0x0000009600150f00` (MC16), `0x0000009600250f00` (MC17), `0x0000009600350f00` (MC18).
- Decoding with the kernel’s macros (`MCI_IPID_HWID = 0xFFF`, `MCI_IPID_MCATYPE = 0xFFFF0000`, `HWID_MCATYPE()`): **HWID = `0x096`, MCAType = `0x0`**, which maps to **`SMCA_UMC` (“Unified Memory Controller”, UMC v1)** in `smca_hwid_mcatypes[]`. `smca_long_names[SMCA_UMC] = "Unified Memory Controller"` is exactly the string printed. **Confidence: High.**
- The kernel exposes one sysfs directory per UMC instance (`get_name()` → `smca_get_name()` = `"umc"`, suffixed with the per‑type `sysfs_id`); the host shows **`umc_0..umc_3`**, i.e. four UMC instances. **Confidence: High.**
- Channel number is `IPID[31:0] >> 20` (rasdaemon `find_umc_channel()`): the four banks give `[31:20] = 0,1,2,3`, so **MC15→channel 0 … MC18→channel 3**. **Confidence: High for the field decode; Medium that “channel” equals a physical DIMM channel on Rembrandt.**
- AMD’s own `amd64_edac` enablement patch for Family 19h models 40h–4Fh states Rembrandt has **“4 memory controllers”** (`pvt->max_mcs = 4`). **Confidence: High.**

> Correction to the original premise: **Family 19h model 0x44 is Rembrandt (Ryzen 6000 mobile, FP7/FP7r2), not Ryzen 7000/8000 AM5.** AMD’s patch maps “family 19h with models 40h–4fh” to “Ryzen 6000 CPUs/APUs (‘Rembrandt’)”. **Confidence: High.**

- AMD’s EDAC driver states *“The CPUs have one channel per UMC, so UMC number is equivalent to a channel number.”* Rembrandt’s platform documentation (Ryzen Embedded V3000, same Family 19h 40h–4Fh silicon) describes **two DDR5 channels**; with DDR5’s two 32‑bit sub‑channels per channel that is **4 sub‑channels = 4 UMCs**, matching MC15–MC18 and a 128‑bit total data bus. **Confidence: High for “one UMC per channel/instance”; Medium that each UMC maps 1:1 to a physical module sub‑channel.**

### 2. MCi_STATUS = `0xdc204000000c011b` decoded
Bit definitions are the masks the running kernel actually uses (`arch/x86/include/asm/mce.h`), cross‑checked against the decoder (`drivers/edac/mce_amd.c`) and rasdaemon’s SMCA header comment.

| Bit(s) | Field | Value here | Meaning | Confidence |
|---|---|---|---|---|
| 63 | `VAL` | 1 | Status valid | High |
| 62 | `OVER` | 1 | Overflow: earlier errors were lost (true count > logged) | High |
| 61 | `UC` | 0 | **Corrected** error | High |
| 60 | `EN` | 1 | Error type enabled in MCi_CTL | High |
| 59 | `MISCV` | 1 | MCi_MISC register valid | High |
| 58 | `ADDRV` | 1 | MCi_ADDR register valid | High |
| 57 | `PCC` | 0 | Processor context not corrupt | High |
| 56 | `S` | 0 | Kernel: “Signaled machine check” (AMD: implementation‑specific) | High |
| 55 | `TCC` (AMD) / `AR` | 0 | AMD task‑context‑corrupt; not set | High |
| 54 | `PADDRV` | **0** | Address is **not** flagged as a valid system physical address | High |
| 53 | `SYNDV` | 1 | Syndrome register valid (kernel prints it) | High |
| 52:38 | `CEC` | `0x100` | Corrected‑error‑count field | Medium |
| 46 | `CECC` | **1** | Corrected ECC event (see §7/§8) | High |
| 45 | `UECC` | 0 | No uncorrected ECC | High |
| 44 | `Deferred` | 0 | Not a deferred error | High |
| 43 | `Poison` | 0 | No poison consumption | High |
| 40 | `Scrub` | 0 | Not a scrub‑detected error | High |
| 31:16 | **XEC / “Ext. Error Code”** | `0x000c` = **12** | AMD “ErrCodeExt” = status[21:16]; see §4 | High (value) / Low (meaning) |
| 15:0 | `MCACOD` | `0x011b` | Generic AMD memory‑error signature; see §5 | High |

Notes:
- The kernel reads the extended code as `XEC(m->status, xec_mask)` with `xec_mask = 0x3f` for SMCA, i.e. **bits [21:16]**; the commit that introduced UMC v2 decoding describes the same field as **`ErrCodeExt[20:16]`**. Both give **12** here. **Confidence: High.**
- `OVER=1` every time: the bank overflows faster than it drains, so the logged count under‑reports reality.
- `PADDRV=0`: `amd_mce_usable_address()` returns false for UMC errors unless `PADDRV` (or poison) is set, so **the printed `Error Addr` is not guaranteed to be a system physical address you can map to a DIMM byte**. **Confidence: High for the rule; Medium for what the raw address is.**
- Generic bits VAL/OVER/UC/EN/MISCV/ADDRV/PCC are architectural (AMD64 APM Vol. 2, doc 24593; the task brief’s “APM Vol. 3” is a misattribution). AMD SMCA additions TCC[55], PADDRV[54], SYNDV[53], DEFERRED[44], POISON[43], SCRUB[40] and the MCA_SYND MSRs are from AMD’s SMCA/PPR documentation. **Confidence: High for the kernel masks; Low for the exact APM (published sources conflict) “Other Information” bit range (56, 54:45, 42:32), which could only be read via a PDF search‑index snippet.**

### 3. The status flag string `[Over|CE|MiscV|AddrV|-|-|SyndV|CECC|-|-|-]`
Built by `amd_decode_mce()` (`drivers/edac/mce_amd.c`) in this exact order (matching commit `a0bcd3c`, “Decode MCA_STATUS in bit definition order”):

| Position | Printed | Source bit / rule |
|---|---|---|
| 1 | `Over` | `MCI_STATUS_OVER` (62) |
| 2 | `CE` | `UC` (61) clear and not `Deferred` (44) |
| 3 | `MiscV` | `MISCV` (59) |
| 4 | `AddrV` | `ADDRV` (58) |
| 5 | `-` | `PCC` (57) clear |
| 6 | `-` | `TCC` (55) clear (printed only when SMCA + `MCA_CONFIG[MCAX]`) |
| 7 | `SyndV` | `SYNDV` (53) |
| 8 | `CECC` | `ecc = (status >> 45) & 0x3`; `2 → CECC`, `1 → UECC` |
| 9 | `-` | `Deferred` (44) clear |
| 10 | `-` | `Poison` (43) clear |
| 11 | `-` | `Scrub` (40) clear |

**Confidence: High.** This pins the ECC encoding: `MCA_STATUS[46:45]` is a 2‑bit field where `0b10` = corrected ECC (**bit 46 = CECC**), `0b01` = uncorrected ECC (**bit 45 = UECC**), `0b11` = deferred.

### 4. “Unified Memory Controller Ext. Error Code: 12”
- The line is emitted by `decode_smca_error()`: `pr_emerg(HW_ERR "%s Ext. Error Code: %d", smca_get_long_name(bank_type), xec)`. **Confidence: High.**
- **What the number means is the weak point. The evidence:**
  - The kernel treats a UMC error as a **DRAM ECC memory error only when `XEC == 0`**: `smca_mce_is_memory_error()` returns true only for `SMCA_UMC`/`SMCA_UMC_V2` with `XEC == 0`, and `decode_smca_error()` only invokes the DRAM address decoder under that same condition. **By the kernel’s own logic, `XEC=12` is explicitly *not* a DRAM ECC event.** **Confidence: High.**
  - The pre‑removal kernel UMC **v1** table (`smca_umc_mce_desc[]`) defines **codes 0–7**: 0 DRAM ECC, 1 Data poison, 2 SDP parity, 3 Advanced peripheral bus error, 4 Address/Command parity, 5 Write data CRC, 6 DCQ SRAM ECC, 7 AES SRAM ECC. **XEC 12 is out of range.** **Confidence: High.**
  - The pre‑removal kernel UMC **v2** table (`smca_umc2_mce_desc[]`) defines **codes 0–11**: 0 DRAM ECC, 1 Data poison, 2 SDP parity, 3 Reserved, 4 Address/Command parity, 5 Write data parity, 6 DCQ SRAM ECC, 7 Reserved, 8 Read data parity, 9 Rdb SRAM ECC, 10 RdRsp SRAM ECC, **11 LM32 MP errors**. **XEC 12 (0xC) is out of range here too** — note this is *not* the “LM32 MP errors” entry, which is index 11 (0xB). **Confidence: High.**
  - rasdaemon’s maintained UMC v1 table extends to **codes 0–11** (8 ECS Row Error, 9 ECS Error, 10 UMC Throttling Error, 11 Read CRC Error). **XEC 12 is still out of range**, so even rasdaemon prints only the raw code. The same numeric index means *different* things in the v1 and v2 tables — direct proof that XEC values are not portable and must be read per family/model/die. **Confidence: High.**
  - The only table that defines index 12 at all is rasdaemon’s `smca_umc_quirk_mce_desc[]`, used **only for Family 19h models 90h–9Fh** (MI300 class), where index 12 = “Reserved”. Model 44h is **not** in that fix‑up. **Confidence: High.**
  - The kernel removed these tables precisely because of mis‑decoding: *“…on some AMD systems some of the existing bit definitions in the CTL register of SMCA bank type are reassigned without defining new HWID and McaType. Consequently, the errors whose bit definitions have been reassigned in the CTL register are being erroneously decoded.”* An out‑of‑table XEC such as 12 can therefore be an **undocumented or reassigned code**. **Confidence: High for the mechanism; Low for what condition code 12 denotes on model 44h.**
- **Conclusion:** for this exact part, **XEC 12 has no public, authoritative meaning that this research could locate.** Do **not** read it as “DRAM ECC” and do **not** read it as “link/PHY” — either claim is unsupported. This is the single biggest unknown in the document. **Confidence: Low.**

- **Public PPR availability:** AMD does publish some Family 19h PPRs publicly (e.g. **doc 56569**, PPR for Family 19h Model 51h, on `docs.amd.com`), but **no public download of the Family 19h Models 40h–4Fh (Rembrandt) PPR was found** in this research; it appears to be NDA / AMD‑account‑gated. That is the direct reason the model‑44h UMC error‑code table (and therefore XEC 12) cannot be quoted here. **Confidence: Medium–High that the 40h–4Fh PPR is not publicly available; High that XEC 12 is absent from all public decoders.**

### 5. `cache level: L3/GEN, tx: GEN, mem-tx: RD`
Decoded from the low 16 bits (`MCACOD = 0x011b`) by `amd_decode_err_code()` using macros in `drivers/edac/mce_amd.h`:

| Field | Macro | Value | Text |
|---|---|---|---|
| `MEM_ERROR(x) ((x & 0xFF00) == 0x0100)` | memory‑error class | true | enables `mem-tx` |
| `LL(x) = x & 0x3` | cache level | 3 | `L3/GEN` |
| `TT(x) = (x>>2) & 0x3` | transaction type | 2 | `GEN` |
| `R4(x) = (x>>4) & 0xf` | memory transaction | 1 | `RD` |

So: **a generic memory read hit the UMC’s memory‑error path, and the cache‑level field carries the generic `L3/GEN` encoding.** For AMD memory/UMC errors this is a standard catch‑all signature (the same `0x011b` appears in AMD’s own MI300 example logs), **not** evidence the L3 cache is faulty. **Confidence: High.**

### 6. What a “corrected read from the UMC” means physically
- The UMC sits between the CPU/Infinity Fabric and the DRAM PHY. It performs DRAM ECC generation/checking, address/command parity, DDR5 link CRC on reads/writes, and maintains internal SRAM (e.g. DCQ) with ECC.
- `UC=0` + `CECC=1` means **the UMC detected an error on a memory read and corrected it in hardware before handing data to the requester**; no data corruption is expected and no kernel action is required — exactly what “Corrected error, no action required.” states.
- “Corrected” does **not** mean “harmless forever”: a rising corrected rate is a leading indicator of a marginal link/DIMM, and `OVER=1` shows the bank is saturating. **Confidence: High (architectural behavior).**

### 7. Syndrome values
Observed (samples from this host and from the reported stream): `0x000001690a248101`, `0x0000010c0a240481`, `0x0000017b0a250301`, `0x0000018b0a240301`, `0x000001db0a248301`, `0x000001fe0a248601`, plus host samples `0x000001bc0a258401`, `0x000001de0a240601`, `0x000001130a258380`, `0x000001f70a248700`.

| Field of the 64‑bit syndrome | Observed behaviour |
|---|---|
| `[63:32]` | varies (≈ `0x010c`–`0x01fe`) |
| `[31:16]` | nearly constant (`0x0a24` / `0x0a25`) |
| `[15:0]` | varies (`0x8101`, `0x0481`, `0x0301`, `0x8301`, `0x8601`, `0x8401`, `0x0601`, …) |

- **The only documented UMC syndrome semantics apply to the `XEC == 0` corrected‑DRAM‑ECC path**, in `drivers/edac/amd64_edac.c` (`decode_umc_error()`): channel from `IPID[31:20]`, `csrow = synd & 0x7`, and for corrected ECC (`ecc_type == 2`) a length in `synnd[23:18]` with the syndrome value in `synnd[63:32]` masked to that length. The syndrome is read only when `SYNDV` is set (`MISCV` validates MCi_MISC, **not** the syndrome). **Confidence: Medium–High (quoted from the AMD EDAC driver).**
- **Applying that documented layout to these values is suggestive but not conclusive:** `[23:18]` is consistently 9, and `[63:32]` fits a 9‑bit value, while `[2:0]` is almost always `1`. That is structurally similar to a corrected‑DRAM‑ECC syndrome — yet the kernel and rasdaemon both refuse to treat `XEC != 0` as DRAM ECC. **This contradiction is unresolved and should be put to AMD directly.** Do **not** conclude from it that these are DRAM ECC errors. **Confidence: Low.**
- The kernel’s removed UMC syndrome decoder and the in‑tree `drivers/ras/amd/atl/umc.c` (MI300/DRAM‑ECC address formats only) provide no UMC‑v1/model‑44h syndrome definitions. Next step: feed the raw `--status/--ipid/--synd` to `rasdaemon -p … --smca --family 0x19 --model 0x44` and raise it with AMD/vendor support.

### 8. Does `CECC` imply ECC DIMMs? On‑die vs side‑band
- **No.** `CECC` (MCA_STATUS[46]) means the UMC corrected *an* error. Public UMC error tables show many corrected sources that are **not** side‑band DRAM ECC: SDP parity, APB error, address/command parity, **write data CRC**, **read CRC**, **DCQ SRAM ECC**, **AES SRAM ECC**, ECS row errors. A CECC flag by itself cannot prove ECC UDIMM/SODIMMs are installed. **Confidence: High.**
- **On‑die ECC (DDR5 ODECC)** is internal to each DRAM die and normally transparent; DDR5 also carries link CRC/ECS. Where AMD surfaces on‑die ECC, it goes through the UMC path (AMD/MI300 material shows rasdaemon labelling UMC `XEC 0` as “DRAM On Die ECC error”), but **no public definition was found for how/whether Rembrandt reports ODECC as a specific XEC**. **Confidence: Low for Rembrandt specifics.**
- **Side‑band ECC** is the classic ECC UDIMM path and yields the “DRAM ECC error” (`XEC 0`) class. Because this event is `XEC 12`, the ECC‑DIMM question is largely moot for *this* error.
- **Platform context:** AMD’s Family 19h Models 40h‑4Fh platform documentation (Ryzen Embedded V3000, same silicon) specifies **two DDR5 channels** (LPDDR5 on mobile SKUs), and the AMD EDAC driver notes one channel per UMC — so the four UMCs are best read as 2 channels × 2 sub‑channels. **No AMD source found documents side‑band ECC SO‑DIMM support on Rembrandt**; the reasonable working assumption is DDR5 on‑die ECC plus link CRC only. **Confidence: Medium (negative finding).**
- **Bottom line:** the storm is **not** evidence that ECC DIMMs are installed, and installing ECC DIMMs is not obviously a fix. To learn whether the box has ECC modules, read DMI Type‑16/17 as root (`sudo dmidecode -t 16,17`) or use a 7.1+ kernel’s EDAC `dimm_label`. **Confidence: High for the logic; Low for this box’s actual DIMM type.**

---

## Likely root causes (ranked)

Ranking is by how well each fits the *whole* pattern: corrected, `XEC 12`, non‑DRAM `misc_umc`, identical across **all four** UMC instances, continuous from boot, same physical pages.

1. **Platform/BIOS‑AGESA memory‑training or UMC‑configuration defect (systematic). — Most likely.**
   Fit: identical status from four independent UMCs; onset at boot; out‑of‑table XEC; recent AMI BIOS; the generic memory‑read signature. A training/configuration problem routes errors through a common path and hits all channels.
   Against: unproven without the PPR and a BIOS changelog.
   Confidence: **Medium.**

2. **Marginal DRAM link / module seating‑contact / SPD problem (training margin).**
   Fit: continuous correctable read errors, `AddrV` but `PADDRV = 0`; CRC/parity‑class UMC errors are exactly what a marginal DDR5 link produces. Mini‑PCs with high‑density modules are prone to seating and signal‑integrity margin issues.
   Against: would more typically localise to one channel, not all four.
   Confidence: **Medium.** (If the memory is soldered LPDDR5, “seating” is not user‑serviceable and the unit goes to vendor RMA.)

3. **Failing DIMM or failing CPU integrated memory controller (IMC).**
   Fit: any persistent corrected‑error stream can be a dying device.
   Against: four UMCs reporting the *same* status simultaneously is an odd signature for one DIMM; a failed IMC usually shows broader instability, not only corrected reads.
   Confidence: **Low–Medium.** (Keep on the list until isolation testing says otherwise.)

4. **Firmware reporting artifact / undocumented or reassigned UMC error code.**
   Fit: XEC 12 is undefined for this model in every maintained table; the kernel stopped trusting these tables because codes get reassigned; an identical status repeated *ad infinitum* is the classic look of a reporting bug; the `misc_umc` counter sitting exactly at the threshold (`4095`) also fits a threshold/notification artefact.
   Against: the kernel does not filter this code as bogus for model 44h (only Cezanne A0 has such a filter), and `EN=1`/`OVER=1` imply a genuine enabled event source.
   Confidence: **Low–Medium.**

5. **Memory overclock profile (EXPO/XMP/DOCP), timings, or voltage/clock desync (VDDIO/VDDQ, VSOC/VDDCR_SOC/VDDP, FCLK/UCLK/MCLK).**
   Fit: overclocked/mis‑trained memory is the classic cause of correctable ECC storms, and disabling the OC profile is the cheapest test.
   Against: this is a locked OEM AMI BIOS on a mini‑PC; EXPO/DOCP may not be exposed, and the storm begins at boot before any user tuning.
   Confidence: **Low** for this specific box, but the test is cheap.

> Ranking note: causes 1–4 are not mutually exclusive. The fastest way to separate them is a BIOS update + a kernel A/B + MemTest86+, as below.

---

## Lowest-hanging fruit (do these before any reboot)

Memory form factor is settled — **soldered onboard LPDDR5, no SO‑DIMM slots** — so there is no physical remediation path. Two steps decide the plan and cost almost nothing:

1. **Check for a newer vendor BIOS than `1.00 (2025‑06‑19)`** on the AOOSTAR/Tianbei GT68 support page (`fwupdmgr` found none via LVFS). If a newer **`RembrandtPI‑FP7`** build exists, it is the leading fix (Cause 1).
2. **Capture the RAM details for the RMA file:** `sudo dmidecode -t 16,17` (sizes/speeds/part numbers/ECC reporting). It no longer chooses a path — with soldered memory the only paths are firmware fixes or vendor RMA — but it documents what shipped.

Still no reboot: install **rasdaemon**, snapshot the evidence (`journalctl -k`, the `umc_*/{misc_umc,dram_ecc}` counters, current MCE count) so every later test has a "before" baseline.

The cheapest **fix attempt** is then one BIOS visit: **load optimized defaults → disable PFEH → disable EXPO/XMP/DOCP → save → clear CMOS/retrain.** That tests Cause 1 and Cause 5 without needing new firmware.

---

## Cause-by-cause approach

For each ranked cause: the cheapest discriminating move, cost/risk, and what each outcome means.

### Cause 1 — Platform/BIOS‑AGESA memory‑training or UMC‑configuration defect *(leading hypothesis)*
- **Approach:** flash the latest vendor BIOS (`RembrandtPI‑FP7`, never an AM5 `ComboAM5PI` image); load defaults; **disable PFEH** (it can suppress ECC reporting); disable EXPO/XMP/DOCP; clear CMOS and let memory retrain; observe 1–2 boots.
- **Cheapest first step:** confirm a newer BIOS exists (see above).
- **Cost/risk:** one reboot; low risk with a vendor BIOS; reversible via re-flash / CMOS clear.
- **Outcomes:** storm stops → confirmed and fixed. Unchanged → hypothesis weakened; move to Cause 2/4.
- **Why first:** the only step that can *fix* rather than characterize, and the best fit for "all four UMCs identical."

### Cause 2 — Marginal DRAM link / contact / SPD / training margin
- **Approach:** **memory is soldered LPDDR5 — there is no physical remediation** (nothing to reseat, clean, or swap). Address it only indirectly: a BIOS/AGESA update and JEDEC defaults (Cause 1) can improve link/training margin, and MemTest86+ (Cause 3) characterizes whether the memory path is actually failing. A genuine soldered‑memory/PHY link fault ends at the **vendor RMA path**.
- **Cost/risk:** no physical cost; one reboot for the firmware/training attempt.
- **Outcomes:** storm stops after BIOS/defaults → training/margin issue resolved. Persists → soldered‑memory/board fault or a reporting artifact (Cause 4), both handled through the vendor.

### Cause 3 — Failing DIMM or failing CPU memory controller (IMC)
- **Approach:** MemTest86+ **v7.00+** booted with the **`ecc`** option, **≥4 passes / overnight**; keep rasdaemon running to correlate. With soldered memory there is **no stick/slot isolation step** — it can confirm/deny a memory‑path fault, not localize it to a replaceable part.
- **Decision rule:** a MemTest86+ failure on soldered memory → **vendor RMA of the whole unit** (there is no module to replace). A pass is not a clean bill of health for an intermittent fault, so repeat.
- **Cost/risk:** one reboot + several hours; low risk.
- **Caveat:** because `dram_ecc = 0`, MemTest86+ **may pass** — and that is informative: it pushes the diagnosis back toward firmware/link/reporting rather than dead DRAM cells.

### Cause 4 — Firmware reporting artifact / undocumented reassigned UMC code
- **Approach:** (a) **A/B one different kernel** (a Linux 7.1 build exists in the store) and compare MCE rate/counters — a material change implicates the kernel/decoder; (b) **file raw evidence with AMD + the mini‑PC vendor** (status, IPID, syndrome, `misc_umc` vs `dram_ecc` counters, DMI memory data) and explicitly request the **F19h 40h–4Fh UMC error‑code table for XEC 12**; (c) if confirmed cosmetic, decide between accepting it with log suppression or pressing for a fixed BIOS.
- **Cost/risk:** one reboot for the A/B; the ticket costs only effort. No data risk.
- **Outcomes:** you learn code 12's meaning / get a fixed BIOS, or you establish it is benign‑but‑noisy and mitigate deliberately.

### Cause 5 — Memory overclock profile / timings / voltages
- **Approach:** covered by Cause 1 ("load defaults + disable EXPO/XMP/DOCP"). Do **not** tune VSOC/VDDIO/VDDP on this locked FP7 OEM BIOS without vendor guidance and a published safe range.
- **Cost/risk:** free if the options exist; wrong voltages are genuinely risky.
- **Outcome:** storm stops at JEDEC → done; otherwise crossed off.

### Recommended execution order

| # | Action | Reboot? | Rules in / out |
|---|---|---|---|
| 0 | BIOS availability check + `dmidecode -t 16,17` + rasdaemon/evidence snapshot | no | is a BIOS fix available; document soldered memory for RMA |
| 1 | BIOS defaults + PFEH off + EXPO off + CMOS clear/retrain | yes | Cause 1, Cause 5 |
| 2 | Observe 1–2 boots; if persistent, kernel A/B (Linux 7.1) | yes | Cause 4 |
| 3 | MemTest86+ (4+ passes, `ecc`); no stick isolation (soldered) | yes | Cause 2, Cause 3 |
| 4 | AMD/vendor report with raw evidence | no | Cause 4 (code‑12 definition) |
| 5 | Vendor RMA if persistent on latest firmware / memtest fails | — | definitive hardware resolution |
| 6 | Journald `SystemMaxUse` cap now; `mce=dont_log_ce`/`ignore_ce` only as last resort | no | mitigation only; hides growth |

**Lowest hanging fruit:** step 0 (BIOS availability + evidence capture; no risk). **Cheapest fix attempt:** step 1 (one reboot, no new firmware needed). **Most decisive for hardware:** step 3.

---

## Diagnostics to run (no code changes)

### A. Capture and preserve the evidence (first)
1. Snapshot the current evidence:
   - `journalctl -k -b | grep -E "Hardware Error|Machine check" > ~/mce-capture-$(date +%F).log`
   - `dmesg > ~/dmesg-$(date +%F).log` (root)
   - `sudo dmidecode -t 16,17 > ~/dmi-memory.txt` — names sizes, speed, part numbers, and ECC reporting. Memory is **soldered LPDDR5**, so this is for the RMA record, not a reseat plan.
   - Archive `/sys/devices/system/machinecheck/machinecheck0/umc_*/{dram_ecc,misc_umc}/{error_count,threshold_limit,interrupt_enable}`.
2. Install **rasdaemon** (NixOS: enable `services.rasdaemon` or `nix-shell -p rasdaemon`). It **persists** MCEs to a SQLite DB and decodes AMD SMCA. Current upstream CLI is grouped: `sudo rasdaemon --foreground [--record]`; `ras-mc-ctl db --summary|--errors`; `ras-mc-ctl dimm --status|--layout|--error-count [--per-rank]|--guess-labels|--register-labels|--print-labels` (legacy ≤0.8.5 Perl used top‑level `--summary`/`--errors`/`--layout`). Offline decode: `rasdaemon -p --status <status> --ipid <ipid> --smca [--family 0x19 --model 0x44 --bank <n>]`. Note: `ras-mc-ctl --error-label` is **not** an upstream option — attach a label via `dimm --register-labels` / `dimm_label`. Use rasdaemon to translate `IPID → memory_channel=%d, csrow=%d`.
3. **The localization limit on this kernel:** `amd64_edac` support for Family 19h models 40h–4Fh landed only around **Linux 7.1** (and was AUTOSEL’d to 7.0/6.19), so this **6.18.38** kernel has **no `/sys/devices/system/edac/mc/mcX/dimmY` nodes** and cannot print a DIMM label — exactly as observed. No rasdaemon/edac‑util setting creates them. Until a 7.1+ (or backport‑carrying) kernel is running, localization is at **channel + csrow** granularity; with soldered memory that is RMA evidence only, not a replaceable‑module location. EDAC hardware error *injection* exists only for families ≤0x16, so it is unavailable on Zen.
4. Remember **lock‑step / mirroring**: ras.rst warns that in these modes “there’s no way to know what memory module is to blame,” so a channel/csrow hit may implicate more than one module until a swap test is done.

### B. Memory testing
- **MemTest86+ (free, UEFI, <https://www.memtest.org/>)** — the reference independent test. Run at least **one full pass**; for an intermittent fault run **4+ passes / several hours** (overnight ideal). Any red “Errors” line is a failure (no published numeric tolerance). ECC polling exists only in **v7.00+**, only with the **`ecc` boot option**, and only on *selected* AMD Ryzen CPUs — so **absence of reported ECC errors does not prove the module is clean** (on‑die ECC can silently correct flips).
- **MemTest86 (PassMark, free edition, <https://www.memtest86.com/>)** — default **4 passes** (~15 min/pass in their example). ECC *reporting* is in the Free edition; ECC *injection* is Pro‑only and disabled on most AMD retail CPUs. Before trusting “no ECC errors”, check the BIOS setting **“Platform First Error Handling” (PFEH)** — PassMark documents that PFEH can prevent ECC errors from being reported to tools, and it should be **disabled** for testing.
- **OS‑level stress (complements, does not replace, MemTest86+):**
  - `stressapptest` (<https://github.com/stressapptest/stressapptest>): **`-M` = memory size in MB**, **`-s` = seconds**, `-m` = number of copy threads (do **not** use `-m` for size). Example: `stressapptest -W -s 3600 -M 28000`. No official recommended runtime; ~1 h+ is reasonable.
  - **Prime95** “Large FFTs” / “Blend”: official guidance is **6–24 h**; the vendor docs note that a Blend failure with smaller‑FFT passes points at memory/IMC.
  - **y‑cruncher** stress tests (e.g. VT3) exercise the memory path; no official duration.
  - A **failure = any reported mismatch, crash, or a rise in the MCE rate** under load. A pass is *not* proof of health for an intermittent fault; repeat. OS stress tests generally **do not surface corrected ECC counts** — run rasdaemon/EDAC alongside.
- **Interpretation caveats:** channel interleaving, lock‑step and mirroring mean a channel/csrow hit may implicate more than one module; normally a swap test attributes it to a stick. Here the memory is **soldered LPDDR5**, so stick‑swapping is impossible and the unit goes straight to vendor RMA.

### C. BIOS / hardware steps (ordered)
1. **Update BIOS/AGESA** to the latest vendor release for `GT68`. Rembrandt uses a dedicated **`RembrandtPI‑FP7`** AGESA line — **not** AM5’s `ComboAM5PI`; do **not** cross‑flash. The OEM “BIOS 1.00” string does not reveal AGESA — read it from **SMBIOS Type 40** (recent kernels print `AGESA: <Codename>PI‑<socket> <version>`). Memory‑training fixes are the most common cure for corrected UMC error storms; ask the vendor for a `RembrandtPI‑FP7` build (CVE‑2023‑20555‑class memory fixes were first in `RembrandtPI‑FP7 1.0.0.8`).
2. **Load optimized defaults**, then explicitly **disable any EXPO/XMP/DOCP** profile so the modules run at JEDEC defaults; confirm the actual speed. (EXPO is officially an AM5 overclock technology; AMD footnote GD‑106 states overclocking/undervolting outside published specs voids the AMD warranty and risks data loss.)
3. **Set “Platform First Error Handling” (PFEH) to disabled** if present — PassMark documents that PFEH can stop ECC/memory errors reaching the OS and test tools.
4. **Disable Memory Context Restore / Power Down Enable** if exposed, and any “memory fast boot”. These are AM5‑desktop‑era labels and may not exist in an FP7 mobile BIOS; they are not themselves ECC knobs.
5. **Clear CMOS / RTC**, then retrain memory (first boot is slow — normal).
6. **Memory is soldered LPDDR5 — do not attempt any physical memory manipulation.** There are no SO‑DIMM slots to reseat or swap; if firmware/defaults do not resolve the storm, this is a vendor‑RMA path.
8. **If the BIOS exposes voltages, prefer defaults.** There is **no published AMD conservative VSOC/VDDIO range for Rembrandt/FP7** (the well‑known ~1.3 V SoC guidance is AM5‑specific). Change one value at a time.
9. Re‑read DMI afterwards to confirm the module SKU/timings did not silently change.

### D. Deciding RAM vs CPU vs motherboard RMA
**Warranty scoping comes first:** the Ryzen 7 PRO 6850H is an **OEM/mobile FP7 part**. AMD’s direct boxed‑processor warranty applies only to sealed retail‑boxed (“PIB”) processors; preinstalled/mobile processors are warranted by the **system builder**. So the correct RMA path for the CPU/board/memory that shipped in this mini‑PC is the **mini‑PC vendor**, *not* AMD‑direct. Only separately purchased **retail** SO‑DIMMs carry the module brand’s limited‑lifetime warranty.
- **RAM RMA does not apply:** the memory is soldered LPDDR5 (no retail modules to return).
- **Whole‑unit (mini‑PC vendor) RMA** is the hardware path: soldered memory, suspected IMC error, a MemTest86+ failure, or CPU‑wide symptoms (uncorrectable MCEs, crashes, PCIe/GPU faults).
- **Thresholds:** any **uncorrectable** error, any reproducible MemTest86+ failure at JEDEC defaults, or a corrected‑error rate that does not fall after a BIOS update is sufficient grounds to open a case. Because the current event is `XEC 12`/`misc_umc` and not a DRAM ECC error, include the raw dmesg + rasdaemon records + DMIDecode memory data so the vendor can decode it.
- **AMD’s boxed‑processor process** asks for a “Component Swap Test” (move the CPU to another compatible system). For a soldered mobile APU this is impossible; use the vendor’s process instead.

### E. Temporary kernel/workaround knobs — **mitigation only, not fixes**
These reduce log/notification load; none repairs hardware or silences a real fault without hiding it.
- `mce=ignore_ce` — *“Disable features for corrected errors, e.g. polling timer and CMCI. All events reported as corrected are not cleared by OS and remained in its error banks.”* (Leaves banks uncleared, so it can hide a growing count.)
- `mce=dont_log_ce` — *“Don’t make logs for corrected errors. All events reported as corrected are silently cleared by OS.”*
- `mce=bootlog` / `mce=nobootlog` — log / don’t log pre‑boot MCEs (disabled by default on AMD Fam10h and older because some BIOS leave bogus ones).
- `mce=no_lmce`, `mce=bios_cmci_threshold`, `mce=recovery`, numeric monarch timeout — advanced.
- **Do not use `mce=off`** (disables machine check and uncorrected‑error protection). **`mce=repeat` is not a real option** — there is no such upstream parser token; unknown values print `mce argument %s ignored. Please use /sys`.
- rasdaemon can filter/aggregate and can auto‑account/offline pages or rows (`PAGE_CE_ACTION`, `ROW_CE_ACTION`, thresholds; `/etc/sysconfig/rasdaemon`, restart required). These isolate, not repair. Leaving corrected errors recorded is strongly preferred during an active investigation.
- EDAC module parameters are **not applicable**: the `amd64_edac` driver does not bind on this kernel/CPU.

> **Safety:** corrected errors do not corrupt data, but `OVER=1` means the hardware is dropping records, and a rising corrected rate often precedes uncorrectable failures. Do not run the machine as an untouched primary system while investigating.

---

## Remediation proposal (ranked)

| Rank | Action | Risk / cost | Why |
|---|---|---|---|
| 1 | Update BIOS/AGESA (**RembrandtPI‑FP7**) to latest vendor release; reload defaults | Low | Fixes memory‑training/AGESA bugs, the leading hypothesis |
| 2 | Install rasdaemon; capture DMI memory; run MemTest86+ (multiple passes, `ecc` option) | Low | Converts the storm into evidence and separates RAM from platform |
| 3 | Disable EXPO/XMP/DOCP (run JEDEC); disable **PFEH**; disable Memory Context Restore / Power Down if present | Low | Removes overclock/training variables; makes ECC reporting visible |
| 4 | ~~Reseat / one‑stick isolation~~ — **not applicable: soldered LPDDR5** | — | No user‑serviceable memory; physical isolation impossible |
| 5 | Clear CMOS / RTC, retrain | Low | Clears stale training/config |
| 6 | Conservative VSOC/VDDIO/VDDP **only if exposed and only one at a time** | Medium | May improve link margin; no published FP7 safe range |
| 7 | RMA via the **mini‑PC vendor** (whole unit only; no retail modules) | Medium (downtime) | Definitive for a hardware fault; AMD‑direct does not cover OEM/mobile |
| 8 | Kernel `mce=ignore_ce` / `dont_log_ce` while awaiting service | Low (but hides errors) | **Mitigation only** for log/machine‑check load |

**What this document does *not* recommend:** blindly enabling/disabling the error, flashing a non‑vendor or AM5 BIOS, or assuming ECC DIMMs are the fix. Because XEC 12 is undefined for this model, the highest‑value non‑hardware action is to **file the full raw log + rasdaemon decode + DMI data with AMD and the mini‑PC vendor**, explicitly asking for the `Family 19h Models 40h‑4Fh` UMC extended‑error‑code table for code 12 and whether the model‑44h syndrome layout differs from the documented `XEC == 0` DRAM‑ECC format.

---

## Decode confidence summary

| Claim | Confidence |
|---|---|
| CPU is Ryzen 7 PRO 6850H, Family 19h Model 44h, Rembrandt | **High** |
| MC15–MC18 are the four UMC instances (IPID HWID 0x96 / MCAType 0) | **High** |
| MCi_STATUS bit‑field values (VAL/OVER/UC/EN/MISCV/ADDRV/PCC/TCC/PADDRV/SYNDV/CECC/UECC…) | **High** |
| `CECC` = bit 46; `UECC` = bit 45 | **High** |
| XEC = bits [21:16] = 12 | **High** |
| MCACOD 0x011b = memory error, L3/GEN, generic, read | **High** |
| Kernel treats only UMC `XEC == 0` as DRAM ECC / runs DRAM decode only then | **High** |
| XEC 12 meaning for model 44h | **Low — not in maintained tables / no public definition found** |
| `misc_umc` (not `dram_ecc`) classification of this event | **Medium–High** |
| Documented XEC==0 UMC syndrome layout (channel/csrow/length/value) | **Medium–High** |
| Whether these syndromes are DRAM ECC despite XEC 12 | **Low — unresolved contradiction** |
| Rembrandt has 4 memory controllers | **High (AMD patch text)** |
| `amd64_edac` does not bind on kernel 6.18.38 (no EDAC DIMM nodes) | **High (observed + patch timing)** |
| Memory form factor | **High — soldered onboard LPDDR5 (confirmed by owner)** |
| CECC does not by itself prove ECC DIMMs | **High (from UMC error‑source tables)** |

**Single biggest unknown:** the physical meaning of UMC Extended Error Code **12** on Family 19h Model 44h. Every other conclusion is provisional on it.

---

## Sources

**Local observations (this host):** `journalctl -k -b`, `/proc/cpuinfo`, `/sys/class/dmi/id/*`, `/sys/devices/system/machinecheck/machinecheck0/*`, `/sys/devices/system/edac/*`, `lshw`.

**Linux kernel source (authoritative for the running decoder):**
- `arch/x86/include/asm/mce.h` — MCI_STATUS bit macros, `XEC()`, `MCACOD`, SMCA MSR offsets: <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/arch/x86/include/asm/mce.h>
- `drivers/edac/mce_amd.c` — `amd_decode_mce()` flag string, `decode_smca_error()`, `amd_decode_err_code()`, `smca_long_names[]` (note: the historical filename was `edac_mce_amd.c`): <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/edac/mce_amd.c>
- `drivers/edac/mce_amd.h` — `LL()/TT()/R4()/MEM_ERROR()` decoding macros: <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/edac/mce_amd.h>
- `arch/x86/kernel/cpu/mce/amd.c` — `smca_hwid_mcatypes[]`, `smca_mce_is_memory_error()` (XEC==0 rule), `smca_umc_block_names[] = {"dram_ecc","misc_umc"}`, `amd_mce_usable_address()`, threshold sysfs: <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/arch/x86/kernel/cpu/mce/amd.c>
- `drivers/edac/amd64_edac.c` — `decode_umc_error()` / `umc_get_err_info()` (channel/csrow/syndrome, corrected‑ECC only): <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/edac/amd64_edac.c>
- Commit `a0bcd3c0b8a52ba0eb74371fa6be15ad0390ba67` — “Decode MCA_STATUS in bit definition order” (flags order; CECC[46]/UECC[45]): <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=a0bcd3c0b8a52ba0eb74371fa6be15ad0390ba67>
- Commit `87a6d4091bd795b43d684bfc87253e04a263af1c` — adds `smca_umc_block_names[]` (`dram_ecc`/`misc_umc`), 2016: <https://lkml.indiana.edu/hypermail/linux/kernel/1609.1/03900.html>
- Commit `c35977b00fa76ce5f3fe9afdb9cffda970c943d5` — “Decode UMC_V2 ECC errors”; documents `ErrCodeExt[20:16]` and the `xec == 0` gate: <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=c35977b00fa76ce5f3fe9afdb9cffda970c943d5>
- Commit `9f988030e85fafa2b03910d467302853ad29a300` — “EDAC/mce_amd: Remove SMCA Extended Error code descriptions” (removed tables; rationale on reassigned UMC bit definitions): <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=9f988030e85fafa2b03910d467302853ad29a300>
- Pre‑removal decoder tables (v6.6): <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/drivers/edac/mce_amd.c?h=v6.6>
- `drivers/ras/amd/atl/umc.c` — AMD Address Translation Library UMC helpers (MI300/DRAM‑ECC address formats): <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/ras/amd/atl/umc.c>

**Kernel documentation:**
- `Documentation/admin-guide/ras.rst` (RAS, EDAC, lock‑step/mirror caveats): <https://www.kernel.org/doc/html/latest/admin-guide/ras.html>
- `Documentation/arch/x86/x86_64/boot-options.rst` — `mce=` options (content merged into `kernel-parameters.txt` in Nov 2024): <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/Documentation/arch/x86/x86_64/boot-options.rst> ; merge: <https://lkml.iu.edu/hypermail/linux/kernel/2411.2/04471.html>
- `Documentation/ABI/testing/sysfs-mce`, `Documentation/ABI/testing/sysfs-devices-edac` (sysfs interfaces)

**AMD (primary):**
- AMD Ryzen 7 PRO 6850H product/support page: <https://www.amd.com/en/support/downloads/drivers.html/processors/ryzen-pro/ryzen-pro-6000-series/amd-ryzen-7-pro-6850h.html>
- AMD64 Architecture Programmer’s Manual, Vol. 2 “System Programming” (doc 24593), **Ch. 15 “Machine Check Mechanism”** — machine‑check mechanism and register definitions (note: the task brief cited “APM Vol. 3”; the MCA chapter is in Vol. 2): current copy <https://docs.amd.com/v/u/en-US/24593_3.44_APM_Vol2> ; archived PDF <https://web.archive.org/web/20230822231247/https://www.amd.com/system/files/TechDocs/24593.pdf>
- Public Family 19h PPR example (proves AMD publishes some F19h PPRs publicly, but **not** the 40h–4Fh one): “PPR for AMD Family 19h Model 51h”, doc 56569: <https://docs.amd.com/v/u/en-US/56569-A1-PUB_3.03>
- AMD Ryzen Embedded V3000 (same Family 19h Models 40h–4Fh silicon) — “two DDR5 channels”: <https://docs.amd.com/v/u/en-US/dh324-amd-ryzen-embedded-v3000>
- AMD Family 17h PPR (doc 55803) — SMCA `MCA_STATUS` fields incl. TCC/PADDRV/SYNDV: <https://www.amd.com/content/dam/amd/en/documents/processor-tech-docs/programmer-references/55803-ppr-family-17h-model-31h-b0-processors.pdf>
- AMD Processor Programming Reference index (Family 19h PPRs are published per model range): <https://www.amd.com/en/support/tech-docs>
  *(This research did not locate a public PDF for “Family 19h Models 40h‑4Fh”; the model‑44h UMC error‑code/register tables should be treated as unavailable public information — the basis for the Low‑confidence XEC‑12 verdict.)*
- `amd64_edac` enablement for Family 19h models 40h–4Fh (states Rembrandt = Ryzen 6000, “4 memory controllers”, `max_mcs = 4`): <https://patchew.org/linux/20251130102111.1180875-1-devangnayanbhai.vyas@amd.com/> ; final EDAC pull for Linux 7.1: <https://lkml.iu.edu/hypermail/linux/kernel/2604.1/08211.html>
- Rembrandt AGESA line and security fixes (`RembrandtPI‑FP7`, not `ComboAM5PI`; AMD‑SB‑4013): <https://www.amd.com/en/resources/product-security/bulletin/amd-sb-4013.html>
- AGESA version exposed via SMBIOS Type 40 / kernel print: <https://lore.kernel.org/all/20260307141024.819807-1-superm1@kernel.org/>
- EXPO overclocking and GD‑106 warranty note: <https://www.amd.com/en/products/processors/technologies/expo.html>
- AMD warranty: boxed PIB guide: <https://www.amd.com/en/resources/support-articles/warranty/PIB.html> ; 3‑year article: <https://www.amd.com/en/resources/support-articles/warranty/RMA-03.html> ; **OEM (preinstalled)**: <https://www.amd.com/en/resources/support-articles/warranty/oem.html> ; **mobile processors**: <https://www.amd.com/en/resources/support-articles/warranty/Mobile-Processors.html>

**rasdaemon / RAS tooling:**
- rasdaemon upstream (AMD SMCA decoder; `smca_umc_mce_desc[]` 0–11; `find_umc_channel()` = `IPID[31:0] >> 20`; `csrow = synd & 0x7`; model 90h–9Fh quirk): <https://github.com/mchehab/rasdaemon> ; decoder file: <https://github.com/mchehab/rasdaemon/blob/master/events-arch-x86/mce-amd-smca.c>
- UMC reassigned‑bit handling commit: <https://github.com/mchehab/rasdaemon/commit/2d15882a0cbfce0b905039bebc811ac8311cd739>
- rasdaemon configuration (`/etc/sysconfig/rasdaemon`, page/row actions): <https://mchehab.github.io/rasdaemon/configuration.html>
- `ras-mc-ctl` reference (current `db`/`dimm` subcommands): <https://mchehab.github.io/rasdaemon/ras-mc-ctl-python.html>
- mcelog: <https://git.kernel.org/pub/scm/utils/cpu/mce/mcelog.git/> and <https://www.mcelog.org/>
- edac-utils (`edac-util`): <https://github.com/grondo/edac-utils>

**Memory / stress testing:**
- MemTest86+: <https://www.memtest.org/> ; README: <https://memtest.org/readme> ; v7.00 ECC note: <https://github.com/memtest86plus/memtest86plus/releases/tag/v7.00>
- MemTest86 (PassMark), incl. **PFEH** ECC‑reporting caveat: <https://www.memtest86.com/ecc.htm> ; run time: <https://www.memtest86.com/tech_execution-time.html>
- stressapptest: <https://github.com/stressapptest/stressapptest>
- Prime95 stress guidance: <https://www.mersenne.org/download/stress.txt>
- y‑cruncher: <https://www.numberworld.org/y-cruncher/>

**Community corroboration (anecdotal — labelled; not relied on for any decode):**
- AMD community, “Understanding Zen3+ UMC channels”: <https://community.amd.com/t5/pc-processors/understanding-zen3-umc-channels/m-p/567578>
- Lenovo forum, “Hardware Error: Corrected Error, No Action Required On Thinkpad T16 AMD”: <https://forums.lenovo.com/t5/Fedora/Hardware-Error-Corrected-Error-No-Action-Required-On-Thinkpad-T16-AMD/m-p/5160424>
- Arch Linux BBS thread with the same UMC corrected‑error signature: <https://bbs.archlinux.org/viewtopic.php?pid=2138000>
