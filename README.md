# BenchLibre

[Français](README.fr.md)

An open source, native benchmark for **macOS 14 or later**, written in Swift 6, C and Metal. Version **0.3.2** uses **`benchlibre-suite-v3`** and reports six measurements in their actual units. There is no combined score.

| Test | Display unit | Workload |
| --- | --- | --- |
| CPU | GFLOP/s | Eight FP32 chains of four lanes per worker |
| Metal GPU | GFLOP/s | 536,870,912 FLOP per dispatch, fixed dimensions |
| Memory transfers | GB/s | Single-worker triad over 3 × 64 MiB: `A = B + 3 × C` |
| Memory access time | ns/access | Dependent-index cycle through 64 MiB; lower is better |
| File reading | GB/s | Sequential reads from a 64 MiB file with `F_NOCACHE` |
| File writing | GB/s | Sequential writes to the file, including `fsync` |

CPU, GPU, memory transfers and memory access time are selected by default. File tests are optional. GB/s uses decimal bytes; temporary-file sizes use binary MiB.

## Language

**English is the default**, including on a Mac configured in French. Select **Français** using **Language** at the bottom of the sidebar, the Language menu, or application settings. The choice is saved for BenchLibre and the interface updates immediately. System-provided menus and dialogs may require reopening the app. Numbers and dates follow the selected language.

Reports retain the human-readable text recorded when they were created. Historical text is labeled **Original report text**. JSON identifiers, canonical units and condition values remain compatible with earlier reports. See [localization](docs/LOCALIZATION.md) for resource and formatting details.

## Understand your results

Each card gives a familiar name, a description of the measured work, an expanded unit and an explanation under **Understand this result**. Higher throughput means more work per second; lower memory access time means less waiting in that workload.

When a compatible earlier session exists, cards describe the observed change in words and as a percentage. The reference must have the same hardware configuration, workload, measured tests, settings and calculation metadata. Differences in macOS version, power and thermal conditions are flagged. Reference selection runs off the interface thread.

Your first session becomes a starting point. These explanations do not assign a health grade, global ranking or game FPS prediction. Technical details and raw results remain available.

## Use the application

Open **BenchLibre.app**, select tests, duration and **1, 3 or 5 passes** (three by default), then start the session. Stopping cancels the session without saving an incomplete report. **Nerd details** shows protocol and measurement metadata.

The displayed value is the actual median pass, retaining its associated work count, timing, checksum and samples. JSON includes all passes, variation and observed conditions. Standard deviation and coefficient of variation are absent for a single pass.

The target duration applies to **each pass of each test**:

- **Quick**: 2.5 seconds, useful for checking operation.
- **Standard**: 10 seconds.
- **Extended**: 30 seconds.

Preparation, calibration, warm-up and validation add time. File tests can finish earlier when they reach their byte budget. A short validation run is not a performance reference.

**Export results** creates a copy in **Exports inside the application container** and reveals it in Finder. You can copy it manually. The app has no user-selected external-file entitlement.

## Storage and security

BenchLibre requires **App Sandbox** and **Hardened Runtime**, checks its signature at startup and rejects unexpected entitlements. It uses no shell commands, scripts, privileged helpers, administrator password prompts or network connections.

Foundation supplies the container's Application Support directory:

- **Reports**: validated local history.
- **Exports**: JSON copies explicitly requested by the user.
- **Temporary**: private file-test data removed at the end of each pass.

With the current identifier, the base path is normally `~/Library/Containers/org.benchlibre.mac/Data/Library/Application Support/BenchLibre`. The diagnostic mode reports the actual system-provided paths. The app also reads its signed resources and uses system frameworks.

Version 0.2 history outside the container is not automatically imported or deleted. After first launch creates the container, you can copy compatible reports into Reports using Finder. Size and consistency checks apply on load. Report access is bounded and rejects symbolic links, special files and files with multiple hard links. This does not protect a compromised operating system or another process already authorized to modify the container.

## File I/O

Each pass creates a private **64 MiB** file on the container's volume and performs **64 MiB of preparation writes** outside timing. Measured transfers are capped at **512 MiB for writing** or **64 GiB for reading** per pass. Repeated passes multiply this I/O.

`F_NOCACHE` must succeed. It disables descriptor data caching without certifying bypass of device or controller caches. These are sequential file tests, without raw SSD access or external-disk selection.

