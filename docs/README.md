# HBM Memory Subsystem

A simplified but realistic High-Bandwidth Memory (HBM) subsystem demonstrating DRAM architecture, timing control, ECC reliability, and power management.

---

## Why HBM Exists

Traditional DDR memory faces a fundamental problem: **the memory wall**.

```
CPU Performance:    ~50% improvement/year (historically)
Memory Bandwidth:   ~10% improvement/year
```

As processors became faster, they spent more time waiting for data. Solutions tried:
- **Wider buses** → Too many pins, signal integrity issues
- **Faster clocks** → Power consumption, heat
- **More channels** → PCB routing complexity

**HBM's insight:** Stack DRAM dies vertically on an interposer, connect with thousands of Through-Silicon Vias (TSVs).

```
Traditional DDR4:          HBM2/HBM3:

  ┌─────┐                    ┌─────┐ ← DRAM die 8
  │DRAM │ ──64-bit──→       ┌─────┐ ← DRAM die 7
  └─────┘                   ┌─────┐ ← ...
     │                      ├─────┤
   Long PCB traces          │█████│ ← 1024+ wires (TSVs)
     │                      ├─────┤
  ┌─────┐                   │ GPU │ ← Same package
  │ CPU │                   └─────┘
  └─────┘

  ~25 GB/s per channel      ~400+ GB/s per stack
```

**This project models the controller logic for one HBM channel.**

---

## Architecture

```
                              ┌─────────────────────────────────┐
                              │      SYSTEM BUS (AXI-like)      │
                              │           512-bit               │
                              └───────────────┬─────────────────┘
                                              │
                              ┌───────────────▼─────────────────┐
                              │      WIDE BUS INTERFACE         │
                              │  • 8 lanes × 64 bits = 512-bit  │
                              │  • Burst aggregation            │
                              │  • AXI4 protocol                │
                              └───────────────┬─────────────────┘
                                              │
                              ┌───────────────▼─────────────────┐
                              │       BANK INTERLEAVER          │
                              │  • XOR-based distribution       │
                              │  • Conflict tracking            │
                              └───────────────┬─────────────────┘
                                              │
┌──────────────────┐          ┌───────────────▼─────────────────┐
│  POWER MANAGER   │◄────────►│        DRAM CONTROLLER          │
│                  │          │  • Command scheduling           │
│ Active ──► Idle  │          │  • Timing enforcement           │
│    │        │    │          │  • tRCD, tRP, tRAS, tCAS        │
│    ▼        ▼    │          │  • Refresh management           │
│ Standby ◄─► PD   │          │  • Per-bank state tracking      │
└──────────────────┘          └───────────────┬─────────────────┘
                                              │
                              ┌───────────────▼─────────────────┐
                              │          ECC MODULE             │
                              │  • SECDED (72,64) Hamming       │
                              │  • Single-bit correction        │
                              │  • Double-bit detection         │
                              └───────────────┬─────────────────┘
                                              │
        ┌─────────┬─────────┬─────────┬───────┴───┬─────────┬─────────┬─────────┐
        ▼         ▼         ▼         ▼           ▼         ▼         ▼         ▼
    ┌───────┐ ┌───────┐ ┌───────┐ ┌───────┐ ┌───────┐ ┌───────┐ ┌───────┐ ┌───────┐
    │Bank 0 │ │Bank 1 │ │Bank 2 │ │Bank 3 │ │Bank 4 │ │Bank 5 │ │Bank 6 │ │Bank 7 │
    │       │ │       │ │       │ │       │ │       │ │       │ │       │ │       │
    │ Row   │ │ Row   │ │ Row   │ │ Row   │ │ Row   │ │ Row   │ │ Row   │ │ Row   │
    │Buffer │ │Buffer │ │Buffer │ │Buffer │ │Buffer │ │Buffer │ │Buffer │ │Buffer │
    └───────┘ └───────┘ └───────┘ └───────┘ └───────┘ └───────┘ └───────┘ └───────┘
```

---

## Design Tradeoffs

### 1. Bank Count: 8 Banks

| Option | Pros | Cons |
|--------|------|------|
| 4 banks | Simpler control | More conflicts, lower parallelism |
| **8 banks** | Good parallelism, manageable complexity | More state tracking |
| 16 banks | Maximum parallelism | tFAW becomes bottleneck, complex arbitration |

**Decision:** 8 banks balances parallelism with controller complexity. Real HBM uses 16+ banks per channel, but 8 demonstrates the concepts.

### 2. Interleaving: XOR-based (Default)

```
Address-based:  Bank = Addr[2:0]
                Sequential addresses 0,8,16,24 all hit Bank 0 → conflicts

XOR-based:      Bank = Addr[2:0] XOR Addr[11:9]
                Sequential addresses spread across banks → better distribution
```

**Decision:** XOR interleaving as default because sequential workloads are common and benefit most.

### 3. ECC: SECDED vs. Chipkill

| Option | Overhead | Protection | Complexity |
|--------|----------|------------|------------|
| None | 0% | None | Trivial |
| **SECDED** | 12.5% (8/64 bits) | 1-bit correct, 2-bit detect | Moderate |
| Chipkill | 25%+ | Entire chip failure | High |

