using System.Runtime.InteropServices;
using OutlookFileDrag;
using Xunit;

namespace OutlookFileDrag.Core.Tests
{
    // The CF_HDROP medium and the FILEGROUPDESCRIPTOR walk depend on these marshaled layouts; pin them
    // so a packing/runtime change cannot silently corrupt the native interop.
    public class NativeMethodsLayoutTests
    {
        [Fact]
        public void Dropfiles_MarshaledSize_Is20Bytes()
        {
            // Arrange / Act -- DROPFILES = DWORD pFiles + POINT(8) + BOOL fNC + BOOL fWide = 20 bytes.
            // https://learn.microsoft.com/windows/win32/api/shlobj_core/ns-shlobj_core-dropfiles
            int size = Marshal.SizeOf(typeof(NativeMethods.DROPFILES));

            // Assert
            Assert.Equal(20, size);
        }

        [Fact]
        public void FileDescriptor_UnicodeIs260BytesWiderThanAnsi()
        {
            // Arrange / Act -- cFileName is TCHAR[260]; Unicode (520 bytes) - ANSI (260 bytes) = 260.
            int ansi = Marshal.SizeOf(typeof(NativeMethods.FILEDESCRIPTORA));
            int unicode = Marshal.SizeOf(typeof(NativeMethods.FILEDESCRIPTORW));

            // Assert
            Assert.True(ansi > 0);
            Assert.True(unicode > 0);
            Assert.Equal(260, unicode - ansi);
        }
    }
}
