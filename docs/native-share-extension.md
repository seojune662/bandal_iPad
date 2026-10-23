# Native iPad Share extension

`BandalShare` is embedded in the Swift `Bandal` app. Its bundle identifier is
`app.bandal.ipad.share`; both targets use App Group `group.app.bandal.ipad`.
The extension displays 과목 / 폴더 selectors from a snapshot the app publishes
after startup and course/folder changes. It accepts PDFs, images, Markdown/text
files, plain text, and web URLs (saved as Markdown, without downloading a page).

Saving copies the shared items into the App Group. Opening/returning to Bandal
imports them into the selected destination through the native library repository.
The extension says that import will happen when Bandal is opened; it does not use
unsupported APIs to launch its containing app from another app's share sheet.

Each item has a persistent receipt, so restarting after a partially completed
batch does not create duplicate materials. Failed batches stay in the shared
inbox. Missing/deleted destinations are reported without silently redirecting a
file to another course. The destination catalog contains relative folder paths
and a per-profile workspace UUID; items for another profile remain queued.

Limits: 20 items, 100 MiB per file, 250 MiB per share, 500 MiB committed inbox.
Plain text is limited to 5 MiB. Names are sanitized, payload paths are UUIDs,
symlinks/traversal are rejected, and batch publication uses an atomic directory
move. NSItemProvider temporary files are copied inside their completion callback.

## Signing and device verification

Before device/archive distribution, the provisioning profiles for **both** app
identifiers must include the registered App Group `group.app.bandal.ipad`.
The source entitlement and target exist in `project.yml`, but editing these files
does not register capabilities in an Apple developer account. A signing failure
must be resolved by configuring the app IDs/profiles, not by removing the group
entitlement or shipping an unconnected extension.

Verify on an iPad with signed builds: launch Bandal once, create a course/folder,
share a PDF from Files or KakaoTalk, select 반달 (More if initially hidden), choose
the folder and save, then return to Bandal. Repeat with Photos, a web URL, multiple
files, and a killed/relaunched app. Verify names, destination, byte preservation,
and a second foreground transition without duplicates. Simulator/unit validation
does not establish that a third-party host presents its share options identically.

`NativeExternalShareUITests` is an explicit integration check. It requires a
simulator build signed/ad-hoc with the App Group entitlements, a recent synthetic
`Bandal Share Fixture.png` photo installed using `xcrun simctl addmedia`, and
`BANDAL_PHOTOS_UI_FIXTURE=1` in the UI test runner's environment (for example the
test target's `EnvironmentVariables` in a copied `.xctestrun`). Without this
explicit opt-in, the test skips with its prerequisite explanation. The ordinary
unsigned `Scripts/test.sh` run does not require or modify the Photos library.

Validated on 2026-10-20: the real Photos share sheet showed Bandal, explicit
course/folder selection saved the fixture, foreground import put it in that
folder, and a full app restart kept exactly one item. Result:
`.build/improvements-ui-share-final.xcresult`. This UI test used ad-hoc simulator entitlements; it does not claim physical
KakaoTalk testing. Subsequently the Release app and embedded extension were
signed with new development profiles including the App Group and paired iPad,
installed as 1.0.0 (4), and the real device produced the shared destination
catalog. See [device installation](ipad-interaction-improvements.md).

The subsequent Release **1.0.0 (5)** performance update was installed on the same
iPad on 2026-10-20. Both signed targets and provisioning profiles still include
the App Group and device. The device's two-course destination catalog was
preserved and readable, and the Photos share integration test passed again on
the simulator (`.build/performance-ui-final.xcresult`). Physical KakaoTalk/Photos
share UI remains untested. See the [latest installation and preservation
record](ipad-performance-2026-10-20.md).

Apple references:
- [Sharing data with an app group and activation rules](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)
- [NSItemProvider file representation lifetime](https://developer.apple.com/documentation/foundation/nsitemprovider/loadfilerepresentation(fortypeidentifier:completionhandler:))
