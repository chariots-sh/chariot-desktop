# Why ad-hoc builds need their own entitlements

`ChariotDesktop-adhoc.entitlements` is `ChariotDesktop.entitlements` plus
`com.apple.security.cs.disable-library-validation`.

The rationale lives here rather than as a comment inside the plist: `codesign`
hands the file to AMFI, whose parser rejects XML comments outright with
`AMFIUnserializeXML: syntax error`. Xcode tolerates them because it compiles
entitlements into a `.xcent` first, so a commented file appears to work right up
until someone signs with `codesign --entitlements` directly.

## The problem it solves

The hardened runtime turns on **library validation**: the process may only load
code signed by the same Team ID as the main executable. Ad-hoc signatures carry
no Team ID, and two independently ad-hoc-signed Mach-Os do not count as the same
identity — so dyld refuses to map `Sparkle.framework` and the app dies before
`main()`:

```
Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
... not valid for use in process: mapping process and mapped file
    (non-platform) have different Team IDs
```

This shipped once, in v0.1.0. Worth understanding why it got that far:
`codesign --verify --deep --strict` **passes** on such a bundle. It verifies
that each signature is individually valid; it does not evaluate whether the
process is permitted to load them together. No amount of static signature
checking catches this — only launching the app does, which is why
`scripts/release-app.sh` now runs a launch smoke test.

## What it gives up

Library validation is the guarantee that a process loads only code signed by
us. Under ad-hoc signing there is no "us" to check against, so the guarantee is
already vacuous — the exception concedes nothing that ad-hoc signing had not
conceded already.

That stops being true with a Developer ID. There, Xcode signs the app and every
embedded framework under one team, library validation passes on its own, and it
is doing real work. **Developer ID builds must not use this file**, and
`release-app.sh` only selects it in ad-hoc mode.
