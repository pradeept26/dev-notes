# Kenya Performance Setups - Vulcano Cards

## Overview
Kenya setups with single Vulcano cards used for performance testing and development.

---

## Kenya-1108 (perf-1)

**Host:**
- Model: Kenya
- IP: 10.30.51.117
- Credentials: root/docker
- Location: SW N1 RU 29

**BMC:**
- IP: 10.30.51.107
- Credentials: root/0penBmc

**APC:**
- IP: 10.30.51.66
- Port: 14
- Credentials: apc/apc

**Vulcano Card:**
- Type: Saraceno
- Count: 1
- Serial: FPF254808C0
- Memory: 128 GB
- NUMA: 16
- CPLD: 1.05
- Status: Moved to Meta Fremont Lab

**Consoles:**
- Vulcano: telnet 10.30.52.56 2048
- SuC: telnet 10.30.52.56 2049

**Network:**
- Connected to Micas switch port 1/1
- Switch: 10.30.52.100 (admin/Micas123)
- Mini-PC: 10.30.51.108 (amd/amd123)

**Purpose:** Meta RoCE testing
**Owner:** Vijay
**Current User:** Loganathan

---

## Kenya-0108 (perf-2)

**Host:**
- Model: Kenya
- IP: 10.30.51.151
- Credentials: root/docker
- Location: SW N1 RU 27

**BMC:**
- IP: 10.30.51.105
- Credentials: root/0penBmc

**APC:**
- IP: 10.30.51.66
- Port: 15

**Vulcano Card:**
- Type: Saraceno
- Count: 1
- Memory: 128 GB
- NUMA: 16
- CPLD: 1.05
- Card Number: P1A-20
- Status: Moved to Meta Fremont Lab

**Consoles:**
- Vulcano: telnet 10.30.52.56 2046
- SuC: telnet 10.30.52.56 2047

**Network:**
- Connected to Micas switch port 1/2
- Mini-PC: 10.30.51.108 (amd/amd123)

**Purpose:** Meta RoCE testing
**Owner:** Vijay
**Current User:** Loganathan

---

## Kenya-1354 (perf-3)

**Host:**
- Model: Kenya
- IP: 10.30.52.66
- Credentials: root/docker
- Location: SW N2 RU 9-10

**BMC:**
- IP: 10.30.52.61
- Credentials: admin/Pen1nfra$

**APC:**
- IP: 10.30.52.57
- Port: 19

**Vulcano Card:**
- Type: Saraceno
- Count: 1
- Serial: FPF254808A8
- Memory: 32 GB
- NUMA: 16
- CPLD: 1.05

**Consoles:**
- Vulcano: telnet 10.30.52.56 2002
- SuC: telnet 10.30.52.56 2003

**Network:**
- Connected to Micas switch port 1/16 (previously 1/18)
- Switch: 10.30.52.100

**Purpose:** Meta RoCE bug fixes
**Owners:** Bharat, Matthew U
**Current User:** Sunil Akella

---

## Kenya-3190 (perf-4)

**Host:**
- Model: Kenya
- IP: 10.30.52.75
- Credentials: root/docker (assumed)
- Location: SW N2 RU 15-16

**BMC:**
- IP: 10.30.52.74
- Credentials: admin/Pen1nfra$

**APC:**
- IP: 10.30.52.55
- Port: 23

**Vulcano Card:**
- Type: Saraceno
- Count: 1
- Serial: FPR2605001C
- Memory: 32 GB
- NUMA: 16
- Card Number: P1A-03
- CPLD: 1.05

**Consoles:**
- Vulcano: telnet 10.30.52.56 2009
- SuC: telnet 10.30.52.56 2031

**Network:**
- Connected to Micas switch port 1/14 (previously 1/17)
- Switch: 10.30.52.100

**Purpose:** Meta RoCE bug fixes
**Comments:** IOMMU enabled for ATS work
**Owners:** Bharat, David
**Current User:** Sunil Akella

---

## Kenya-0106 (perf-7)

**Host:**
- Model: Kenya
- IP: 10.30.52.119
- Credentials: root/docker
- Location: SW N3 RU 22-23

**BMC:**
- IP: 10.30.52.110

**APC:**
- IP: 10.30.52.111
- Port: 15

**Vulcano Card:**
- Type: Gelso P1-A
- Count: 1
- Serial: FPF254808B6
- Memory: 128 GB (8 count)
- NUMA: 16 nodes, 2 present
- Card Number: P1A-30
- CPLD: 1.05 (updated; needs cpld refresh)

**Consoles:**
- Vulcano: telnet 10.30.53.51 2008
- SuC: telnet 10.30.53.51 2009

**Network:**
- Mini-PC3: 10.30.51.85 (root/docker)
- j2c connected to mini-pc-6

**Purpose:** MRC Perf debug
**Current User:** Mehul (as of 27 Jan)

---

## Kenya-3188 (perf-8)

**Host:**
- Model: Kenya
- IP: 10.30.52.123
- Credentials: root/docker
- Location: SW N3 RU 24-25

**APC:**
- IP: 10.30.52.111
- Port: 8

**Vulcano Card:**
- Type: Gelso P1-A
- Count: 1
- Serial: FPF2548089B
- Memory: 128 GB
- NUMA: 16
- CPLD: 1.05 (updated; needs cpld refresh)

**Consoles:**
- Vulcano: telnet 10.30.53.51 2004
- SuC: telnet 10.30.53.51 2005

**Network:**
- mini-pc7: 10.30.52.81 (root/Pen1nfra$)
- j2c connected to mini-pc-5