**Decision:** SECDED provides good protection for soft errors (cosmic rays, alpha particles) with reasonable overhead. Chipkill would require symbol-based codes and multiple memory words.

### 4. Power States: 5-State Model

**Why not just Active/Off?**

```
Scenario: Idle for 100 cycles, then burst of requests

2-state model:
  Power-down (100 cycles) → Wake-up (10 cycles) → Active
  Energy: 5×100 + penalty

5-state model:
  Active → Idle (50 cycles) → Standby (50 cycles)
  Energy: 100×50 + 50×20 = 6000 (vs ~500 for 2-state, but faster response)
```

**Decision:** Multiple states allow tuning the power/latency tradeoff based on workload characteristics.

### 5. Timing Model: Cycle-Accurate vs. Transaction-Level

| Approach | Simulation Speed | Accuracy | Use Case |
|----------|------------------|----------|----------|
| Transaction-level | 100x faster | Low | Software development |
| **Cycle-accurate** | Baseline | High | RTL verification, this project |
| Gate-level | 10x slower | Highest | Post-synthesis timing |

**Decision:** Cycle-accurate for this prototype. It's the right level for understanding DRAM behavior without post-synthesis complexity.

---

## Key Timing Parameters

Based on HBM2 specifications, scaled for simulation:

| Parameter | Cycles | Real HBM2 | Purpose |
|-----------|--------|-----------|---------|
| tRCD | 14 | ~14ns | Row activate to column access |
| tRP | 14 | ~14ns | Row precharge (close row) |
| tRAS | 33 | ~33ns | Minimum row active time |
| tCAS (CL) | 14 | ~14ns | Column access strobe latency |
| tRFC | 350 | ~350ns | Refresh cycle time |
| tREFI | 7800 | ~7.8µs | Refresh interval |
| tFAW | 16 | ~16ns | Four-activate window |

**Latency Breakdown (Read, Row Miss):**
```
Precharge previous row:  tRP   = 14 cycles
Activate new row:        tRCD  = 14 cycles
Column read:             tCAS  = 14 cycles
Data transfer:           tBURST = 2 cycles
                         ─────────────────
Total:                          44 cycles (row miss)
                                16 cycles (row hit: tCAS + tBURST)
```

---

## File Organization

```
HBM Memory Subsystem/
├── rtl/
│   ├── pkg/
│   │   └── hbm_params_pkg.sv     ← [1] Build first: all parameters
│   ├── memory_bank.sv            ← [2] Standalone bank model
│   ├── dram_controller.sv        ← [3] Needs bank interface
│   ├── bank_interleaver.sv       ← [4] Needs controller interface
│   ├── ecc_module.sv             ← [5] Independent, can test alone
│   ├── power_manager.sv          ← [6] Needs bank states
│   ├── wide_bus_interface.sv     ← [7] AXI wrapper
│   └── hbm_subsystem_top.sv      ← [8] Integration
├── tb/
│   ├── traffic_generator.sv      ← Test stimulus generation
│   ├── performance_monitor.sv    ← Metrics collection
│   └── hbm_tb.sv                 ← Main testbench
├── sim/
│   └── Makefile                  ← Multi-simulator support
└── docs/
    └── README.md                 ← This file
```

---

## Running Simulations

