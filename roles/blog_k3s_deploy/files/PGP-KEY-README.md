# Blog impressum PGP key

The public key served at <https://www.apt-upgrade.me/publickey.asc> and listed
on the imprint page (`/impressum/`). Visitors use it to send Raphael encrypted
email.

## Current key

| Field | Value |
|-------|-------|
| UID | Raphael Münch \<raphael.muench@proton.me\> |
| Type | RSA 4096 ([SC] primary + [E] encryption subkey) |
| Key ID | `B487DFA14F1CB07E` |
| Fingerprint | `64C5 8186 0575 AC79 64EB EB70 B487 DFA1 4F1C B07E` |
| Created | 2026-07-31 |
| Expires | **2031-07-30** |

## Files in this directory

| File | Tracked in git? | Purpose |
|------|-----------------|---------|
| `publickey.asc` | **yes** | Public half. Deployed to the webroot by `tasks/dirs.yml`, served at `/publickey.asc`. Safe to publish. |
| `privatekey.asc` | **no – gitignored** | Private half. **Never commit, never push anywhere.** |
| `revoke-B487DFA14F1CB07E.rev` | **no – gitignored** | Revocation certificate. Import + send to keyservers if the key is ever compromised or lost. |

The `.gitignore` at the repo root blocks `privatekey.asc` and `*.rev`, so they
cannot reach GitHub or the internal repo. `git check-ignore` confirms this.

## Import + protect the private key

The private key was generated **without a passphrase** so it is immediately
usable. Add one before relying on it:

```bash
gpg --import privatekey.asc
gpg --edit-key B487DFA14F1CB07E     # then: passwd  ->  save
```

## Off-repo backup (important)

Because the private key is gitignored, it is **not** part of any repo backup.
The previous key was lost exactly this way. Keep an independent copy of
`privatekey.asc` + the revocation cert in a password manager or offline medium.
A working copy currently lives in `~/apt-upgrade-blog-pgp-backup-20260731/`.

## Rotating the key (what was done on 2026-07-31)

1. `gpg --batch --gen-key` with a params file (RSA 4096, 5y, `%no-protection`),
   same UID as before.
2. Export both halves: `gpg --armor --export <id> > publickey.asc` and
   `--export-secret-keys > privatekey.asc`; copy the `.rev` from the keyring's
   `openpgp-revocs.d/`.
3. Deploy `publickey.asc` (playbook `blog.yml`, or scp to
   `/srv/wordpress-www/publickey.asc`, root:root 0644).
4. Update Key ID + fingerprint on the imprint page (WordPress page ID 54) via
   wp-cli `post update`.
5. Commit **only** `publickey.asc` (+ this README); the private key stays local.
