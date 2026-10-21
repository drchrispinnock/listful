# Listful

A native macOS outliner for task lists, in the spirit of Workflowy but with no
subscription. Lists are plain Markdown files you own.

- Bulleted tasks you can nest with Tab / Shift-Tab and collapse to their parent
- Tasks are Open, Done (struck through or ticked) or Decrufted (tidied away, never deleted)
- `#`, `##`, `###` headings; a `#` on the first line is the list's title
- A sidebar of lists: one folder of `.md` files (default `~/Documents/Task Lists`),
  plus any Markdown files elsewhere that you add

Requires macOS 14 or later. Currently under development.

## Building

Only the Xcode Command Line Tools are needed.

```sh
swift build          # debug build
scripts/test         # run the tests
swift run Listful    # run from the terminal
```

## Releasing

`scripts/release` builds a universal `Listful.app`, signs it with hardened
runtime, wraps it in a DMG, notarizes and staples it. Output goes to `dist/`.
The version is read from `VERSION`; the build number is the git commit count.

One-time setup:

1. **Developer ID certificate.** In Keychain Access choose *Certificate
   Assistant ▸ Request a Certificate From a Certificate Authority…*, enter your
   email, pick *Saved to disk*. At
   [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates/add)
   create a **Developer ID Application** certificate from that request, download
   it and double-click it to install. `security find-identity -v -p codesigning`
   should then list it.
2. **Notarization credentials.** Create an app-specific password at
   [account.apple.com](https://account.apple.com) (*Sign-In and Security ▸
   App-Specific Passwords*), then store it in the keychain:

   ```sh
   xcrun notarytool store-credentials listful-notary \
       --apple-id you@example.com --team-id YOURTEAMID
   ```

   Your team ID is the 10-character code in brackets at the end of the
   certificate's name.
3. **Update signing key.** Check for Updates uses
   [Sparkle](https://sparkle-project.org), which only installs updates signed
   with the EdDSA key whose public half is `SUPublicEDKey` in
   `packaging/Info.plist`. The private key lives in the login keychain (account
   `listful`). On a new Mac, export it from the old one and import it:

   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account listful -x ~/listful-sparkle.key   # silent; check the file exists
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account listful -f ~/listful-sparkle.key
   ```

   Keep a copy somewhere safe: if it's lost, existing installs can't be
   updated and users have to download the next version by hand.

Like the certificate's private key, the notarization profile and update key
are per keychain, so each Mac you release from needs all three.

Then:

```sh
scripts/release            # signed + notarized dist/Listful-<version>.dmg, plus dist/appcast.xml
scripts/release --adhoc    # local signature only, to test the packaging
```

Before releasing, bump `VERSION` and add a `## <version>` section to
`CHANGELOG.md` describing every user-visible change in detail; the script won't
build without one. Those notes go on the GitHub release and in the app's update
window. Then tag and upload the DMG and the appcast:

```sh
git tag v$(cat VERSION) && git push origin v$(cat VERSION)
gh release create v$(cat VERSION) dist/Listful-*.dmg dist/Listful-*.dmg.sha256 dist/appcast.xml \
    --title "Listful $(cat VERSION)" --notes-file dist/release-notes.md
```

The app's update feed is `releases/latest/download/appcast.xml` of that repo
(`RELEASE_REPO`, default `drchrispinnock/listful`), so the newest
non-prerelease release is always the one offered. The repo must be public for
the feed and downloads to work.
