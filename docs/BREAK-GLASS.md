# Break-glass: recover without Timecrate

If Timecrate, or the machine it ran on, is gone, three standard tools are enough — `gpg`, `zstd`
and `tar` — plus the escrowed secret key. Nothing from this project has to be installed.

## 0. What you need

- **The kit**: `timecrate-<ts>.tar.zst.gpg`, fetched from the remote with rclone or downloaded from
  the provider's web interface. Kits written before 3.0.0 are named `timemachine-<ts>.tar.zst.gpg`;
  everything below applies to them unchanged, except that the manifests directory inside is called
  `TIMEMACHINE-MANIFESTS`.
- **Its checksum**: `<kit>.sha256`, beside it on the remote.
- **The escrowed secret key**: `timecrate-secret.asc`, from wherever you escrowed it — the printed
  sheet (`timecrate escrow-doc`, with a QR code), a password manager, another machine. A machine
  that has used Timecrate since before 3.0.0 may have escrowed it as `timemachine-secret.asc`; it is
  the same key.
- **The signing public key**: `timecrate-signing-public.asc`, which proves the kit is yours. It is
  on the escrow sheet, with its fingerprint.

## 0b. PQ-wrapped kits (TIMECRATE_CRYPTO=hybrid, 3.1.0+)

A hybrid kit's first line starts with `TIMECRATE-PQ1`. It is the signed kit below wrapped in
one more envelope, and it needs the PQ secret key from the escrow sheet (`pq-secret.pem`)
plus OpenSSL 3.5+ before any of the GPG steps:

```sh
head -n1 KIT | cut -d' ' -f4 | base64 -d > kem.ct
openssl pkeyutl -decap -inkey pq-secret.pem -in kem.ct -secret kem.ss
od -An -tx1 -v kem.ss | tr -d ' \n' > kem.pass
tail -n +2 KIT | gpg --batch --pinentry-mode loopback --passphrase-file kem.pass -d -o inner.gpg
```

`inner.gpg` is now the ordinary signed kit: continue at step 1 with it. Classic kits (no
`TIMECRATE-PQ1` first line) skip this section entirely.

## 1. Import the keys

```sh
gpg --import timecrate-secret.asc            # decryption
gpg --import timecrate-signing-public.asc    # authentication
```

## 2. Check integrity

```sh
sha256sum -c timecrate-<ts>.tar.zst.gpg.sha256    # must print: OK
```

The checksum only catches damage in transit. The signature in the next step is the proof.

## 3. Decrypt, verify the signature, then extract

Never pipe `gpg` straight into `tar`: gpg reports the signature only at the end of the stream,
after tar has already written everything. Decrypt to a file, check the signature, and only then
extract:

```sh
gpg --status-file st.txt -o kit.tar.zst -d timecrate-<ts>.tar.zst.gpg
grep VALIDSIG st.txt    # MUST print a line with the signing fingerprint from the escrow sheet.
                        # No VALIDSIG means a forged or tampered kit: STOP
                        # (unless gpg failed for lack of space: see below).
                        # (The tool refuses an unpinned signature the same way; to pin one
                        #  explicitly, pass TIMECRATE_EXPECT_SIGNER=<fingerprint from the sheet>.)
mkdir -p restore        # inspect first: extract into ./restore
zstd -dc --long=27 < kit.tar.zst \
  | sudo tar --numeric-owner --acls --xattrs -xpf - -C restore
```

Decrypt on disk-backed space with room for about twice the kit, such as your home directory or
`/var/tmp`, and extract where there is room for the uncompressed contents as well: on a modern
Ubuntu `/tmp` is a RAM-backed tmpfs that cannot hold a kit. A decrypt that runs out of space ends
without a `VALIDSIG` line, and that is not evidence of tampering: check the free space (`df -h .`)
and gpg's own error first, then decrypt again where there is room.

`--long=27` matches the 128 MiB window the kit was compressed with and needs only about 128 MB of
memory, so recovery works on a small rescue machine.

To restore straight onto a freshly installed system instead of `./restore`, use `-C /` and leave
the manifests out — they describe the machine, they are not part of it:

```sh
zstd -dc --long=27 < kit.tar.zst \
  | sudo tar --numeric-owner --acls --xattrs \
      --exclude=TIMECRATE-MANIFESTS --exclude=TIMEMACHINE-MANIFESTS -xpf - -C /
```

## 4. Rebuild the packages from the manifest

First put the captured APT sources and their keyrings in place; third-party repositories fail
without them:

```sh
sudo mkdir -p /etc/apt/keyrings /usr/share/keyrings
sudo cp -a restore/etc/apt/sources.list /etc/apt/ 2>/dev/null || true
sudo cp -a restore/etc/apt/sources.list.d/. /etc/apt/sources.list.d/
sudo cp -a restore/etc/apt/trusted.gpg.d/. /etc/apt/trusted.gpg.d/
sudo cp -a restore/etc/apt/keyrings/. /etc/apt/keyrings/ 2>/dev/null || true
sudo cp -a restore/usr/share/keyrings/. /usr/share/keyrings/
```

Then replay the selections. Foreign architectures come first, or one package with an unavailable
dependency of another architecture makes apt refuse the whole transaction; and `merge-avail` is
required on a fresh machine, or `--set-selections` silently records nothing:

```sh
M=restore/TIMECRATE-MANIFESTS                 # restore/TIMEMACHINE-MANIFESTS in an older kit
while read -r a; do [ -n "$a" ] && sudo dpkg --add-architecture "$a"; done < "$M/dpkg-foreign-architectures.txt"
sudo apt-get update
sudo sh -c 'apt-cache dumpavail | dpkg --merge-avail'
sudo dpkg --set-selections < "$M/dpkg-selections.txt"
sudo apt-get dselect-upgrade
```

A very old kit may have no `dpkg-foreign-architectures.txt`. The architectures are still there, as
the `:arch` suffixes in `dpkg-selections.txt`:
`awk '{print $1}' "$M/dpkg-selections.txt" | sed -n 's/.*:\([a-z0-9-]*\)$/\1/p' | sort -u`.

The rest — desktop settings, units, crontabs — is in the extracted tree. [RESTORE.md](RESTORE.md)
has the whole machine in order.

> A kit is a plain `tar` of real paths (`etc/…`, `home/…`, `var/lib/…`), compressed with zstd and
> encrypted with GnuPG (AES-256). Any machine with those three tools can open it.