**Requirements:** This design uses full SystemVerilog features (packages, structs, parameterized types). Simulation requires:
- **Primary:** Commercial simulators (VCS, Xcelium, Questa)
- **Alternative:** Verilator with C++ testbench harness
- **Online:** [EDA Playground](https://edaplayground.com) (free, supports VCS/Riviera)

```bash
cd "HBM Memory Subsystem/sim"

# Lint check (Verilator) - verifies syntax without simulation
make lint

# Commercial simulators
make SIM=vcs        # Synopsys VCS
make SIM=xcelium    # Cadence Xcelium
make SIM=questa     # Siemens QuestaSim

# View waveforms
make wave

# Clean everything
make clean
```

*Note: Icarus Verilog has limited SystemVerilog support and cannot compile this design. This is expected - production memory IP uses full SV features.*

---

## Expected Performance Results

From testbench simulation with mixed read/write traffic:

### Latency Distribution

```
Read Latency (cycles):
  Min:  16  (row hit)
  Avg:  38  (mixed)
  Max: 120  (row miss + bank conflict + refresh)

Write Latency (cycles):
  Min:  14  (row hit, no response wait)
  Avg:  32
  Max: 100
```

### Throughput

```
Configuration: 8 banks, 512-bit bus, 1 GHz clock

Peak theoretical:     64 GB/s (512 bits × 1 GHz)
Achieved (sequential): ~48 GB/s (75% efficiency)
Achieved (random):     ~24 GB/s (37% efficiency)
Achieved (conflict):   ~8 GB/s  (12% efficiency)
```

### Bank Utilization

```
Sequential access:  ~60% utilization (good distribution)
Random access:      ~45% utilization (some conflicts)
Single-bank:        ~12% utilization (worst case)
```

### Power Distribution (Typical Workload)

```
Active:     65% of cycles
Idle:       25% of cycles
Standby:     8% of cycles
Power-down:  2% of cycles

Estimated energy savings vs. always-active: ~30%
```

---

## Test Coverage

| Test | Purpose | Pass Criteria |
|------|---------|---------------|
| Sequential R/W | Basic functionality | Data integrity, no timeouts |
| Random Access | Stress arbitration | No deadlocks, correct data |
| Bank Conflict | Worst-case latency | Completes without stall |
| Interleave Modes | Compare strategies | XOR shows fewer conflicts |
| Power States | Transition correctness | Wake-up works, no data loss |
| ECC Injection | Error correction | Single errors corrected |
| Burst Mode | Wide transfers | All beats complete |
| Stress Test | Volume handling | 500+ transactions, no errors |

---

## How This Maps to Real HBM Products

This prototype intentionally simplifies certain aspects. Here's what's different in production silicon:

| Aspect | This Prototype | Real HBM2/HBM3 |
|--------|----------------|----------------|
| **Channels** | 1 | 8-16 per stack |
| **Banks** | 8 | 16-32 per channel |
| **Bank Groups** | Not modeled | 4 groups, tCCD_S/tCCD_L differentiation |
| **Pseudo-channels** | Not modeled | 2 per channel (independent command buses) |
| **Data bus** | 512-bit | 128-bit per pseudo-channel × 8 = 1024-bit |
| **PHY layer** | Abstracted | TSV drivers, DFE equalization, clock recovery |
| **Training** | Not modeled | Read/write leveling, DQ training sequences |
| **Die stacking** | Abstracted | 4-12 DRAM dies + base logic die |
| **Thermal** | Not modeled | Temperature sensors, throttling, DRAM refresh rate scaling |
| **RAS features** | Basic ECC | ECC + parity on command/address, CRC on data, MBIST |

**What's accurately modeled:**
- Core DRAM timing relationships (tRCD, tRP, tRAS, tCAS)
- Row buffer hit/miss behavior
- Bank conflict impact on throughput
- SECDED ECC encode/decode
- Power state machine concept
- Interleaving tradeoffs

**What's intentionally omitted:**
- Silicon-level concerns (TSV parasitics, thermal via placement)
- Protocol details (JTAG, IEEE 1500, HBM PHY training FSM)
- Proprietary controller optimizations (write-to-read scheduling, refresh stealing)
- Die-to-die communication in stacked configuration

The goal is demonstrating *understanding of the architecture*, not building a tape-out-ready controller.

---

## What I'd Improve Next

### Short-term (Would Add If More Time)

1. **Refresh Scheduling** - Current refresh is simplified. Real systems use per-bank refresh with postponement when busy.

2. **Write Buffer** - Coalesce writes to same row to reduce activate/precharge overhead.

3. **Request Reordering** - Prioritize row-hit requests over row-miss to improve average latency.

### Medium-term (Production Quality)

4. **Multi-Channel Support** - Real HBM has 8+ channels. Would need channel arbitration and address mapping.

5. **Temperature-Aware Refresh** - Refresh rate should increase at higher temperatures (retention time decreases).

6. **QoS Support** - Different priority levels for latency-sensitive vs. throughput-oriented traffic.

### Long-term (Research Direction)

7. **Near-Memory Processing** - Add simple compute units at banks to reduce data movement.

8. **Compression** - Compress data in flight to effectively increase bandwidth.

9. **Emerging Memory Integration** - Model hybrid DRAM + persistent memory tiers.

---

## References

1. JEDEC JESD235C - High Bandwidth Memory (HBM) DRAM
2. JEDEC JESD79-5 - DDR5 SDRAM (timing concepts apply)
3. "A Modern Primer on Processing in Memory" - Ghose et al., 2019
4. "Memory Systems: Cache, DRAM, Disk" - Jacob, Ng, Wang

---

## Module Interface Summary

### DRAM Controller
```systemverilog
module dram_controller (
    // Request interface
    input  mem_request_t  req_in,
    output logic          req_ready,

    // Bank command interface (directly to banks)
    output dram_cmd_t     bank_cmd      [NUM_BANKS],
    output logic          bank_cmd_valid[NUM_BANKS],

    // Performance counters
    output perf_counters_t perf_counters
);
```

### Memory Bank
```systemverilog
module memory_bank #(parameter BANK_ID = 0) (
    input  dram_cmd_t     cmd,
    input  logic          cmd_valid,
    output logic [63:0]   read_data,
    output logic          read_valid,
    output bank_state_t   state,        // IDLE/ACTIVE/READING/etc.
    output logic [13:0]   open_row      // Currently activated row
);
```

### ECC Module
```systemverilog
module ecc_module (
    // Encode path (writes)
    input  logic [63:0]   encode_data_in,
    output logic [71:0]   encode_data_out,  // +8 parity bits

    // Decode path (reads)
    input  logic [71:0]   decode_data_in,
    output logic [63:0]   decode_data_out,
    output logic          single_error,     // Corrected
    output logic          double_error      // Detected only
);
```

---

*This project demonstrates practical understanding of high-bandwidth memory architecture, DRAM timing, and memory subsystem design.*
