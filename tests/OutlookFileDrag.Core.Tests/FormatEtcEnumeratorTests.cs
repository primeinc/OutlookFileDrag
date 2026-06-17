using System.Runtime.InteropServices.ComTypes;
using OutlookFileDrag;
using Xunit;

namespace OutlookFileDrag.Core.Tests
{
    // IEnumFORMATETC contract is observable enumeration STATE, not just return codes, so these
    // assert state via Next() after Skip()/Clone().
    public class FormatEtcEnumeratorTests
    {
        private static FORMATETC[] Formats(int n)
        {
            var a = new FORMATETC[n];
            for (int i = 0; i < n; i++)
                a[i].cfFormat = (short)(i + 1);   // 1-based marker so position is observable
            return a;
        }

        [Fact]
        public void Skip_FullCount_ReturnsSOk_AndNextIsExhausted()
        {
            var e = new FormatEtcEnumerator(Formats(3));
            Assert.Equal(NativeMethods.S_OK, e.Skip(3));
            var buf = new FORMATETC[1];
            Assert.Equal(NativeMethods.S_FALSE, e.Next(1, buf, null));
        }

        [Fact]
        public void Skip_PastEnd_ReturnsSFalse_AndPositionsAtEnd()
        {
            var e = new FormatEtcEnumerator(Formats(3));
            Assert.Equal(NativeMethods.S_FALSE, e.Skip(4));
            var buf = new FORMATETC[1];
            Assert.Equal(NativeMethods.S_FALSE, e.Next(1, buf, null));
        }

        [Fact]
        public void Clone_AfterOneNext_BothContinueFromSamePosition()
        {
            var e = new FormatEtcEnumerator(Formats(3));
            var b1 = new FORMATETC[1];
            Assert.Equal(NativeMethods.S_OK, e.Next(1, b1, null));   // consume item #1
            Assert.Equal(1, b1[0].cfFormat);

            IEnumFORMATETC clone;
            e.Clone(out clone);

            var b2 = new FORMATETC[1];
            var b3 = new FORMATETC[1];
            Assert.Equal(NativeMethods.S_OK, e.Next(1, b2, null));      // original -> item #2
            Assert.Equal(NativeMethods.S_OK, clone.Next(1, b3, null));  // clone must also -> item #2
            Assert.Equal(2, b2[0].cfFormat);
            Assert.Equal(2, b3[0].cfFormat);
        }

        [Theory]
        [InlineData(-1)]            // a COM ULONG > int.MaxValue marshals to a negative int
        [InlineData(int.MinValue)]
        [InlineData(int.MaxValue)]
        public void Skip_OverflowingOrNegativeCount_ReturnsSFalse_WithoutCorruptingIndex(int celt)
        {
            var e = new FormatEtcEnumerator(Formats(3));
            Assert.Equal(NativeMethods.S_FALSE, e.Skip(celt));
            // Position must be at the end -- the next read must not throw / return an item.
            var buf = new FORMATETC[1];
            Assert.Equal(NativeMethods.S_FALSE, e.Next(1, buf, null));
        }
    }
}