## Build with Xcode

Requirements: **Xcode with Swift 6 and the macOS SDK**, macOS 14 or later, and a GPU supporting the Metal kernel.

1. Open **BenchLibre.xcodeproj** in Xcode.
2. Select the shared **BenchLibre** scheme and **My Mac** destination.
3. Keep the scheme's **Release** configuration and choose **Product → Build**.
4. Reveal **BenchLibre.app** from Xcode's Products group in Finder and open it.

The target assembles resources and applies sandboxing and Hardened Runtime without a script phase. Local ad hoc signing does not require a developer account. The scheme launches Release without a debugger or `get-task-allow`. Keep build products in local Xcode DerivedData; synchronized folders can attach metadata that invalidates strict signature verification. Do not relax security settings to bypass build errors.

**Package.swift builds only BenchCore, C kernels and tests**, not the signed application. Open the package in Xcode and choose **Product → Test** for library development. Tests do not replace Release measurements on target hardware; Metal tests may skip without a usable GPU. Debug and memory-instrumented builds are not performance references.

## Headless modes

The executable inside the signed app accepts launch arguments, configurable in **Product → Scheme → Edit Scheme → Run → Arguments** without shell scripts:

| Argument | Purpose |
| --- | --- |
| `--info` | Hardware metadata as JSON, without a benchmark |
| `--security-info` | Signature policy and container paths |
| `--smoke` | 0.25-second validation, one pass, at most two CPU workers |
| `--cli` | Headless session with the app's default measurement settings |
| `--seconds N` | Target duration per pass, 0.1 to 120 seconds |
| `--repetitions N` | 1, 3 or 5 passes |
| `--threads N` | CPU worker count |
| `--tests LIST` | Comma-separated test identifiers, or `all` |
| `--language en` / `--language fr` | Message language; English by default, independent of saved GUI preference |
| `--output NAME.json` | JSON copy in container Exports, with no external path |

Tests accept `cpu,gpu,memory,latency,disk-read,disk-write`; `all` includes file I/O. Without a selection, the first four are used. Without `--output`, JSON goes to standard output. Export names allow only ASCII letters, digits, hyphens, dots and underscores; external paths are rejected before computation.

## Compare and interpret

Use the same workload version, Release build, settings and similar conditions: power source, energy mode, competing apps and thermal state. Do not automatically combine suite-v2 and suite-v3: timing windows and GPU output handling changed. Version 0.3.2 localization does not change suite-v3 kernels or counted work.

FP32 compute does not measure game FPS, ray tracing or a 3D engine. The triad counts logical bytes rather than physical DRAM traffic. Memory access time includes the cache hierarchy in a fixed 64 MiB set; 64-byte slots do not claim to reproduce every processor's cache-line size.

macOS schedules workers across Performance and Efficiency cores. Sustained work does not certify 100% hardware occupancy. Power, Low Power Mode and thermal conditions are observed about once per second and can miss brief events. Thermal state is not a temperature in °C or proof that throttling did not occur.

Numerical and structural validation checks local consistency. It does not certify the authenticity of a shared score, a remote computer or exhaustive hardware stability. 3D rendering, ray tracing, NPU tests, advanced sensors and a worldwide ranking remain future work.

## Distribution, privacy and license

The local build is signed **ad hoc**, without Developer ID or Apple notarization. Public distribution recognized by Gatekeeper still requires Developer ID signing and notarization. A developer-identity warning differs from a malware detection. No absence of XProtect or VirusTotal false positives is guaranteed; nothing is automatically submitted to those services.

BenchLibre collects no telemetry, uploads no reports and needs no account. JSON sharing is manual. There are **no external third-party dependencies**; project code uses the [MIT license](LICENSE). Apple frameworks retain their own license terms.

- [Protocol (French)](docs/PROTOCOL.md)
- [Dependency and license inventory (French)](docs/DEPENDENCIES.md)
- [Localization](docs/LOCALIZATION.md)
- [Validation record (French)](docs/VALIDATION.md)
- [Core engines](Sources/BenchCore)
- [C kernels](Sources/BenchKernels)
- [macOS application](Sources/BenchLibre)

The MIT license permits study, modification and redistribution. New local changes are not automatically published online.
