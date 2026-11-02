# Capability library index — mechanical hands, reused across runs

Each row is one reusable mechanical step executor. Describe the MECHANICAL ACTION only (what it
signs/builds/parses/frames) — never a target, a vector, a CVE, or "when to use it" (see README +
`doctrine/00`). Add a row when you promote a primitive from a run's `tools/`.

```
path | mechanical action | inputs -> output | from-run
-----|-------------------|------------------|--------
(empty — populated as hunts build reusable primitives)
```
- nxc_backupop_bootkey.py — nxc module: read Windows SYSLKEY/bootkey via rrp backup-open (REG_OPTION_BACKUP_RESTORE) class-name reads of HKLM\SYSTEM\CCS\Control\Lsa\{JD,Skew1,GBG,Data}, for a Backup Operators principal when the large SYSTEM-hive SMB3 download corrupts. From DarkZeroReturns.
