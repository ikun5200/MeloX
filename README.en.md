# MeloX · QQ Music Migration

[简体中文](README.md) | [English](README.en.md)

MeloX is a third-party music player built with native SwiftUI. This repository is a
personal migration fork of [youshen2/MeloX](https://github.com/youshen2/MeloX):
the iOS backend has been switched from NetEase Cloud Music to QQ Music, while playback
and download URLs are resolved by Luoxue (LX) sources imported by the user.

> This is an unofficial open-source project. It is not affiliated with, sponsored by,
> or authorized by QQ Music, Tencent, or their related companies. The project does not
> bundle any source, key, or paid content, and does not provide a way to bypass payment
> or copyright restrictions.

## Status

| Platform | Status |
| --- | --- |
| iPhone / iPad | QQ Music main flow completed |
| Apple Watch | Still NetEase-based, migration pending |
| macOS (MeloX Desktop) | Still NetEase-based, migration pending |

The original NetEase implementation is preserved on the `netease-final` snapshot branch.
The default branch is `qq-migration`.

## Features

- **QQ Music browsing**: search and suggestions, song/album/artist/playlist/toplist
  details, recommended playlists, new albums, comments.
- **QQ login**: QQ QR, WeChat QR, and phone verification code. Anonymous browsing is
  supported; account actions prompt for login.
- **Library**: liked songs, created/subscribed playlists, favorite albums, followed
  artists, plus like/favorite/create/delete/add/remove operations.
- **Luoxue sources**:
  - import an `lx` source URL, a local `.js`, or an LX source list/subscription;
  - multiple sources with priority, enable/disable, and automatic failover;
  - detects the source-declared QQ (`tx`) qualities and downgrades across the 7 tiers;
  - source scripts run on-device in JavaScriptCore and are never uploaded;
  - source URLs and keys are not committed or bundled.
- **Playback/download**: URLs come entirely from LX sources, with request headers,
  download support, failure prompts, and automatic next-track fallback.
- **MV**: open and play an MV from the song detail page.
- **Artist enhancements**: artist description and similar artists.
- **Lyrics**: QQ Music QRC word-by-word / LRC, translations, romanization, and the
  existing Apple Music-style motion.
- **Home/Explore**: QQ recommended playlists, toplists, and new albums. Daily
  recommendations, private FM, and Heart Mode are approximated with QQ charts.
- **Removed**: podcasts, cloud drive, song recognition, song wiki, listening rank,
  private messages, Listen Together entry, share-to-feed, NetEase deep-link handling,
  and their views/models/permissions.

## Download & Install

The latest build is published as a rolling GitHub Release:

- [MeloX iOS Development Build (Latest)](https://github.com/ikun5200/MeloX/releases/tag/ios-latest)

Asset name: `MeloX-iOS-unsigned.ipa`.

The IPA is **unsigned** and cannot be installed directly. Sign it with your own
certificate/provisioning profile, or install it with AltStore, SideStore, TrollStore,
or a similar tool. The release is updated automatically after each successful
`qq-migration` build.

Each GitHub Actions run also keeps a 14-day artifact:
`MeloX-iOS-unsigned-<run_number>`.

## First Run

1. **Import a source**: Settings → Luoxue Sources → paste your own `lx` source URL,
   or import a local `.js` / source list. Only sources containing QQ Music (`tx`) are
   enabled; other platforms are marked unsupported.
2. **Log in (optional)**: Settings → QQ Music Account → QQ QR / WeChat QR / phone code.
   Anonymous search and playback work; favorites and playlists require login.
3. **Play**: pick a song from search or Home. The player shows the quality that was
   actually resolved; unsupported tiers are downgraded automatically.
4. **Download**: choose a quality from the song/album/playlist menu. Downloads also go
   through the source resolver.

> You provide and are responsible for your own sources. The project does not bundle,
> distribute, or recommend any specific source.

## Build from Source

Requirements:

- Xcode 27.1 or later
- iOS 27.1 SDK
- A working macOS build environment

```bash
git clone https://github.com/ikun5200/MeloX.git
cd MeloX
bash build_ios_unsigned.sh
```

Output: `build/MeloX-iOS-unsigned.ipa` (unsigned).

### CI

`.github/workflows/build-ipa.yml` runs on:

- pushes to `qq-migration` or `main`
- manual `workflow_dispatch`
- `v*` tags

Pipeline:

1. run `Tools/Tests/test_qq_backend.py` offline backend checks;
2. build the unsigned IPA;
3. upload the Actions artifact;
4. create/update the `ios-latest` Release;
5. additionally create a versioned Release for `v*` tags.

Backend checks cover QQ `zzc` signing, quality mapping, search/playlist parsing,
QQ share-link parsing, LX runtime initialization, and playback URL resolution.

## Known Limitations

- Desktop and Watch are not migrated to QQ Music yet.
- QQ library write operations follow the QQMusicApi protocol but still need a real-account
  regression pass.
- Daily recommendations, private FM, and Heart Mode are QQ chart approximations, not
  official personalization.
- There is no standalone MV browse page; MV entry points live on song details.
- A simulator launch smoke script exists (`Tools/Tests/simulator_smoke.sh`), but the
  simulator build is too slow on GitHub Actions runners and is not enabled in CI.
- Source compatibility depends on the script. LX sources that require Node APIs are
  reported as incompatible.

## Security & Compliance

- Source configuration is stored in plain text in Application Support for easier
  debugging and migration. Do not use it on shared devices.
- Source scripts are treated as untrusted code: they run in a restricted JavaScriptCore
  environment, and network requests have time and size limits.
- This project is for learning and research. Follow local laws, the QQ Music terms of
  service, and music copyright requirements.
- Delete downloaded copies within 24 hours.

## Credits

- Upstream: [youshen2/MeloX](https://github.com/youshen2/MeloX)
- QQ API reference: [L-1124/QQMusicApi](https://github.com/L-1124/QQMusicApi)
- LX custom-source protocol: LX Music
- Additional lyrics/player references and licenses are listed in the in-app
  “Projects & Licenses” page.

## License

The main application code is licensed under GPLv3. Third-party code, assets, fonts,
models, and PV Tool content remain under their own licenses. See [LICENSE](LICENSE)
and the license files under `MeloX/Resources/`.
