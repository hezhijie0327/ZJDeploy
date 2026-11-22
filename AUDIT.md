# AUDIT.md — ZJDeploy audit playbook

Reusable playbook for whole-repo ZJDeploy audits: baseline → dimension scans (grep is the audit command) → sprint fixes → adversarial fix-surface re-check → gates. Shell deployment tooling, not a service: the blast radius of a bug is "a wiped or unbootable machine", so correctness gates weigh more than performance ones.

Goal: **audit round by round until a round produces no new findings.** Every fix carries a verification (function-level Docker test where possible, real-machine round for boot chains); each round lands new root-cause patterns in §5 — never audit the same mistake twice. No standalone round archives; historical fix details live in git log.

## 1. Baseline (start of every round)

```sh
./build.sh                    # regenerate dist/ - a stale tree fails lint
./lint.sh                     # bash -n + shellcheck + step count + dependency order + freshness
bash tests/run_tests.sh       # unit tests (bash 3.2 and 5.x)
python3 tests/check_dependencies.py dist/*.sh   # the lint wrapper runs this too
```

- Focus surface = the commit diff since the previous round (`git log <previous-round-baseline>..HEAD`). Review boot-chain and orchestration-reorder commits one by one — historical incidents mostly sit at container boundaries we introduced ourselves.
- A `src/` change without its regenerated `dist/` in the same commit is an automatic finding (AGENTS.md rule; lint freshness would catch it on a fresh clone only).

## 2. Audit dimensions

The highest-yield entry points (the grep command is the audit command):

| Dimension | Entry point |
|------|------|
| Unsafe var under `set -u` | `python3 tests/check_dependencies.py dist/*.sh` — ORDER and NEVER-SET classes; also read its allowlist critically: a new allowlist entry must have a guard proving it |
| Container ordering | For each platform: top-level Process order vs where Install*/Configure* globals are assigned (the `86617db..` marathon had three of these) |
| Idempotency | `grep -rn '>> /etc' src/` — appends must be into files we truncate first; `ln -s` must rm -f the target path first |
| Swallowed output | `grep -rn '> /dev/null 2>&1' src/` — every suppression needs a reason (password redaction ok, error hiding not); chatty commands go through `RunLogged` |
| SIGPIPE traps | `grep -rn '| head' src/` — under pipefail, `find|head` and friends die 141; wrap or `|| true` with a comment |
| Quoting | `shellcheck --severity=warning` covers it; also `grep -rn 'for .* in \$' src/` for unquoted word splits |
| bash 3.2 compat | In `lib/core.sh` + `lib/modules/*.sh` (not `debian/`): no assoc arrays, no namerefs, no `${var,,}`, guard empty arrays with `${arr[@]+"${arr[@]}"}` |
| busybox ash compat | `src/platforms/reinstall/trans.sh`: no arrays, no `[[`, no process substitution, no `$'...'`; verify with `sh -n` **and** `dash -n` — modern alpine ash tolerates bashisms dash rejects |
| Partitions / boot | Any change touching partition_disk/format_and_copy/chroot_configure needs a PVE VM round before merge — GRUB one-time entry, initramfs injection and netplan replay are environment-sensitive (AGENTS.md) |
| Credential hygiene | Passwords only via `MintRandomPassword` + `RecordCredential`; never `echo`-interpolated into process lists; 0600 on credentials.txt and run logs |
| Branding / doc rot | `grep -rn -i 'autodeploy' .` ; AGENTS.md claims vs code (names, paths, defaults); README config table vs `src/config/*` knobs |
| Naming conformance | PascalCase verb-noun functions (`grep -rnE '^[a-z_]+\(\) \{' src/` outside trans.sh; `grep -rn 'local [A-Z]' src/`), UPPERCASE globals, lowercase locals |
| Log copy style | `grep -rn 'LogInfo\|LogWarn' src/ \| grep -F '" - '` must be empty: colon-only `key: value` separator, lowercase start, no trailing period, remediation in parentheses |
| Output alignment | Every summary block routes labels through one `printf '%-*s'` helper — hand-padded columns drift with variable-width labels |
| Modularity / dead code | Function inventory vs call sites across all five dist builds (zero dead code is the invariant); cross-platform body-similarity scan for renamed duplicates; module cohesion vs its header |
| Step totals | `grep -c RunStep dist/<Script>.sh` vs `ZJDEPLOY_STEP_TOTAL` — lint checks it, but new steps added during a fix round get missed |

## 3. Fix process

| Sprint | Scope | Criteria |
|--------|------|------|
| 1 | CRITICAL/HIGH | Fresh-machine aborts (set -u, missing groups/users), boot-chain failures, credential loss |
| 2 | MEDIUM | Idempotency drift, swallowed diagnostics, resume-path breakage, doc rot |
| 3 | LOW | Format uniformity, naming, micro-cleanups |

