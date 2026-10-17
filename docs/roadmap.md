# Remaining work

Keep only unfinished work here. Remove completed entries and add a new item only
when it has a concrete user impact. Last reviewed: 2026-10-17.

## Next product decision

- [ ] Decide APKS/XAPK scope with real samples. Either use an explicitly selected
  bundletool for variant APKS or keep the clear rejection. Add OBB placement only
  when a concrete package and destination rule require it.

## When needed

- [ ] Add one Windows build/test/installer workflow for repeatable releases.
- [ ] Consolidate duplicated version metadata at the next version bump.
- [ ] Retire fallback core construction and legacy string/sentinel APIs as their
  callers are changed; split `AppState` when a feature is blocked by its size.

Android Package Manager owns APK signature acceptance. A separate signer trust
system, persistent transfer database/resume, exhaustive failure matrices, a new
Agent authentication protocol, and native Logcat UI replacement are not planned
without a concrete need.
