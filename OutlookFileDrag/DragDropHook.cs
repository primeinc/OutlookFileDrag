using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using log4net;

namespace OutlookFileDrag
{
    // Redirects calls to ole32!DoDragDrop by overwriting the import / delay-import address-table
    // slot in every loaded module that imports it, instead of inline-patching ole32's code.
    //
    // Why: Office 16.0.20131+ (Current Channel Preview) also intercepts ole32!DoDragDrop via
    // AppVIsvSubsystems64.dll. The previous approach (EasyHook) wrote a JMP into ole32's code; two
    // inline patches over the same prologue corrupt the heap and fastfail OUTLOOK.EXE (0xC0000409,
    // subcode 0x23) on every drag. An IAT redirect lives in the *caller's import table*, not in
    // ole32's code, so it cannot collide with Office's patch -- they occupy different memory.
    // Verified on this build: only OUTLOOK.EXE imports DoDragDrop, via a delay-load thunk.
    class DragDropHook : IDisposable
    {
        private static ILog log = LogManager.GetLogger(System.Reflection.MethodBase.GetCurrentMethod().DeclaringType);

        private readonly NativeMethods.DragDropDelegate detour;
        private readonly IntPtr detourPtr;
        private readonly List<Patch> patches = new List<Patch>();
        private bool disposed = false;
        private bool isHooked = false;

        private struct Patch { public IntPtr Slot; public IntPtr Original; }

        public DragDropHook()
        {
            // Keep the delegate referenced for the life of the hook so its native thunk stays valid.
            detour = new NativeMethods.DragDropDelegate(DoDragDropHook);
            detourPtr = Marshal.GetFunctionPointerForDelegate(detour);
        }

        public bool IsHooked
        {
            get { return isHooked; }
        }

        public void Start()
        {
            try
            {
                if (isHooked)
                    return;

                log.Info("Installing DoDragDrop import redirect");
                foreach (ProcessModule module in Process.GetCurrentProcess().Modules)
                {
                    try
                    {
                        PatchModule(module);
                    }
                    catch (Exception ex)
                    {
                        log.DebugFormat("Skipped module at {0}: {1}", module.BaseAddress, ex.Message);
                    }
                }

                if (patches.Count == 0)
                    log.Warn("No ole32!DoDragDrop import slot found -- drag interception is INACTIVE");
                else
                    log.InfoFormat("Redirected {0} ole32!DoDragDrop import slot(s)", patches.Count);

                isHooked = true;
            }
            catch (Exception ex)
            {
                log.Error("Error installing import redirect", ex);
                throw;
            }
        }

        public void Stop()
        {
            try
            {
                if (!isHooked)
                    return;

                log.Info("Removing DoDragDrop import redirect");
                foreach (Patch p in patches)
                {
                    try { WriteSlot(p.Slot, p.Original); }
                    catch (Exception ex) { log.WarnFormat("Could not restore slot {0}: {1}", p.Slot, ex.Message); }
                }
                patches.Clear();
                isHooked = false;
                log.Info("Removed import redirect");
            }
            catch (Exception ex)
            {
                log.Error("Error removing import redirect", ex);
                throw;
            }
        }

        public static int DoDragDropHook(NativeMethods.IDataObject pDataObj, IntPtr pDropSource, uint dwOKEffects, out uint pdwEffect)
        {
            try
            {
                log.Info("Drag started");
                if (!DataObjectHelper.GetDataPresent(pDataObj, "FileGroupDescriptorW") && !DataObjectHelper.GetDataPresent(pDataObj, "FileGroupDescriptor"))
                {
                    log.Info("No virtual files found -- continuing original drag");
                    return NativeMethods.DoDragDrop(pDataObj, pDropSource, dwOKEffects, out pdwEffect);
                }

                //Start new drag
                log.Info("Virtual files found -- starting new drag adding CF_HDROP format");
                log.InfoFormat("Files: {0}", string.Join(",", DataObjectHelper.GetFilenames(pDataObj)));

                OutlookDataObject newDataObj = new OutlookDataObject(pDataObj);
                int result = NativeMethods.DoDragDrop(newDataObj, pDropSource, dwOKEffects, out pdwEffect);

                //If files were dropped and drop effect was "move", then override to "copy" so original item is not deleted
                if (newDataObj.FilesDropped && pdwEffect == NativeMethods.DROPEFFECT_MOVE)
                    pdwEffect = NativeMethods.DROPEFFECT_COPY;

                //Get result
                log.InfoFormat("DoDragDrop effect: {0} result: {1}", pdwEffect, result);
                return result;
            }
            catch (Exception ex)
            {
                log.Warn("Dragging error", ex);
                pdwEffect = NativeMethods.DROPEFFECT_NONE;
                return NativeMethods.DRAGDROP_S_CANCEL;
            }
        }