**Purpose:** MRC Perf debug
**Current User:** Mehul (as of 27 Jan)

---

## Kenya-1693

**Host:**
- Model: Kenya
- IP: 10.30.52.65
- Credentials: root/docker
- Location: SW N2 RU 11-12

**BMC:**
- IP: 10.30.52.64
- Credentials: admin/Pen1nfra$

**APC:**
- IP: 10.30.52.57
- Port: 18

**Vulcano Card:**
- Type: Gelso P1-A
- Count: 1
- Serial: FPF255102BD
- Memory: 32 GB (also has 128GB - 8 count)
- NUMA: 1
- CPLD: 1.05 (updated; needs cpld refresh)

**Consoles:**
- Vulcano: telnet 10.30.52.56 2014
- SuC: telnet 10.30.52.56 2015

**Network:**
- Mini-PC USB: 10.30.52.73 (Pen1nfra$)
- Mini-PC j2c: 10.30.53.74 (root/docker)

**Purpose:** Running custom pciemgr only FW for ASIC testing
**Owner:** Yogesh
**Current User:** Yogesh

---

## Kenya-1688 (perf-11)

**Host:**
- Model: Kenya
- IP: 10.30.52.71
- Credentials: root/docker
- Location: SW N2 RU 7-8

**BMC:**
- IP: 10.30.52.60
- Credentials: admin/Pen1nfra$

**APC:**
- IP: 10.30.52.57
- Port: 20

**Vulcano Card:**
- Type: Gelso P1-A
- Count: 1
- Serial: FPF25511055
- Memory: 64 GB (also has 64 GB - 1 count)
- NUMA: 8
- CPLD: 1.05 (updated; needs cpld refresh)

**Consoles:**
- Vulcano: telnet 10.30.52.56 2007
- SuC: telnet 10.30.52.56 2008

**Network:**
- Connected to Micas switch port 1/11
- Switch: 10.30.52.100
- Mini-PC7: 10.30.52.81 (root/Pen1nfra$)

**Purpose:** Kernel upgrade testing (12/31)
**Owner:** Tony
**Current User:** Prateek

---

## Kenya-3667 (perf-12)

**Host:**
- Model: Kenya
- IP: 10.30.52.115
- Credentials: root/docker (assumed)
- Location: SW N3 RU 26-27

**BMC:**
- IP: 10.30.52.113
- Credentials: root/0penBmc

**APC:**
- IP: 10.30.52.111
- Port: 24

**Vulcano Card:**
- Type: Gelso P1-A
- Count: 1
- Serial: FPF2548089C
- Memory: 128 GB
- NUMA: 8
- CPLD: 1.05

**Consoles:**
- Vulcano: telnet 10.30.53.51 2002
- SuC: telnet 10.30.53.51 2003

**Network:**
- Connected to Micas switch port 1/24
- Switch: 10.30.52.100 (admin/Micas123)
- Mini-PC6: 10.30.52.79 (root/Pen1nfra$)

**Owner:** Tony
**Current User:** Prateek

---

## Common Infrastructure

### Micas Switch
- IP: 10.30.52.100
- Credentials: admin/Micas123
- Ports used: 1/1, 1/2, 1/11, 1/14, 1/16, 1/24

### Console Server
- IP: 10.30.52.56 and 10.30.53.51
- Credentials: admin/N0isystem$
- Ports: Various (2002-2049)

### Card Types
- **Saraceno:** 4 setups (perf-1 through perf-4)
- **Gelso P1-A:** 6 setups (perf-7, 8, 11, 12, kenya-1693)

### Common Credentials
- Hosts: root/docker
- BMC: admin/Pen1nfra$ or root/0penBmc
- Mini-PCs: root/docker or root/Pen1nfra$
- Switch: admin/Micas123

---

## Quick Reference Table

| Setup | Host IP | BMC IP | Card Type | Memory | Purpose | Current User |
|-------|---------|--------|-----------|--------|---------|--------------|
| kenya-1108 (perf-1) | 10.30.51.117 | 10.30.51.107 | Saraceno | 128GB | Meta RoCE | Loganathan |
| kenya-0108 (perf-2) | 10.30.51.151 | 10.30.51.105 | Saraceno | 128GB | Meta RoCE | Loganathan |
| kenya-1354 (perf-3) | 10.30.52.66 | 10.30.52.61 | Saraceno | 32GB | Meta RoCE bugs | Sunil |
| kenya-3190 (perf-4) | 10.30.52.75 | 10.30.52.74 | Saraceno | 32GB | Meta RoCE bugs | Sunil |
| kenya-0106 (perf-7) | 10.30.52.119 | 10.30.52.110 | Gelso P1-A | 128GB | MRC Perf | Mehul |
| kenya-3188 (perf-8) | 10.30.52.123 | - | Gelso P1-A | 128GB | MRC Perf | Mehul |
| kenya-1693 | 10.30.52.65 | 10.30.52.64 | Gelso P1-A | 32GB | ASIC testing | Yogesh |
| kenya-1688 (perf-11) | 10.30.52.71 | 10.30.52.60 | Gelso P1-A | 64GB | Kernel upgrade | Prateek |
| kenya-3667 (perf-12) | 10.30.52.115 | 10.30.52.113 | Gelso P1-A | 128GB | - | Prateek |

---

**Last Updated:** 2026-03-01
**Source:** /home/pradeept/setups/Vulcano_Setup_Details_datapath_setups.csv
**Note:** Some setups (perf-1, perf-2) have been moved to Meta Fremont Lab

