# Host-Based Licensing User Guide

**For Mass Migrator Customers**
**Version:** 1.0
**Date:** 2026-03-31

---

## Overview

Mass Migrator uses **host-based licensing** to bind your license to specific physical or virtual machines. This ensures compliance while allowing flexibility for hardware maintenance.

### How It Works

Your license is bound to a **hardware fingerprint** composed of 3 components:
- **MAC Address** - Network interface identifier
- **CPU ID** - Processor signature
- **Disk Serial** - Boot disk identifier

**2-of-3 Tolerance:** Your license remains valid if 2 of 3 components match. This means you can replace a single component (NIC, CPU, or disk) without needing a new license.

---

## Getting Your Host Fingerprint

### Step 1: Run the Command

On your server where Mass Migrator is installed, run:

```bash
./mass-migrator --host-id
```

**Example Output:**
```
873afa20ed25:9ce47f08cde0:65addbe6a242
```

### Step 2: Provide to Vendor

Send this 12:12:12 hex string to your Mass Migrator representative. They will generate a license bound to your machine.

---

## Installing Your License

### Option 1: User Config Directory (Recommended)

```bash
# Linux/macOS
mkdir -p ~/.config/mass-migrator
cp license.key ~/.config/mass-migrator/

# Windows (PowerShell)
New-Item -ItemType Directory -Force -Path "$env:AppData\Local\mass-migrator"
Copy-Item license.key "$env:AppData\Local\mass-migrator\"
```

### Option 2: System-Wide (All Users)

```bash
# Linux
sudo mkdir -p /etc/mass-migrator
sudo cp license.key /etc/mass-migrator/

# macOS
sudo mkdir -p /Library/Application Support/mass-migrator
sudo cp license.key /Library/Application Support/mass-migrator/

# Windows (Admin PowerShell)
New-Item -ItemType Directory -Force -Path "C:\ProgramData\mass-migrator"
Copy-Item license.key "C:\ProgramData\mass-migrator"
```

### Option 3: Current Directory

Place `license.key` in the same directory where you run `mass-migrator`.

---

## License Discovery Order

Mass Migrator searches for your license in this order:

1. `./license.key` (current directory)
2. `./mm-license.key` (explicit name, avoids conflicts)
3. `~/.config/mass-migrator/license.key` (user config)
4. `/etc/mass-migrator/license.key` (system-wide)

**Platform-specific paths:**

| Platform | User Config | System-Wide |
|----------|-------------|-------------|
| Linux | `~/.config/mass-migrator/` | `/etc/mass-migrator/` |
| macOS | `~/Library/Application Support/mass-migrator/` | `/Library/Application Support/mass-migrator/` |
| Windows | `%AppData%\Local\mass-migrator\` | `%ProgramData%\mass-migrator\` |

---

## Validating Your License

After installation, verify your license:

```bash
./mass-migrator --validate-license
```

**Successful Output:**
```
✓ License file found: ~/.config/mass-migrator/license.key
✓ Signature valid
✓ License ID: lic-abc123
✓ Tier: enterprise
✓ Organization: Acme Corporation
✓ Expires: 2027-12-31
✓ Host binding verified: 873afa20ed25:9ce47f08cde0:65addbe6a242
✓ License valid
```

---

## Hardware Changes and Tolerance

### What You CAN Change Without a New License

- **Replace Network Card (NIC)** - MAC changes, CPU+Disk match ✓
- **Upgrade CPU** - CPU changes, MAC+Disk match ✓
- **Replace Boot Disk** - Disk changes, MAC+CPU match ✓

### What Requires a NEW License

- **Replace Entire Machine** - No components match ✗
- **Move License to Different Server** - Different fingerprint ✗
- **Run in New VM/Container** - Different virtual hardware ✗

### Changing 2+ Components

If you need to replace 2 or more components (e.g., motherboard replacement affects both MAC and CPU), contact your vendor for a replacement license.

---

## Common Scenarios

### Scenario 1: New Server Installation

1. Install Mass Migrator
2. Run `./mass-migrator --host-id`
3. Send fingerprint to vendor
4. Receive `license.key` file
5. Copy to `~/.config/mass-migrator/`
6. Run `./mass-migrator --validate-license`

### Scenario 2: Server Upgrade (One Component)

1. Replace hardware (e.g., new NIC)
2. Restart Mass Migrator
3. License remains valid (2-of-3 tolerance)
4. No action required

### Scenario 3: Server Replacement

1. Set up new server
2. Run `./mass-migrator --host-id` on new server
3. Request license transfer from vendor
4. Install new license file
5. Old license automatically invalid

---

## Troubleshooting

### Error: "License file not found"

**Cause:** License not in any discovery path.

**Solution:**
```bash
# Check where Mass Migrator looks
./mass-migrator --validate-license

