- **Compute Optimization:** Favor native edge capabilities.
- **Zero-Budget:** Solutions must rely on free tiers.
- **Immutable Backend:** Treat the WordPress API as an immutable black box. Do not attempt backend database or PHP logic changes.
Enforce lexicographical sorting and line uniqueness in ignore files to prevent redundant entries and maintain configuration integrity.
diff --git a/AI_MAP.md b/AI_MAP.md
--- a/AI_MAP.md
+++ b/AI_MAP.md
@@ -0,0 +1,7 @@
+# AI Map: VM-auto-security
+
+- `configs/`: OS security and auto-reboot logic.
+- `scripts/`: WordPress update automation.
+- `install.sh`: Stack provisioning script.
+- `AI_LOG.md`: Security repair audit trail.
+- `AI_MAP.md`: Architectural context map.

Unified diffs must include @@ hunk headers and line-prefixed changes (+/-); metadata headers alone are insufficient to apply modifications.
Always include @@ hunk headers and +/- line prefixes in unified diffs to ensure they are structurally valid and applicable by patch tools.
Enforce lexicographical sorting and line uniqueness in ignore files to prevent redundant entries and maintain configuration integrity.
.
├── AI_LOG.md
├── AI_MAP.md
├── GEMINI.md
├── LICENSE
├── README.md
├── configs
│   ├── 20auto-upgrades
│   ├── 50unattended-upgrades
│   ├── auto-reboot.service
│   ├── auto-reboot.timer.tpl
│   └── needrestart.conf
├── install.sh
└── scripts
    └── wp-auto-update.sh.tpl

3 directories, 12 files