        // --- Import-table patching ------------------------------------------------------------

        // Find and redirect the ole32!DoDragDrop slots in a module's import / delay-import tables.
        //
        // Locating the directory tables is delegated to the official DbgHelp helper
        // ImageDirectoryEntryToData (no hand-parsing of the DOS/PE headers, the optional-header
        // magic, or the data-directory array): the OS performs that parse and bounds the probe.
        // What remains hand-rolled -- walking the descriptor/thunk arrays to the specific imported
        // symbol, and rewriting the slot -- has no higher-level Win32 API, so every RVA is still
        // validated against the module's mapped size (module.ModuleMemorySize) before it is read.
        // An out-of-bounds read -> AccessViolationException is uncatchable and would fastfail
        // OUTLOOK.EXE, the exact crash class this add-in exists to prevent.
        private void PatchModule(ProcessModule module)
        {
            IntPtr baseAddr = module.BaseAddress;
            long b = baseAddr.ToInt64();
            long size = module.ModuleMemorySize;

            // The Windows loader never mixes 32- and 64-bit modules in one process, so every module
            // we see matches the host process bitness. That fixes the thunk width and the import-by-
            // ordinal flag without reading the PE optional-header Magic field by hand.
            //   https://learn.microsoft.com/dotnet/api/system.intptr.size
            bool plus = IntPtr.Size == 8;                      // PE32+ (x64) in a 64-bit process; else PE32
            int thunkSize = IntPtr.Size;
            long ordinalFlag = plus ? unchecked((long)0x8000000000000000) : 0x80000000L;

            // Official directory lookup. ImageDirectoryEntryToData returns a live pointer to the
            // descriptor table within the mapped image (MappedAsImage = true) and its size in bytes,
            // or NULL if the module has no such directory.
            uint impSize, delaySize;
            IntPtr impDir = NativeMethods.ImageDirectoryEntryToData(baseAddr, true, NativeMethods.IMAGE_DIRECTORY_ENTRY_IMPORT, out impSize);
            IntPtr delayDir = NativeMethods.ImageDirectoryEntryToData(baseAddr, true, NativeMethods.IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT, out delaySize);

            if (impDir != IntPtr.Zero)
                PatchTable(b, size, impDir.ToInt64(), impSize, false, thunkSize, ordinalFlag);
            if (delayDir != IntPtr.Zero)
                PatchTable(b, size, delayDir.ToInt64(), delaySize, true, thunkSize, ordinalFlag);
        }

