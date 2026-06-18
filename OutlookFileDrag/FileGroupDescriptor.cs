using System;

namespace OutlookFileDrag
{
    // Pure, platform-independent validation for the FILEGROUPDESCRIPTOR(A/W) header read from an
    // untrusted data object. The descriptor's cItems count is attacker-influenced; the reader must
    // confirm the medium actually holds that many fixed-size FILEDESCRIPTOR records before walking
    // them. Without this, an out-of-bounds Marshal.PtrToStructure read can cross an unmapped page
    // and raise an AccessViolationException -- a CorruptedStateException the drag handler's
    // catch(Exception) cannot catch -- fastfailing OUTLOOK.EXE, the crash class this add-in exists
    // to prevent. Kept free of System.Windows.Forms / COM so it can be unit-tested off-Windows.
    static class FileGroupDescriptor
    {
        // The leading FILEGROUPDESCRIPTOR.cItems field (a UINT) precedes the descriptor array.
        public const int CItemsFieldSize = sizeof(uint);

        // Throws if the buffer cannot even hold the leading cItems field. MUST be called BEFORE the
        // FILEGROUPDESCRIPTOR header is marshaled out of the buffer: Marshal.PtrToStructure reads
        // CItemsFieldSize bytes to populate cItems, so a shorter buffer would over-read the heap
        // allocation the medium was copied into. Split out from ValidateCount (which can only run
        // once cItems is known) so the reader can fence that over-read off ahead of marshaling.
        public static void ValidateHeaderPresent(int bufferLength)
        {
            if (bufferLength < CItemsFieldSize)
                throw new InvalidOperationException(
                    string.Format("FileGroupDescriptor buffer too small ({0} bytes) to contain the item count", bufferLength));
        }

        // Throws if a buffer of bufferLength bytes cannot contain cItems descriptors of
        // descriptorSize bytes each (after the leading cItems field). Overflow-safe: the capacity
        // is computed by division in 64-bit, never by multiplying cItems * descriptorSize.
        public static void ValidateCount(int bufferLength, int descriptorSize, uint cItems)
        {
            ValidateHeaderPresent(bufferLength);
            if (descriptorSize <= 0)
                throw new ArgumentOutOfRangeException("descriptorSize", descriptorSize, "Descriptor size must be positive");

            long capacity = (long)(bufferLength - CItemsFieldSize) / descriptorSize;
            if (cItems > capacity)
                throw new InvalidOperationException(
                    string.Format("FileGroupDescriptor claims {0} files but the {1}-byte medium holds at most {2}", cItems, bufferLength, capacity));
        }
    }
}
