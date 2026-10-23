# Archive index staging fixture — NOT FOR PRODUCTION

This directory contains synthetic, non-production index data only.

- Branch: `staging/isy-archive-index-20261023`
- Fixture: `reflections-v1.fixture.json`
- Schema: `isy-archive-index-v1`
- Sentinel blog ID: `STAGING_FIXTURE_DO_NOT_PUBLISH`
- Empty cards intentionally; no private Blogger content or draft records are included.
- The fixture must NOT be used as a production reader source and must NOT be promoted unchanged to `main`.
- No Apps Script, publishing triggers, credentials, or live Blogger theme are modified by this branch.
- Before production integration: verify the real public Blogger blog ID via authenticated read-only access; build a complete LIVE-only snapshot, validate concurrent SHA updates and removals, verify raw JSON delivery and browser access, and obtain separate deployment authorization.