        // dirPtr/dirSize is the descriptor table returned by ImageDirectoryEntryToData (an absolute
        // pointer into the mapped image and its byte length). The descriptors' internal fields are
        // still RVAs, so they are resolved as base (b) + RVA and bounds-checked against moduleSize.
        private void PatchTable(long b, long moduleSize, long dirPtr, long dirSize, bool delay, int thunkSize, long ordinalFlag)
        {
            if (dirPtr == 0 || dirSize == 0)
                return;

            int descSize = delay ? 32 : 20;
            int nameOff = delay ? 4 : 12;     // RVA of imported DLL name
            int intOff = delay ? 16 : 0;      // RVA of Import Name Table (names)
            int iatOff = delay ? 12 : 16;     // RVA of Import Address Table (slots to patch)

            for (long d = dirPtr; d + descSize <= dirPtr + dirSize; d += descSize)   // stay within the directory
            {
                int nameRva = Marshal.ReadInt32((IntPtr)(d + nameOff));
                int intRva = Marshal.ReadInt32((IntPtr)(d + intOff));
                int iatRva = Marshal.ReadInt32((IntPtr)(d + iatOff));

                // Terminator: import = all-zero descriptor; delay = null DLL name
                if (delay) { if (nameRva == 0) break; }
                else { if (nameRva == 0 && intRva == 0 && iatRva == 0) break; }

                if (nameRva <= 0 || nameRva >= moduleSize || !StringEquals(b + nameRva, "ole32.dll", moduleSize, b))
                    continue;

                // For normal imports OriginalFirstThunk may be 0 -> names live in FirstThunk
                long names = (intRva != 0) ? intRva : iatRva;
                if (names <= 0 || names >= moduleSize)
                    continue;

                for (int i = 0; ; i++)
                {
                    long nameSlot = names + (long)i * thunkSize;
                    if (nameSlot + thunkSize > moduleSize)     // the thunk we read must be in-bounds
                        break;

                    long entry = (thunkSize == 8)
                        ? Marshal.ReadInt64((IntPtr)(b + nameSlot))
                        : (uint)Marshal.ReadInt32((IntPtr)(b + nameSlot));
                    if (entry == 0)
                        break;
                    if ((entry & ordinalFlag) != 0)
                        continue;                              // imported by ordinal -> no name

                    long ibnRva = entry & 0x7FFFFFFF;          // RVA of IMAGE_IMPORT_BY_NAME
                    if (ibnRva + 2 >= moduleSize || !StringEquals(b + ibnRva + 2, "DoDragDrop", moduleSize, b))   // +2 skips the Hint
                        continue;

                    long slotOffset = (long)iatRva + (long)i * thunkSize;
                    if (slotOffset <= 0 || slotOffset + thunkSize > moduleSize)   // the IAT slot we patch must be in-bounds
                        break;

                    IntPtr slot = (IntPtr)(b + slotOffset);
                    PatchSlot(slot);
                }
            }
        }

        private void PatchSlot(IntPtr slot)
        {
            foreach (Patch existing in patches)
                if (existing.Slot == slot)
                    return;

            IntPtr original = Marshal.ReadIntPtr(slot);
            if (original == detourPtr)
                return;

            WriteSlot(slot, detourPtr);
            patches.Add(new Patch { Slot = slot, Original = original });
        }

        private static void WriteSlot(IntPtr slot, IntPtr value)
        {
            uint old;
            if (!NativeMethods.VirtualProtect(slot, (IntPtr)IntPtr.Size, NativeMethods.PAGE_READWRITE, out old))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                Marshal.WriteIntPtr(slot, value);
            }
            finally
            {
                uint ignore;
                NativeMethods.VirtualProtect(slot, (IntPtr)IntPtr.Size, old, out ignore);
            }
        }

        // Compares a null-terminated ASCII string at an absolute address, but only after confirming the
        // whole string + its terminator lie within the module (offset = addr - baseAddr is its RVA).
        private static bool StringEquals(long addr, string expected, long moduleSize, long baseAddr)
        {
            long offset = addr - baseAddr;
            if (offset < 0 || offset + expected.Length + 1 > moduleSize)
                return false;

            for (int i = 0; i < expected.Length; i++)
            {
                byte ch = Marshal.ReadByte((IntPtr)(addr + i));
                if (ch == 0)
                    return false;
                // case-insensitive ASCII compare
                char c = (char)ch;
                if (char.ToUpperInvariant(c) != char.ToUpperInvariant(expected[i]))
                    return false;
            }
            return Marshal.ReadByte((IntPtr)(addr + expected.Length)) == 0;
        }

        public void Dispose()
        {
            Dispose(true);
            GC.SuppressFinalize(this);
        }

        protected virtual void Dispose(bool disposing)
        {
            if (disposed)
                return;

            if (disposing)
            {
                Stop();
            }

            disposed = true;
        }
    }
}
