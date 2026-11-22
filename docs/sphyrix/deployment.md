# OpenCloud on the sphyrix homelab: deployment guide (fork features)

This fork adds three posixfs features so OpenCloud can serve a NAS tree that
people also use over SMB: files written through OpenCloud belong to the human,
edits made over SMB show up live, and existing home directories become
personal spaces. This page is the operating contract for the `drive` chart in
the homelab Gitea; it is deliberately self-contained so a rebuild needs no
memory.

## The fork options

| Env var | What it does | Needs |
|---|---|---|
| `STORAGE_USERS_POSIX_USE_SPACE_OWNER=true` | Every operation inside a space runs as the uid and gid of the space root, so new files, directories, metadata, trash and revisions are owned by the space owner on disk. Implies `use_space_groups`. | `storage-users` runs as root; the export does not squash root; the space root is owned by a uid the NAS resolves (a domain user after the AD join), never a synthetic one. |
| `STORAGE_USERS_POSIX_ADOPT_EXISTING_SPACE_ROOTS=true` | When the personal space path template resolves to a directory that already exists without space metadata, it is adopted as the space root with its contents intact instead of refused. | A path template that points at the existing homes, e.g. `homes/{{.User.Username}}` (the exact naming comes from the QNAP join, spike #5). |
| `STORAGE_USERS_POSIX_PERSONAL_SPACE_FALLBACK_PATH_TEMPLATE=cloud/{{.User.Username}}` | Makes the personal space path template adopt-only: a user without a directory there (a cloud-only person with no NAS home) gets the space under this template instead of a bogus home in the domain homes tree. `STORAGE_USERS_POSIX_FALLBACK_UID`/`_GID` own those spaces, so `use_space_owner` acts as that one identity in all of them. | A uid/gid for the cloud-only spaces; it only has to exist on the NAS if people browse that directory over SMB. |
| `STORAGE_USERS_POSIX_IGNORED_DIR_PATTERNS=.*,@Recycle,@eaDir` | Directories whose name matches one of the globs, at any depth, are neither scanned at startup, watched, assimilated nor listed: desktop trash, `.git`, editor caches and the QNAP folders stay out of the index. Files with matching names are untouched. | Nothing; empty by default. |
| `STORAGE_USERS_POSIX_LOCK_PRUNE_INTERVAL=24h` | Once per interval (first time one interval after start), every space's `.oc-nodes/locks` directory is swept: lock files older than the interval are removed when they belong to a path's initial assimilation (named after the path) or to a node id that no longer exists. Locks younger than the interval are never touched, which protects locks held right now. `0` disables it. | Nothing; 24h by default. |
| `STORAGE_USERS_POSIX_WATCH_FS=true` + `STORAGE_USERS_POSIX_WATCH_TYPE=smbnotify` | Live change detection through the SMB server: one session long-polls recursive `SMB2 CHANGE_NOTIFY` on the share directory that corresponds to `STORAGE_USERS_POSIX_WATCH_ROOT`; creates, writes, renames and deletes by any SMB client reach the assimilator within milliseconds. A dropped session or a server overflow triggers a rescan of the watch root. | `STORAGE_USERS_POSIX_SMBNOTIFY_{ADDRESS,SHARE,PATH,USERNAME,PASSWORD,DOMAIN}`; an account with read access to the homes tree (nothing else). |

Everything else is stock OpenCloud: Keycloak with AD federation for login
(`OC_OIDC_ISSUER`, `PROXY_*`), local Keycloak users for cloud-only people,
Collabora or ONLYOFFICE through the collaboration service.

## Transport: what the NAS actually supports (measured 2026-11-20)

posixfs keeps metadata in extended attributes and needs `flock`. From a
privileged pod on Talos 1.12.0 (kernel 6.18) against `192.168.61.2`:

| | NFS 4.2 | NFS 4.1 | SMB (cifs) |
|---|---|---|---|
| Mounts | **no** (`Protocol not supported`) | yes, `noac` honoured | yes (`CONFIG_CIFS=y`, `CONFIG_CIFS_XATTR=y`) |
| user xattrs | n/a | **no** (`Not supported`; RFC 8276 is 4.2-only) | as SMB EAs, server dependent |
| flock | n/a | yes | needs `nobrl`/`nolock` semantics, unverified |
| root squash | n/a | root not squashed; unknown uids mapped to guest | all files appear as the mount uid |
| per-user ownership | n/a | yes, for uids the NAS knows | **no** (single mount identity) |

So, as shipped, posixfs cannot run over this QNAP's NFS. Three ways forward
were considered (joshualawson/opencloud#6); **option 3 was chosen on
2026-11-20**, see "Chosen layout" below:

1. **NFS 4.2 from the NAS.** If the QTS version in use (not recorded; check
   Control Panel → System → Firmware) or a newer one offers v4.2, the stock
   driver works unchanged. QNAP's community forum has an open feature request
   for v4.2 on QuTS hero, which suggests it is not there yet.
2. **No-xattr metadata in posixfs.** Make the driver work with the
   `messagepack` sidecar backend (a `.mpk` file beside each node). NFS 4.1
   then suffices and ownership and `smbnotify` keep working. Cost: a reva
   change (nine direct xattr call sites in `blobstore`, `tree/assimilation`
   and `checkStorage` must go through the metadata backend), sidecar files in
   the tree (hidden from SMB with `veto files`), and unmeasured overhead.
3. **`storage-users` on the NAS.** Run only that service in Container Station
   with the homes tree as a local bind mount; the rest of OpenCloud stays on
   Talos and reaches it over gRPC. xattrs and even inotify work natively and
   no NFS export is needed. Cost: one component outside the cluster pipeline.

## Chosen layout: storage-users on the NAS

The TS-863U-RP (QTS 5.2) has no firmware with NFS 4.2, so `storage-users`
runs on the NAS itself, in Container Station, with `/share/homes` bind-mounted
at `/data/homes` and `/share/opencloud` at `/data`. Every other service runs
on the cluster in one Deployment (`OC_EXCLUDE_RUN_SERVICES=idp,storage-users`,
`OC_ADD_RUN_SERVICES=collaboration`). The two halves meet through:

- the cluster's NATS, exposed on a LoadBalancer (`MICRO_REGISTRY_ADDRESS`,
  `OC_EVENTS_ENDPOINT`, `OC_CACHE_STORE_NODES`, `OC_PERSISTENT_STORE_NODES`,
  `STORAGE_USERS_ID_CACHE_STORE_NODES` on the NAS side);
- the NAS service binding and therefore advertising its LAN address
  (`STORAGE_USERS_GRPC_ADDR=<nas ip>:9157`, `..._HTTP_ADDR=<nas ip>:9158`,
  `..._DATA_SERVER_URL=http://<nas ip>:9158/data`), which the registry hands
  to the cluster services;
- the NAS service dialling the gateway and settings services directly with
  the `dns:///<lb ip>:<port>` form, which skips the registry (its entries for
  cluster services are pod addresses the NAS cannot reach).

The NAS container runs as root with host networking; `use_space_owner`,
`adopt_existing_space_roots`, `watch_fs` with `inotifywait` and `scan_fs` are
on. `smbnotify` is not needed in this layout. The homelab `drive` chart owns
the compose file and starts it through Container Station's TLS Docker API
from a Helm hook Job, so both halves deploy in one release. The image is
built on Gitea by the `opencloud-build` repo from the commit it pins; GitHub
only hosts the fork source and its test workflow.

## Runtime contract for the chart (joshualawson/opencloud#3)

- `storage-users` is its own Deployment with `runAsUser: 0`. The capability
  set that would let it drop root is `CAP_SETUID`, `CAP_SETGID`,
  `CAP_DAC_OVERRIDE`, `CAP_FOWNER`, `CAP_CHOWN`; whether the NFS server
  honours that without uid 0 on the wire is untested, so start with root.
- Mount the homes export at `STORAGE_USERS_POSIX_ROOT` (`vers=4.1,noac` today;
  `4.2` once available) and set `STORAGE_USERS_POSIX_WATCH_ROOT` to the same
  path.
- `inotifywait` is not needed in the image when `watch_type=smbnotify`.
- Secrets come from Vault through the Vault Secrets Operator: the SMB
  notification account password (`homelab/identity/svc/opencloud-notify`),
  the OIDC client secret (`homelab/sso/clients/opencloud`), and OpenCloud's
  own `OC_JWT_SECRET`, `OC_TRANSFER_SECRET`, `OC_MACHINE_AUTH_API_KEY`,
  `OC_SYSTEM_USER_API_KEY`.
- Hidden directories posixfs creates inside each space, for the QNAP
  `veto files` setting: `.oc-nodes`, `.oc-trash`, `.oc-tmp`, and the
  per-file lock files `*.lock` / `*.mlock` created next to nodes while a
  write is in flight.

## AD side

- Users carry RFC 2307 `uidNumber`/`gidNumber`; the values must be the ones
  the QNAP resolves for the domain user (measured with `ls -n` over NFS on a
  file the user created over SMB), because the NAS maps unknown uids to guest.
- Service account for `smbnotify`: `svc-opencloud-notify`, member of a group
  with read access to the homes share and nothing else.

## Known limitations after milestone M4

- Ownership is per space, not per actor: a share recipient's writes into
  Joshua's space are owned by Joshua. Intended.
- Renaming a user does not rename the home directory on the NAS.
- Versions written by OpenCloud live in `.oc-nodes` inside the space, not in
  Samba's shadow copies.
