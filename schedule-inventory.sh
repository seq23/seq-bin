#!/usr/bin/env bash
# RETIRED 1 Nov 2026. This used to regenerate ~/repo-tools/manifests/SCHEDULE.md, a hand-run inventory that
# fell behind (77 GitHub jobs listed on 7 Oct; 127 by 1 Nov).
#
# The schedule now lives in Boss OS: ☰ More → Schedule, from src/shared/boss/schedule/manifest.json in
# seq23/boss-os, held to every real trigger by `npm run schedule:check`. Nothing here regenerates it.
echo "RETIRED: the schedule is the Boss OS Schedule page (☰ More → Schedule). Check it with:" >&2
echo "  cd ~/GitHub/boss-os && npm run vault:run -- npm run schedule:check" >&2
exit 3