- Priority order: one-line fixes → pattern fixes (grep the same shape repo-wide after fixing one spot) → logic rewrites.
- Every fix **names its verification** in the commit body (Docker function test / lint+tests / real-machine round). One commit per class; subject states the concrete fix.
- Before committing: `./build.sh && ./lint.sh && bash tests/run_tests.sh` — zero warnings.

## 4. Quality gates

- **lint gate**: shellcheck warning-clean, dependency-order clean, step counts match, dist fresh.
- **Function gate** (Docker): behavior reproducible in a container gets a container test — `alpine:latest` for trans.sh helpers (dropbear login, mount sweep), `ubuntu:latest` for sshd/netplan semantics (`sshd -T`, `netplan generate`).
- **Real-machine gate** (Reinstall only, PVE VM): unattended run end-to-end — phase 1 stages, reboot installs, auto-reboot lands in GRUB, ssh works with the minted password. No container substitute: firmware/NVRAM/initramfs are the environment.
- **Resume gate**: interrupt a run mid-way, re-run, verify it skips completed steps and the access summary still prints passwords (credentials.txt fallback path).

## 5. Root-cause patterns (backfilled across rounds — check against them before fixing)

| Pattern | Root cause | Prevention |
|------|------|------|
| **Globals assigned after first use** | Install* steps consume structural globals that a later container assigns | Declare install-time globals at the top of the dispatching container; `tests/check_dependencies.py` enforces |
| **User consumed before creation** | Reordering containers put chown/usermod/add-to-group before the user-creating step | Create → modify → install-into-home, in that order; pre-create packages' groups (`groupadd docker`) when the package installs later |
| **Interactive stalls unattended** | `apt modernize-sources` prompts on stdin; `DEBIAN_FRONTEND` doesn't cover apt's own prompts | Feed `printf 'y\n'`; audit every new command for stdin reads under `curl \| sudo bash` (stdin is the script pipe) |
| **sudo strips env** | `export VAR && sudo bash` drops every REINSTALL_*/knob | Pass as `sudo VAR=value bash`; documented in AGENTS deployment guidelines |
| **Diagnostics swallowed** | `> /dev/null 2>&1` on apk/mkfs hid the real failure for hours | Errors stay visible; chatty output goes through `RunLogged` (file always, console at debug) |
| **Parted negative positions** | `mkpart ... -2048MiB` — getopt keeps scanning after the device name, eats `-2` as an option cluster | Absolute MiB ends computed from `/sys/block/*/size` |
| **Device nodes stale after partprobe** | devtmpfs occasionally skips a partition node while the kernel knows the partition | `mdev -s` after partprobe (alpine); check `/dev` not `/proc/partitions` when mkfs says "No such file" |
| **Same-session rerun residue** | Stray mounts from a failed run or a SIGPIPE-killed diagnostic block mkfs/parted | Sweep `/proc/mounts` for the target disk (deepest-first) before partitioning; never leave `find \| head` without a trailing umount |
| **Kernel partition-table cache** | Repeated same-session repartitions leave the kernel unable to BLKRRPART | Reboot the installer before rerunning when parted says "unable to inform the kernel" |
| **Cloud-image layout assumptions** | Ubuntu cloud images keep the ESP at partition 15, /boot at 13 — a 1..5 probe misses both | Probe by content (os-release / `EFI/*.efi` / vmlinuz), never by number |
| **grub.cfg keyed on PARTUUID** | A fresh partition table regenerates PARTUUIDs; fs UUIDs we preserve, PARTUUIDs we cannot | Rewrite the copied ESP grub.cfg to an fs-uuid search; `grub-install` in the chroot is the canonical writer |
| **Image lacks what we assumed** | resolute cloud images ship no openssh-server; host keys came from the cloud-init we disable | Install the package and `ssh-keygen -A` in the chroot; audit every "the image surely has X" assumption on release bumps |
| **Kernel-rejected sysctl aborts run** | One unsupported key (fq_pie/bbr) makes `sysctl --system` non-zero under ERR trap | Capture stderr, demote to warnings; clean distro leftovers (`99-cloudimg-ipv6.conf`, broken `99-sysctl.conf` symlink) — our deploy is authoritative |
| **Broken symlink blocks ln** | `-f` fails on a dangling link; plain `ln` then dies "Already exists" | `rm -f` the link first; recreate only while the target exists |
| **sshd first-match wins** | `sshd_config.d/*.conf` included before the main file override our password-login rewrite | Clear the snippets (matches ConfigureSshd in the deployment scripts) |
| **Pseudo-random minting** | `$RANDOM` for hostnames/tunnel octets (bash PRNG, 15 bits) | Everything minted from `/dev/urandom` (`od`/`head|base64`); no `$RANDOM` in src/ |
| **Credentials lost on failure** | Minted passwords only printed to console scrollback | `RecordCredential` → `~/.zjdeploy/credentials.txt` (0600); Die points at it |
| **Injection after exec** | Hooks printed after `exec switch_root` never run (exec replaces init) | Inject BEFORE the exec line; verify against the real initramfs init |
| **Missing apk repo** | qemu-img lives in alpine community, not main | Derive the sibling community repo from the main URL |
| **DHCP overrides collected facts** | udhcpc-first moved the installer off the expected static address | Static facts reassert first; dhcp only when no facts |
| **Allowlisted check neutralized** | A SAFE_ENV entry silenced the exact use-before-assignment check that a real failure later proved correct | Every allowlist entry cites its guard; re-arm attempts belong in each audit round (R1 removed DOCKER_APT_DISTRO/FRR_APT_LINE) |
| **Bare critical commands in no-set-e scripts** | trans.sh deliberately runs without set -e (die-in-pipeline cannot set exit status); new commands were added without `\|\| die` | Every installer command is either `\|\| die`, deliberate `\|\| true` with a comment, or pre-checked; R1+R2 added ~24 dies |
| **Bashism tolerated by modern ash** | `$'\n'` works on alpine's ash ≥1.28 but breaks dash/older ash — literal `$\n` lands in the generated netplan | `dash -n` trans.sh before merge; embed real newlines or use printf |
| **grep\|tail\|cut under pipefail** | A no-match grep returns 1 and the assignment trips the ERR trap — Die mid-summary | `\|\| true` on every fallback read of credentials.txt |
| **Secrets in argv** | `openssl passwd "$pw"` and `snmpwalk -A` expose plaintext in /proc cmdline | stdin modes where they exist (`openssl passwd -stdin`); accepted-risk note where not (snmpwalk, localhost verification only) |
| **Hand-padded log columns** | Labels padded with literal spaces break when a variable-width label (username) appears | One `printf '%-*s'` helper per summary block |
| **Mixed log separators** | ` - ` and `: ` both used between fact and consequence — inconsistent reading, broken greppability | Colon-only contract (AGENTS Log copy style); audit dimension greps for ` - ` |
| **Noun-only getters / UPPERCASE locals** | `StateFile` (no verb), `local LOCK_ROOT_STATUS` crept in during fixes | Naming dimension greps both shapes; getters get a Get prefix |
| **World-readable staged secrets** | The initramfs carries the password hash into /tmp and / at 0644 until reboot | chmod 700/600 at creation (workdir + built image) |
| **Slow-terminal UX reads as hang** | Silent curl/apk gave no progress for minutes | `--progress-bar` + per-file LogInfo; console mirror via `/dev/console` (openrc eats service stdout) |

