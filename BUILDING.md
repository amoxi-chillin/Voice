# Building Voice

## Requirements

- macOS 26 or later
- Xcode with Command Line Tools
- Git

## Local Build

```bash
git clone https://github.com/amoxi-chillin/Voice.git
cd Voice
make local
open ~/Downloads/Voice.app
```

`make local` prepares `whisper.xcframework` in `~/Voice-Dependencies`, builds Release in `.local-build`, and copies `Voice.app` to `~/Downloads`.

It uses `LocalBuild.xcconfig`, `Voice.local.entitlements`, and the `LOCAL_BUILD` Swift flag. Without an override, it uses the only available Apple Development identity or falls back to ad-hoc signing when none or multiple are found.

Choose an identity explicitly:

```bash
make local LOCAL_CODESIGN_IDENTITY="<SHA or name>"
```

Force ad-hoc signing:

```bash
make local LOCAL_CODESIGN_IDENTITY=-
```

Local builds do not include iCloud dictionary sync or automatic updates. Ad-hoc builds may require macOS permissions again after rebuilding.

## Other Commands

- `make check` — verify required tools
- `make whisper` — prepare `whisper.xcframework`
- `make build` — build the standard Debug configuration
- `make dev` — build and launch `Voice Dev.app`
- `make run` — launch `~/Downloads/Voice.app`, or the first app found in DerivedData
- `make clean` — remove `~/Voice-Dependencies`
- `make help` — list all commands

## Build with Xcode

```bash
make setup
open Voice.xcodeproj
```

Select the `Voice` scheme. Run builds `Voice Dev.app`; Archive uses Release. `LOCAL_BUILD` applies only through `make local`.

## Troubleshooting

- Run `make check` to verify the required tools.
- Run `make whisper` if the framework is missing.
- If several Apple Development identities exist, set `LOCAL_CODESIGN_IDENTITY` explicitly.
- For additional help, open a [GitHub issue](https://github.com/amoxi-chillin/Voice/issues).
