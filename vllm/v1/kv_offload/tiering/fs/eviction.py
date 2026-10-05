# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project
"""FIFO cache eviction for the file system secondary tier.

The ``fs`` secondary tier is an append-only, content-addressed block store: a
block file is written exactly once (``os.replace`` of a temp file) and, because
``_store_block`` returns early when the destination already exists, is never
rewritten afterwards. Its ``mtime`` is therefore exactly the time the block
entered the cache, which makes an mtime-ordered deletion a true FIFO policy.

Using the filesystem as the ordering source (instead of an in-process queue)
also means the policy survives process restarts and stays correct when several
vLLM instances share one ``root_dir``, as the fs tier explicitly supports.

Eviction is opt-in: it is only active when ``max_bytes`` or ``min_free_bytes``
is configured, so an unconfigured tier keeps its historical never-delete
behaviour.
"""

import os
import threading
import time
from dataclasses import dataclass

from vllm.logger import init_logger

logger = init_logger(__name__)

# Only block files are evictable. Everything else in the cache directory
# (notably the tier's config.json) is left untouched. _store_block's in-flight
# temp files are named "<dest>_<n>.tmp" and are therefore never matched.
_BLOCK_SUFFIX = ".bin"

SUPPORTED_POLICIES = ("fifo",)

# Minimum spacing between repeated "cannot reach the limit" warnings, so a
# persistently over-budget tier does not flood the log every interval.
_STALL_WARNING_INTERVAL_SECONDS = 300.0


@dataclass
class EvictionStats:
    """Outcome of one eviction pass."""

    scanned_blocks: int
    scanned_bytes: int
    evicted_blocks: int
    evicted_bytes: int
    remaining_bytes: int
    free_bytes: int