## 6. Environment trap checklist

- **macOS dev host**: system bash is 3.2 — `bash -n` on src files using bash 4+ process substitution gives false syntax errors; lint checks the generated dist files for a reason. `zcat` behaves differently (use `gunzip -c`); no `shuf`.
- **Docker on macOS**: no `--privileged` loop devices — mount/partition code paths cannot be container-tested there; test those functions logically or in the PVE VM. `--cap-add NET_ADMIN` still leaves pseudo-interfaces (`erspan0`) in `/sys/class/net` that real hosts filter by MAC match.
- **`source.zhijie.online` proxy caching**: stale trans.sh served after push — always `?t=$(date +%s)` cache-busting (or scp) when refreshing installer scripts mid-round.
- **`find \| head` SIGPIPE**: the trailing umount behind `&&` never runs (find dies 141) — the exact cause of one stuck-mkfs round. Never put cleanup behind a pipe-fed `&&` chain.
- **PVE VMs**: NVRAM (efidisk) persists boot entries across reinstalls — `efibootmgr` wipe+create handles it, but manual UiApp checks mislead if you forget the efidisk survives.
- **busybox vs GNU**: busybox awk chokes on some dynamic-regex forms; busybox `grep -oE`, `sort -r`, `head -c` are fine. When a sweep silently matches nothing in alpine, suspect the tool before the data.

## 7. Closing loop

1. Fixes → `./build.sh && ./lint.sh && bash tests/run_tests.sh` zero warnings → function-level Docker tests for the touched behavior → real-machine round if the boot chain moved.
2. Adversarial re-check of the fix diffs (regressions introduced by the fixes themselves) → land new root-cause patterns in §5 → AGENTS.md/README consistency check against code.
3. Commit style per AGENTS.md (conventional prefix, one logical change, dist regenerated in the same commit, exactly one Co-authored-by line).
