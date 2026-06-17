# Audit reference: `ole32!DoDragDrop` import redirect

This document is the audit trail for the low-level native interop in
`OutlookFileDrag/DragDropHook.cs` and the related P/Invoke declarations in
`OutlookFileDrag/NativeMethods.cs`. Every magic constant, structure offset,
and Win32/COM contract the add-in relies on is traced here to its
authoritative Microsoft Learn source, so the mechanism can be reviewed
without trusting undocumented "magic numbers".

## What the add-in does, in one paragraph

When Outlook starts a drag, the add-in needs `ole32!DoDragDrop` to run its
own handler first (to add a `CF_HDROP` format so virtual attachments can be
dropped as files). It does this by **redirecting the import-address-table
(IAT) slot** for `DoDragDrop` in the modules that import it — it overwrites a
function pointer in the *caller's* import table, never the bytes of `ole32`
itself. This is why it cannot collide with Office's own `DoDragDrop`
interception (`AppVIsvSubsystems64.dll`), which was the root cause of the
Office 16.0.20131 fastfail (see PR description).

## Design rule: prefer the official API over hand-rolled parsing

Where Windows ships a documented API for a step, the add-in uses it instead
of re-deriving structure layout by hand:

| Step | Official path used | Not hand-rolled |
| --- | --- | --- |
| Locate the import descriptor table in a loaded module | `ImageDirectoryEntryToData(base, MappedAsImage=TRUE, IMAGE_DIRECTORY_ENTRY_IMPORT, &size)` | DOS header `MZ` / `e_lfanew` / PE signature / optional-header magic / data-directory array math |
| Locate the delay-import descriptor table | `ImageDirectoryEntryToData(..., IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT, &size)` | same |
| Decide PE32 vs PE32+ (thunk width, ordinal flag) | `IntPtr.Size` (in-process modules always match host bitness) | reading the optional-header `Magic` |
| Make an IAT page writable | `VirtualProtect` | — |
| Allocate the `CF_HDROP` medium so the drop target's `GlobalFree` matches | `GlobalAlloc(GMEM_FIXED, …)` | — |

The only logic that remains hand-written is **walking the descriptor/thunk
arrays to the specific imported symbol and writing the slot** — Windows
exposes no higher-level API for "redirect this import", so this is
unavoidable. It is bounded on every read (see below).

`ImageDirectoryEntryToData` is documented as single-threaded. The add-in
serializes its DbgHelp calls under a private lock (`DragDropHook.DbgHelpLock`)
to honor that contract for the calls it controls; the sole caller
(`DragDropHook.Start`) is itself a one-time startup scan on a single thread.
(No in-process lock can guard a *foreign* component that calls DbgHelp on
another thread — that residual risk is inherent to any DbgHelp use.)

- ImageDirectoryEntryToData — https://learn.microsoft.com/windows/win32/api/dbghelp/nf-dbghelp-imagedirectoryentrytodata
- DbgHelp image-access functions — https://learn.microsoft.com/windows/win32/debug/dbghelp-functions#image-access
- `IntPtr.Size` — https://learn.microsoft.com/dotnet/api/system.intptr.size

## Constant / offset trace

All PE structure facts below are from the Microsoft **PE Format**
specification unless noted.
Source: https://learn.microsoft.com/windows/win32/debug/pe-format

### `ImageDirectoryEntryToData` directory indices (`NativeMethods.cs`)

