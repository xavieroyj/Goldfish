# Goldfish

A native macOS SwiftUI recovery studio for accidentally deleted files on SD cards and other volumes.

## What it does

- Scans a selected volume read-only for JPEG, TIFF/RAW, PNG, GIF, PDF, MKV, and MP4 signatures. Archive recovery is intentionally not included.
- Reads FAT32 and exFAT directory metadata when available. Surviving deleted-file records can recover files without a recognized signature when their cluster extents can be reconstructed; FAT32 contiguous extents may be estimates when the deleted FAT chain has been cleared.
- Restores surviving original filenames when directory metadata maps to a recovered file's first cluster.
- Exposes recovery source, physical data ranges, fragmentation evidence, EXIF metadata when present, scan speed/ETA, candidate ranges, and read-error ranges. These are evidence and diagnostics, not a guarantee that a recovered file is complete.
- Exports recovered data to a folder chosen by you, never back to the source card.
- Keeps the card connected and untouched while scanning.
- Lists internal volumes as unsupported and prevents scanning them. macOS APFS recovery is not currently implemented.
- When macOS blocks device access, the app can open Full Disk Access settings and request membership in macOS's built-in operator group through an administrator prompt. macOS may require signing out and back in afterward.

## Run

```sh
swift run Goldfish
```

To build a release executable:

```sh
swift build -c release
```

The binary is written to `.build/release/Goldfish`.

To package the release executable as a macOS app:

```sh
Scripts/build-app.sh
```

The final app icon and bundle metadata are kept in `Packaging/`. The icon-preparation utility is retained in `Scripts/prepare-app-icon.swift` for manually regenerating the icon if needed.

## Read-only device benchmark

To compare one, two, and four concurrent readers on a connected card without writing to it:

```sh
/usr/sbin/diskutil list external physical
Scripts/benchmark-read.py /dev/rdisk4s1 --sample-mib 1024
```

Replace the example path with the card partition shown by `diskutil`. The benchmark performs reads only.

## Important recovery notes

Recovery combines signature-based carving with best-effort FAT32/exFAT deleted-entry recovery. A surviving cluster chain can recover fragmented files; if FAT32 has cleared the chain, a contiguous layout may be estimated from the deleted entry's start cluster and size. Such estimates can include incorrect data. Deleted records and file data may be missing, reused, or overwritten, and carved results can be partial or still present. A missed signature does not prove a file is unrecoverable. The app does not currently recover arbitrary files from unsupported filesystems or reconstruct data erased by TRIM, encryption, or overwritten sectors. macOS may deny raw device access to a normal app process. Always test on a copy or a non-boot, non-system card, and export to a separate drive.

Do not format, initialize, repair, or write to the affected card before attempting recovery.