class FifoCacheEvictor:
    """Keeps one cache directory under a byte budget by deleting oldest-first.

    A background daemon thread wakes every ``interval_seconds``, and only
    actually scans the directory when a store has happened since the previous
    pass, so an idle tier costs nothing.
    """

    def __init__(
        self,
        root_dir: str,
        *,
        name_prefix: str | None = None,
        max_bytes: int | None = None,
        min_free_bytes: int | None = None,
        eviction_policy: str = "fifo",
        min_file_age_seconds: float = 10.0,
        interval_seconds: float = 5.0,
    ) -> None:
        """Create an evictor for one tier's blocks.

        Args:
            root_dir: Directory that holds the tier's cache. Also the path
                used for the free-space check, so pass the configured offload
                root (the mount point) rather than a per-model subdirectory.
            name_prefix: When set, only first-level subdirectories of
                ``root_dir`` whose name starts with this prefix are considered
                evictable. The fs tier writes blocks to
                ``<base_path>_r<rank>/...``, so this confines a tier's byte
                budget to its own cache when several models share one root.
            max_bytes: Byte budget for the matched directories. ``None``
                disables the budget.
            min_free_bytes: Free-space floor for the filesystem holding
                ``root_dir``. ``None`` disables that check.
            eviction_policy: Only "fifo" is supported.
            min_file_age_seconds: Blocks younger than this are never evicted.
            interval_seconds: Background wake-up period.
        """
        if name_prefix is not None and not name_prefix:
            raise ValueError("name_prefix must be non-empty when set.")
        if eviction_policy not in SUPPORTED_POLICIES:
            raise ValueError(
                f"Unsupported cache eviction policy {eviction_policy!r} for the "
                f"fs secondary tier. Supported policies: {list(SUPPORTED_POLICIES)}."
            )
        if max_bytes is not None and max_bytes <= 0:
            raise ValueError("max_bytes must be greater than 0 when set.")
        if min_free_bytes is not None and min_free_bytes <= 0:
            raise ValueError("min_free_bytes must be greater than 0 when set.")
        if min_file_age_seconds < 0:
            raise ValueError("min_file_age_seconds must not be negative.")
        if interval_seconds <= 0:
            raise ValueError("interval_seconds must be greater than 0.")

        self.root_dir = root_dir
        self.name_prefix = name_prefix
        self.eviction_policy = eviction_policy
        self.max_bytes = max_bytes
        self.min_free_bytes = min_free_bytes
        self.min_file_age_seconds = min_file_age_seconds
        self.interval_seconds = interval_seconds

        # Set by the owner after a store; consumed by the background thread.
        self._dirty = threading.Event()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        # Guards against overlapping passes if evict_now() is also called by
        # an operator/test while the background thread is running.
        self._lock = threading.Lock()

        self.evicted_blocks_total = 0
        self.evicted_bytes_total = 0
        self._last_stall_warning = 0.0

    @property
    def enabled(self) -> bool:
        """Eviction only runs when a limit was configured."""
        return self.max_bytes is not None or self.min_free_bytes is not None

    def start(self) -> None:
        if not self.enabled or self._thread is not None:
            return
        self._thread = threading.Thread(
            target=self._run,
            name="vllm_kv_fs_fifo_evictor",
            daemon=True,
        )
        self._thread.start()

    def close(self) -> None:
        self._stop.set()
        self._dirty.set()  # unblock the wait() promptly
        thread = self._thread
        if thread is not None:
            thread.join(timeout=10.0)
            self._thread = None

    def notify_stored(self) -> None:
        """Signal that blocks were written, so the next pass should scan."""
        if self.enabled:
            self._dirty.set()

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _run(self) -> None:
        while True:
            self._stop.wait(self.interval_seconds)
            if self._stop.is_set():
                return
            if not self._dirty.is_set():
                # Idle tick: nothing was stored, nothing to do.
                continue
            self._dirty.clear()
            try:
                stats = self.evict_now()
            except Exception:
                logger.exception(
                    "FIFO eviction pass failed for cache directory %s", self.root_dir
                )
                continue
            # A pass can stop short of the limit (e.g. every remaining block is
            # younger than min_file_age_seconds). Keep retrying on later ticks,
            # but never busy-loop.
            if self._over_limit(stats.remaining_bytes, stats.free_bytes):
                self._dirty.set()

    def _over_limit(self, used_bytes: int, free_bytes: int | None) -> bool:
        if self.max_bytes is not None and used_bytes > self.max_bytes:
            return True
        if (
            self.min_free_bytes is not None
            and free_bytes is not None
            and free_bytes < self.min_free_bytes
        ):
            return True
        return False

    def _free_bytes(self) -> int | None:
        """Bytes available to this (unprivileged) user on the cache filesystem."""
        try:
            st = os.statvfs(self.root_dir)
        except OSError:
            return None
        return st.f_bavail * st.f_frsize

    def _cache_dirs(self) -> list[str]:
        """Directories that hold this tier's evictable blocks.

        The fs tier writes to ``<base_path>_r<rank>/...``, so with a
        ``name_prefix`` the tier's own cache is the set of sibling
        directories sharing that prefix. Resolved per pass so a rank that
        appears later is picked up.
        """
        if self.name_prefix is None:
            return [self.root_dir]
        try:
            entries = list(os.scandir(self.root_dir))
        except OSError:
            return []
        return [
            entry.path
            for entry in entries
            if entry.is_dir() and entry.name.startswith(self.name_prefix)
        ]

    def _collect(self) -> tuple[list[tuple[float, int, str]], int]:
        """Return ([(mtime, size, path)], total_bytes) for evictable block files."""
        entries: list[tuple[float, int, str]] = []
        total = 0
        for cache_dir in self._cache_dirs():
            for dirpath, _dirnames, filenames in os.walk(cache_dir):
                for name in filenames:
                    if not name.endswith(_BLOCK_SUFFIX):
                        continue
                    path = os.path.join(dirpath, name)
                    try:
                        st = os.stat(path)
                    except OSError:
                        # Raced with another deleter (or another instance).
                        continue
                    entries.append((st.st_mtime, st.st_size, path))
                    total += st.st_size
        return entries, total

    def evict_now(self) -> EvictionStats:
        """Run one FIFO eviction pass and return what happened.

        Deletes oldest-written block files until both the byte budget and the
        free-space floor are satisfied, or until no evictable file is left.
        """
        with self._lock:
            entries, total = self._collect()
            free_bytes = self._free_bytes()
            evicted_blocks = 0
            evicted_bytes = 0
            remaining = total

            if not self.enabled or not self._over_limit(total, free_bytes):
                return EvictionStats(
                    scanned_blocks=len(entries),
                    scanned_bytes=total,
                    evicted_blocks=0,
                    evicted_bytes=0,
                    remaining_bytes=remaining,
                    free_bytes=free_bytes if free_bytes is not None else -1,
                )

            # FIFO: oldest mtime first. O(N log N) once per pass, off the
            # scheduler and off the transfer thread pool.
            entries.sort(key=lambda entry: entry[0])
            eldest_allowed = time.time() - self.min_file_age_seconds

            evicted_any = False
            for mtime, size, path in entries:
                if not self._over_limit(remaining, free_bytes):
                    break
                if mtime > eldest_allowed:
                    # Everything left was just written; stop rather than evict
                    # a block that may be mid-promotion.
                    break
                try:
                    os.remove(path)
                except FileNotFoundError:
                    pass  # already gone; still account for it
                except OSError as exc:
                    logger.warning("Failed to evict %s: %s", path, exc)
                    continue
                remaining -= size
                evicted_blocks += 1
                evicted_bytes += size
                evicted_any = True
                if free_bytes is not None:
                    # Deletions free space, so advance the estimate instead of
                    # calling statvfs per file.
                    free_bytes += size

            self.evicted_blocks_total += evicted_blocks
            self.evicted_bytes_total += evicted_bytes

            if evicted_any:
                logger.info(
                    "FIFO eviction on %s: removed %d blocks (%.2f MiB); "
                    "cache usage %.2f -> %.2f GiB",
                    self.root_dir,
                    evicted_blocks,
                    evicted_bytes / (1024 * 1024),
                    total / float(1 << 30),
                    remaining / float(1 << 30),
                )

            still_over = self._over_limit(remaining, free_bytes)
            if still_over and evicted_blocks == 0:
                now = time.monotonic()
                if now - self._last_stall_warning >= _STALL_WARNING_INTERVAL_SECONDS:
                    self._last_stall_warning = now
                    logger.warning(
                        "FIFO eviction on %s cannot reach its limit: %d blocks "
                        "(%.2f GiB) remain but are younger than "
                        "min_file_age_seconds=%.1f. Consider a larger max_bytes or "
                        "a smaller min_file_age_seconds.",
                        self.root_dir,
                        len(entries),
                        remaining / float(1 << 30),
                        self.min_file_age_seconds,
                    )

            return EvictionStats(
                scanned_blocks=len(entries),
                scanned_bytes=total,
                evicted_blocks=evicted_blocks,
                evicted_bytes=evicted_bytes,
                remaining_bytes=remaining,
                free_bytes=free_bytes if free_bytes is not None else -1,
            )