| Symbol | Value | Meaning | Source |
| --- | --- | --- | --- |
| `IMAGE_DIRECTORY_ENTRY_IMPORT` | `1` | Import directory | [ImageDirectoryEntryToData › DirectoryEntry](https://learn.microsoft.com/windows/win32/api/dbghelp/nf-dbghelp-imagedirectoryentrytodata#parameters) |
| `IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT` | `13` | Delay import table | same |

### Import directory entry — `IMAGE_IMPORT_DESCRIPTOR` (20 bytes)

Used by `PatchTable` when `delay == false`.
Source: PE Format § The .idata Section › Import Directory Table.

| Field offset | Code (`nameOff`/`intOff`/`iatOff`) | Field |
| --- | --- | --- |
| `0` | `intOff = 0` | Import Lookup Table RVA (a.k.a. OriginalFirstThunk / "Characteristics") |
| `12` | `nameOff = 12` | Name RVA (ASCII DLL name) |
| `16` | `iatOff = 16` | Import Address Table RVA (the slots to patch) |

Descriptor size `20`, and the all-zero terminator descriptor, are from the
same section. When `OriginalFirstThunk` (the lookup table) is `0`, the names
are read from the IAT itself — also per spec ("identical … until the image is
bound").

### Delay-load directory — `ImgDelayDescr` (32 bytes)

Used by `PatchTable` when `delay == true`.
Source: PE Format § Delay-Load Import Tables › The Delay-Load Directory Table.

| Field offset | Code | Field |
| --- | --- | --- |
| `4` | `nameOff = 4` | Name RVA (DLL name) |
| `12` | `iatOff = 12` | Delay Import Address Table RVA |
| `16` | `intOff = 16` | Delay Import Name Table RVA |

Descriptor size `32` (eight 4-byte fields, offsets `0…28`), and the
null-DLL-name terminator, are from the same table. The add-in assumes the
descriptor fields are RVAs (`dlattrRva`), which is what every current linker
emits.
Reference: https://learn.microsoft.com/cpp/build/reference/understanding-the-helper-function

### Import Lookup Table / thunk entry

Source: PE Format § Import Lookup Table.

| Code | Value | Meaning |
| --- | --- | --- |
| `thunkSize` | `8` (PE32+) / `4` (PE32) | Lookup/IAT entries are 64-bit for PE32+, 32-bit for PE32 |
| `ordinalFlag` | `0x8000000000000000` (PE32+) / `0x80000000` (PE32) | Ordinal/Name flag — bit 63/31; if set, import is by ordinal (no name) |
| `entry & 0x7FFFFFFF` | — | 31-bit RVA of the `IMAGE_IMPORT_BY_NAME` (hint/name) entry |

### Hint/Name table — `IMAGE_IMPORT_BY_NAME`

Source: PE Format § Hint/Name Table.

| Code | Offset | Field |
| --- | --- | --- |
| `+ 0` | `0` | Hint (2 bytes) |
| `b + ibnRva + 2` | `2` | Name — null-terminated, **case-sensitive** ASCII |

The `+ 2` in `StringEquals(b + ibnRva + 2, "DoDragDrop", …)` is exactly the
2-byte Hint skip. The DLL-name comparison (`"ole32.dll"`) is case-insensitive
on purpose; the symbol-name comparison matches the spec's case sensitivity.

## Win32 / COM API contracts

### `ImageDirectoryEntryToData` (dbghelp.dll)

- Returns a pointer to the directory data, or `NULL` on failure
  (`GetLastError`). With `MappedAsImage = TRUE` the returned pointer is a live
  VA inside the loaded module and `Size` is the directory's byte length — the
  add-in iterates descriptors only within `[ptr, ptr + size)`, and as
  defense-in-depth re-confirms that extent lies within the module's mapped
  image (`[base, base + ModuleMemorySize)`) before walking it.
- Single-threaded (see design rule above).
- https://learn.microsoft.com/windows/win32/api/dbghelp/nf-dbghelp-imagedirectoryentrytodata

### `VirtualProtect` (kernel32.dll) — `WriteSlot`

- Changes page protection; returns non-zero on success, zero on failure
  (`GetLastError`). The add-in flips the slot's page to `PAGE_READWRITE`
  (`0x04`), writes the pointer, then restores the previous protection.
- https://learn.microsoft.com/windows/win32/api/memoryapi/nf-memoryapi-virtualprotect
- `PAGE_READWRITE` — https://learn.microsoft.com/windows/win32/memory/memory-protection-constants

### `GlobalAlloc` / `GMEM_FIXED` (kernel32.dll) — `DataObjectHelper.SetDropFiles`

- `GMEM_FIXED` (`0x0000`) returns a usable pointer (not a movable handle);
  the matching free is `GlobalFree`. The `CF_HDROP` medium is handed to the
  drop target with `pUnkForRelease == null`, so the target releases it via
  `ReleaseStgMedium`, which calls `GlobalFree` — hence the allocator family
  must be `Global*`.
- https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-globalalloc
- `GlobalFree` — https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-globalfree
- `ReleaseStgMedium` frees `tymed`/`HGLOBAL` media — https://learn.microsoft.com/windows/win32/api/ole2/nf-ole2-releasestgmedium

### `DoDragDrop` (ole2.h / ole32.dll) — the redirected function

- `HRESULT DoDragDrop(LPDATAOBJECT pDataObj, LPDROPSOURCE pDropSource, DWORD dwOKEffects, LPDWORD pdwEffect)`.
  The add-in's `DragDropDelegate` and `DoDragDropHook` match this signature
  exactly, return the original `HRESULT`, and forward `pdwEffect`.
- Returns `S_OK` / `DRAGDROP_S_DROP` on success, `DRAGDROP_S_CANCEL` when
  cancelled (returned by `DoDragDropHook` on error). `pdwEffect` is set only
  if the operation is not cancelled.
- https://learn.microsoft.com/windows/win32/api/ole2/nf-ole2-dodragdrop
- `DROPEFFECT` constants (`DROPEFFECT_NONE/COPY/MOVE`) — https://learn.microsoft.com/windows/win32/com/dropeffect-constants
- The `DROPEFFECT_MOVE → DROPEFFECT_COPY` override on a successful file drop
  prevents the source item being deleted; the move/copy semantics are
  described in https://learn.microsoft.com/windows/win32/shell/datascenarios

## Audit risk note: endpoint exploit-protection conflict

For a regulated/fintech endpoint deployment this is the most important item to
review, because it is a **deliberate, documented exception** to a platform
security control, not a bug:

> Windows **Exploit Protection → Import Address Filtering (IAF)** mitigates
> exactly the technique this add-in uses: it watches for IAT modification and
> for calls to `VirtualProtect`/`VirtualAlloc` and terminates the process when
> validation fails. Microsoft explicitly notes that *"legitimate applications
> that perform API interception might be detected by this mitigation and cause
> some applications to crash. Examples include security software and
> application compatibility shims."*
> — https://learn.microsoft.com/defender-endpoint/exploit-protection-reference#import-address-filtering-iaf

Implications for deployment review:

1. If IAF (or a comparable EDR IAT-tamper rule) is enabled for `OUTLOOK.EXE`,
   the add-in's redirect will be flagged or will crash Outlook. IAF supports an
   **Audit Only** mode to measure impact before enforcing.
2. The add-in ships a **kill-switch** so IT can disable interception
   fleet-wide via policy without uninstalling:
   `HKLM`/`HKCU\Software\OutlookFileDrag\EnableHook` (DWORD), with the
   registry value taking precedence over `EnableHook` in `app.config`
   (`ThisAddIn.HookEnabled`). This is the recommended control when an endpoint
   policy forbids IAT modification.
3. The redirect is fully reversed on teardown: original slot pointers are
   restored in `Stop()` (called from `Dispose` and from the `ProcessExit`
   handler), so no dangling redirect is left if the add-in is unloaded.

## Verification tooling

`tools/Find-DoDragDropImport.ps1` re-checks which loaded modules import
`ole32!DoDragDrop` after a future Office update, so import coverage can be
re-confirmed without a debugger. The production redirect logs the number of
slots it redirected (`Redirected N ole32!DoDragDrop import slot(s)`) for the
same audit purpose.
