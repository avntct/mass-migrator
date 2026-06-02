# Host-Based Licensing - Quick Reference

**For Administrators and Vendors**

---

## Customer Workflow (Getting License Key)

```bash
# 1. Customer runs on their server:
./mass-migrator --host-id
# Output: 873afa20ed25:9ce47f08cde0:65addbe6a242

# 2. Customer sends fingerprint to vendor

# 3. Vendor generates license:
./mm-keygen create \
  --tier enterprise \
  --customer "Acme Corp" \
  --email "admin@acme.com" \
  --host "873afa20ed25:9ce47f08cde0:65addbe6a242" \
  --expires 2027-12-31 \
  --output license.key

# 4. Vendor sends license.key to customer

# 5. Customer installs and validates:
cp license.key ~/.config/mass-migrator/
./mass-migrator --validate-license
```

---

## License Generation Options

### Basic License
```bash
mm-keygen create \
  --tier professional \
  --customer "Customer Name" \
  --expires 2027-12-31
```

### Host-Bound License
```bash
mm-keygen create \
  --tier enterprise \
  --customer "Customer Name" \
  --host "abc123def456:789abc123def:456789abc123" \
  --expires 2027-12-31
```

### Multi-Host License
```bash
mm-keygen create \
  --tier enterprise \
  --customer "Customer Name" \
  --host "host1:cpu1:disk1" \
  --host "host2:cpu2:disk2" \
  --host "host3:cpu3:disk3" \
  --expires 2027-12-31
```

### Time-Limited Trial
```bash
mm-keygen create \
  --tier trial \
  --customer "Trial User" \
  --expires $(date -v+30d +%Y-%m-%d)
```

---

## Host Fingerprint Format

```
Format: <mac_hash>:<cpu_hash>:<disk_hash>
Length: 12 hex chars : 12 hex chars : 12 hex chars

Example: 873afa20ed25:9ce47f08cde0:65addbe6a242
         └────MAC───┘ └────CPU───┘ └───DISK───┘
```

**Each component:**
- SHA-256 hash of raw hardware value
- Truncated to first 12 hex characters (48 bits)
- Case-insensitive (but lowercase is standard)

**Validation:**
- Must be exactly 3 parts separated by colons
- Each part must be 12 hexadecimal characters
- Non-hex characters (g-z) are rejected

---

## 2-of-3 Tolerance Examples

```
Licensed:    abc123:def456:ghi789
Current:     abc123:def456:XXX000
Result:      ✓ VALID (MAC+CPU match)

Licensed:    abc123:def456:ghi789
Current:     abc123:YYY000:ZZZ111
Result:      ✗ INVALID (only MAC matches)

Licensed:    abc123:def456:ghi789
Current:     XXX000:YYY000:ZZZ111
Result:      ✗ INVALID (no components match)
```

---

## CLI Flags Reference

### mass-migrator

| Flag | Description |
|------|-------------|
| `--host-id` | Show current host fingerprint and exit |
| `--validate-license` | Validate license and show details |

### mm-keygen create

| Flag | Description | Required |
|------|-------------|----------|
| `--tier` | License tier (trial/professional/enterprise) | Yes |
| `--customer` | Customer/organization name | Yes |
| `--email` | Contact email | No |
| `--host` | Host fingerprint (mac:cpu:disk format) | No |
| `--expires` | Expiration date (YYYY-MM-DD) | Yes |
| `--output` | Output file path (default: stdout) | No |

### mm-keygen verify

| Flag | Description |
|------|-------------|
| `--host` | Test license against specific host fingerprint |
| `--verbose` | Show full license details |

---

## Verification Commands

### Check License Details
```bash
mm-keygen verify license.key
```

### Test Against Specific Host
```bash
mm-keygen verify license.key --host "abc123:def456:ghi789"
```

### Show License Info (JSON)
```bash
mm-keygen show license.key --format json
```

---

## Troubleshooting Commands

### Validate Current Setup
```bash
# Show host fingerprint
./mass-migrator --host-id

# Validate license
./mass-migrator --validate-license

# Check all clocks (host + DB)
./mass-migrator gencsv --check-clocks-only
```

### Test License Components
```bash
# Verify signature
mm-keygen verify license.key

# Check expiration
mm-keygen show license.key | grep Expires

# Test host binding
mm-keygen verify license.key --host $(./mass-migrator --host-id)
```

---

## License File Locations

| Method | Path | Command |
|--------|------|---------|
| Current dir | `./license.key` | `cp license.key .` |
| User config | `~/.config/mass-migrator/license.key` | `mkdir -p ~/.config/mass-migrator && cp license.key ~/.config/mass-migrator/` |
| System | `/etc/mass-migrator/license.key` | `sudo mkdir -p /etc/mass-migrator && sudo cp license.key /etc/mass-migrator/` |
| Env override | `$MASS_MIGRATOR_LICENSE` | `export MASS_MIGRATOR_LICENSE=/path/to/license.key` |

---

## Multi-Clock Validation

Mass Migrator validates license expiry using 3 clocks:

1. **Host Server** - System time
2. **Source Database** - Database server time
3. **Target Database** - Database server time

**Consensus:** Median of 3 clocks
**Drift Threshold:** 5 minutes
**Rejection:** Any clock with >5min drift invalidates license

### Check Clock Sync
```bash
# All clocks must be within 5 minutes
./mass-migrator gencsv \
  --source-db "postgresql://..." \
  --target-db "mysql://..." \
  --validate-clocks
```

---

## Common Error Messages

| Error | Cause | Solution |
|-------|-------|----------|
| `license file not found` | No license in discovery path | Install to `~/.config/mass-migrator/` |
| `license signature invalid` | File corrupted or tampered | Request new license |
| `license has expired` | Expiration date passed | Renew license |
| `host binding check failed` | Fingerprint mismatch | Check with `--host-id`, request new license if needed |
| `excessive clock drift detected` | System time out of sync | Sync system time with NTP |

---

## Batch Operations

### Generate Multiple Licenses (Script)
```bash
#!/bin/bash
while read -r customer host email; do
  mm-keygen create \
    --tier enterprise \
    --customer "$customer" \
    --email "$email" \
    --host "$host" \
    --expires 2027-12-31 \
    --output "licenses/$customer.key"
done < customers.txt
```

### Verify All Licenses in Directory
```bash
for key in licenses/*.key; do
  echo "Verifying $key"
  mm-keygen verify "$key" || echo "FAILED: $key"
done
```

---

## Integration with CI/CD

### GitHub Actions Example
```yaml
- name: Get Host Fingerprint
  run: |
    ./mass-migrator --host-id > host-fingerprint.txt

- name: Upload License
  env:
    HOST_FP: $(cat host-fingerprint.txt)
  run: |
    # Call your license API
    curl -X POST https://license-api.example.com/generate \
      -H "Authorization: Bearer $LICENSE_API_KEY" \
      -d "{\"host\": \"$HOST_FP\", \"tier\": \"enterprise\"}" \
      -o license.key

- name: Validate License
  run: ./mass-migrator --validate-license
```

---

## Security Notes

1. **Protect Private Keys:** Never share `mm-keygen` private key files
2. **Revoke Compromised Licenses:** Update `revoked_licenses.json`
3. **Use HTTPS:** Always deliver licenses via encrypted channels
4. **Verify Fingerprints:** Always confirm host fingerprint with customer
5. **Audit Regularly:** Review license usage and access logs

---

## Contact

**Vendor Support:** vendor@massmigrator.com
**Customer Support:** support@massmigrator.com
**Documentation:** https://docs.massmigrator.com/licensing
