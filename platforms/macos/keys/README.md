# Release signing keys — macos

`install.sh` verifies every file it fetches in two independent ways:

1. **SHA-256** against the `FILE_CHECKSUMS` map baked into `install.sh` (always).
2. **minisign signature** against `twdxos-release.pub` in this directory
   (best-effort by default; **mandatory** with `--require-signatures` /
   `--strict` / `REQUIRE_SIGNATURES=true`).

## Status of this key

`twdxos-release.pub` here is a **placeholder** (it contains the literal
string `REPLACE-WITH-REAL-PUBLIC-KEY`). Until the maintainer replaces it
with a real minisign public key and publishes `.minisig` files next to each
shipped config:

- Default runs: signature step is **skipped with a warning**, SHA-256 still
  enforced.
- `--require-signatures`: the run **aborts** with exit code 5 (this is the
  correct fail-closed behaviour).

## For the maintainer — enabling signatures

```bash
# one-time: generate the keypair, keep the .key OFFLINE (hardware token / vault)
minisign -G -p platforms/macos/keys/twdxos-release.pub \
            -s ~/.secure/twdxos-release.key

# per release: sign every fetched file
for f in declutter.sh configs/com.twdxos.declutter.plist.tpl \
         modules/wp-auto-update.sh.tpl; do
  minisign -S -s ~/.secure/twdxos-release.key -m "platforms/macos/$f"
done
git add platforms/macos/{keys/twdxos-release.pub,**/*.minisig}
```

Commit the same public key to every `platforms/*/keys/` directory (each
platform folder is self-contained by design).

## Verifying this public key out of band

The public key's fingerprint is also published at
`https://thewebdexter.com/twdxos/release-key` and in the repository's
signed release tags. Confirm it matches before trusting a run made with
`--require-signatures`.