# Install to recommended location
mkdir -p ~/.config/mass-migrator
cp license.key ~/.config/mass-migrator/
```

---

### Error: "License not valid for this host"

**Cause:** Host fingerprint doesn't match license binding.

**Solution:**
1. Check current host: `./mass-migrator --host-id`
2. Compare with licensed fingerprint
3. If 2+ components changed, contact vendor for new license
4. If 0-1 components changed, this may be an error - contact support

---

### Error: "License has expired"

**Cause:** License expiration date passed.

**Solution:** Contact vendor for renewal.

---

### Error: "Host fingerprint format invalid"

**Cause:** Incorrect format when creating license.

**Solution:** Ensure format is `mac:cpu:disk` with 12 hex chars each:
```
Correct: abc123def456:789abc123def:456789abc123
Wrong:   abc:def:ghi (too short)
Wrong:   xxx:yyy:zzz (not hex)
```

---

## Container and VM Environments

### Docker Containers

Containers share the host's CPU ID and may have virtual NICs. Your host fingerprint will typically match the container's, so licenses usually work. Test first:

```bash
docker run --rm -v ~/.config/mass-migrator:/root/.config/mass-migrator \
  mass-migrator --validate-license
```

### Virtual Machines

VMs have distinct disk serials and may have unique MAC addresses. Each VM needs its own license. Consider:
- **VM snapshot/cloning**: Creates new fingerprint, needs new license
- **VM migration**: Usually preserves fingerprint, license works
- **Different hypervisors**: May generate different fingerprints

### Kubernetes Pods

Treat each node as requiring its own license. For cluster-wide deployments, contact your vendor for volume licensing options.

---

## Security Best Practices

1. **File Permissions:**
   ```bash
   chmod 600 ~/.config/mass-migrator/license.key
   ```

2. **Backup Your License:**
   ```bash
   cp ~/.config/mass-migrator/license.key ~/backup/
   ```

3. **Don't Share Licenses:**
   - Each license is bound to specific machines
   - Sharing violates license agreement
   - Fingerprint mismatches will be detected

4. **Report Lost/Stolen Licenses:**
   - Contact vendor immediately to revoke
   - Obtain replacement for affected machines

---

## FAQ

### Q: Can I move my license to a different machine?

**A:** No. Licenses are host-bound. Contact your vendor to transfer the license.

### Q: What happens if I upgrade my OS?

**A:** OS upgrades don't change hardware fingerprints. Your license remains valid.

### Q: Do licenses work in cloud environments (AWS, Azure, GCP)?

**A:** Yes. However, instance types and generations may have different fingerprints. Test after any instance migration.

### Q: How many hosts can one license cover?

**A:** Standard licenses cover a single host. For multiple hosts, ask your vendor about multi-host licensing.

### Q: What about development/staging environments?

**A:** Each environment needs its own license unless running on identical hardware (e.g., VM snapshots).

### Q: Can I see which components are being used?

**A:** The host fingerprint is a hash, not the raw values. This protects your hardware privacy.

---

## Contact Support

For licensing issues, questions, or requests:

**Email:** licensing@massmigrator.com
**Subject:** License Inquiry - [Your Company Name]
**Include:**
- License ID (if you have it)
- Host fingerprint (`./mass-migrator --host-id`)
- Error messages (if any)
- Description of your situation

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-03-31 | Initial host-based licensing system |
