# Third-party software notices

iOS Developer Toolkit's own source code is distributed under the repository's
[MIT License](LICENSE). That license does not replace the licenses of the third-party software
used to build or run the application.

## Swift packages linked into the app and `idt`

Versions are pinned in [`Package.resolved`](Package.resolved).

| Component | Version | Role | License |
|---|---:|---|---|
| [swift-nio](https://github.com/apple/swift-nio) | 2.103.0 | Networking for the lockdown connection | Apache-2.0 |
| [swift-nio-ssl](https://github.com/apple/swift-nio-ssl) | 2.37.5 | TLS for the lockdown connection | Apache-2.0; contains [BoringSSL](https://boringssl.googlesource.com/boringssl/) under the ISC and OpenSSL licenses |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Command-line parsing for `idt` | Apache-2.0 |
| [swift-atomics](https://github.com/apple/swift-atomics) | 1.3.1 | Dependency of swift-nio | Apache-2.0 |
| [swift-collections](https://github.com/apple/swift-collections) | 1.7.1 | Dependency of swift-nio | Apache-2.0 |
| [swift-system](https://github.com/apple/swift-system) | 1.8.1 | Dependency of swift-nio | Apache-2.0 |

Each release app contains the exact `LICENSE` and `NOTICE` files of these packages in
`Contents/Resources/Licenses/`, and each release has an SPDX SBOM generated from `Package.resolved`
(see [docs/release-verification.md](docs/release-verification.md)).

## Firmware helpers bundled as separate programs

The Firmware page installs firmware with `idevicerestore` and reads recovery and DFU devices with
`irecovery`, from the [libimobiledevice](https://libimobiledevice.org) project. They are separate
executables in `Contents/Helpers`, run as child processes with argument vectors; the app and `idt`
do not link them. Each helper is statically linked against the libraries below and depends only on
macOS system libraries. [`scripts/build-restore-helpers.sh`](scripts/build-restore-helpers.sh)
builds them from these exact sources:

| Component | Version | Source | License |
|---|---|---|---|
| [idevicerestore](https://github.com/libimobiledevice/idevicerestore) | 1.0.0-git | commit `60192e97` | LGPL-3.0-or-later |
| [libirecovery](https://github.com/libimobiledevice/libirecovery) | 1.3.1-git | commit `93c117c2` | LGPL-2.1-or-later |
| [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) | 1.4.0-git | commit `fa0f7919` | LGPL-2.1-or-later |
| [libimobiledevice-glue](https://github.com/libimobiledevice/libimobiledevice-glue) | 1.3.2-git | commit `da770a76` | LGPL-2.1-or-later |
| [libusbmuxd](https://github.com/libimobiledevice/libusbmuxd) | 2.1.1-git | commit `93eb168b` | LGPL-2.1-or-later |
| [libtatsu](https://github.com/libimobiledevice/libtatsu) | 1.0.5-git | commit `e7d6ad13` | LGPL-2.1-or-later |
| [libplist](https://github.com/libimobiledevice/libplist) | 2.7.0-git | commit `32428aba` | LGPL-2.1-or-later |
| [libzip](https://libzip.org) | 1.11.4 | commit `6f8a0cdd` | BSD-3-Clause |
| [OpenSSL](https://www.openssl.org) | 3.5.8 | release tarball, SHA-256 `a8f84a39…64f5b2` | Apache-2.0 |

Each release app contains these projects' license files and `SOURCES.txt` in
`Contents/Resources/Licenses/restore-helpers/`, and each release attaches
`…-firmware-helpers-source.tar.gz` with their complete source and the build script. You may
replace the helpers with your own build of the same programs: put them in `Contents/Helpers`, or
point `IDT_RESTORE_HELPERS` at a folder that contains them.

## Data

The Location Lab world map is derived from [Natural Earth](https://www.naturalearthdata.com)
1:110m land data, which is in the public domain.

## macOS system libraries

Security Analysis reads backup manifests through the SQLite library supplied by macOS. The app
links the system library through a local module map; it does not bundle or redistribute SQLite.

## Optional external tools

[MVT](https://github.com/mvt-project/mvt), [UFADE](https://github.com/prosch88/UFADE), and
[idb Companion](https://github.com/facebook/idb) can be launched from the External Tools page if
you install them yourself. They are not bundled, linked, or included in the release SBOM, and they
remain under their own licenses (MVT under the [MVT License 1.1](https://license.mvt.re/1.1/),
idb under MIT). The app records the path and SHA-256 of the executable it launches.

## Apple tools

The app uses `devicectl`, `simctl`, `xctrace`, `xed`, and `rvictl` from the user's own Xcode
installation and macOS. They are not redistributed.

These notices describe the shipped dependency boundary and are not legal advice. Anyone who
redistributes a modified app is responsible for meeting every applicable license.
