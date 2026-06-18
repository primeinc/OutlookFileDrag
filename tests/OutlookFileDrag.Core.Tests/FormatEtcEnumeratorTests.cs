using System.Runtime.InteropServices.ComTypes;
using OutlookFileDrag;
using Xunit;

namespace OutlookFileDrag.Core.Tests
{
    // IEnumFORMATETC's contract is observable enumeration STATE, so these assert state via Next() after
    // Skip()/Clone()/Reset(), not just return codes.
    // Contract: https://learn.microsoft.com/windows/win32/api/objidl/nf-objidl-ienumformatetc-next
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
        public void Next_RequestExactlyAvailable_ReturnsSOk_AndFillsBuffer()
        {
            // Arrange
            var e = new FormatEtcEnumerator(Formats(2));
            var buf = new FORMATETC[2];
            var fetched = new int[1];

            // Act
            int hr = e.Next(2, buf, fetched);

            // Assert
            Assert.Equal(NativeMethods.S_OK, hr);
            Assert.Equal(2, fetched[0]);
            Assert.Equal(1, buf[0].cfFormat);
            Assert.Equal(2, buf[1].cfFormat);
        }

        [Fact]
        public void Next_RequestMoreThanAvailable_ReturnsSFalse_WithPartialCount()
        {
            // Arrange
            var e = new FormatEtcEnumerator(Formats(1));
            var buf = new FORMATETC[2];
            var fetched = new int[1];

            // Act
            int hr = e.Next(2, buf, fetched);

            // Assert -- per the contract, fewer than requested -> S_FALSE and pceltFetched < celt.
            Assert.Equal(NativeMethods.S_FALSE, hr);
            Assert.Equal(1, fetched[0]);
            Assert.Equal(1, buf[0].cfFormat);
        }

        [Fact]
        public void Next_CeltOne_AllowsNullPceltFetched()
        {
            // Arrange -- the contract permits a null pceltFetched when celt == 1.
            var e = new FormatEtcEnumerator(Formats(1));
            var buf = new FORMATETC[1];

            // Act
            int hr = e.Next(1, buf, null);

            // Assert
            Assert.Equal(NativeMethods.S_OK, hr);
            Assert.Equal(1, buf[0].cfFormat);
        }

        [Fact]
        public void Reset_RestartsEnumerationFromBeginning()
        {
            // Arrange
            var e = new FormatEtcEnumerator(Formats(2));
            e.Next(1, new FORMATETC[1], null);   // consume #1

            // Act
            int hr = e.Reset();
            var afterReset = new FORMATETC[1];
            e.Next(1, afterReset, null);

            // Assert
            Assert.Equal(NativeMethods.S_OK, hr);
            Assert.Equal(1, afterReset[0].cfFormat);
        }

        [Fact]
        public void Skip_FullCount_ReturnsSOk_AndNextIsExhausted()
        {
            // Arrange
            var e = new FormatEtcEnumerator(Formats(3));

            // Act
            int hr = e.Skip(3);

            // Assert
            Assert.Equal(NativeMethods.S_OK, hr);
            Assert.Equal(NativeMethods.S_FALSE, e.Next(1, new FORMATETC[1], null));
        }

        [Fact]
        public void Skip_PastEnd_ReturnsSFalse_AndPositionsAtEnd()
        {
            // Arrange
            var e = new FormatEtcEnumerator(Formats(3));

            // Act
            int hr = e.Skip(4);

            // Assert
            Assert.Equal(NativeMethods.S_FALSE, hr);
            Assert.Equal(NativeMethods.S_FALSE, e.Next(1, new FORMATETC[1], null));
        }

        [Theory]
        [InlineData(-1)]            // a COM ULONG > int.MaxValue marshals to a negative int
        [InlineData(int.MinValue)]
        [InlineData(int.MaxValue)]
        public void Skip_OverflowingOrNegativeCount_ReturnsSFalse_WithoutCorruptingIndex(int celt)
        {
            // Arrange
            var e = new FormatEtcEnumerator(Formats(3));

            // Act
            int hr = e.Skip(celt);

            // Assert -- positioned at end; the next read must not throw / return an item.
            Assert.Equal(NativeMethods.S_FALSE, hr);
            Assert.Equal(NativeMethods.S_FALSE, e.Next(1, new FORMATETC[1], null));
        }

        [Fact]
        public void Clone_AfterOneNext_BothContinueFromSamePosition()
        {
            // Arrange
            var e = new FormatEtcEnumerator(Formats(3));
            var b1 = new FORMATETC[1];
            e.Next(1, b1, null);   // consume #1
            Assert.Equal(1, b1[0].cfFormat);

            // Act
            IEnumFORMATETC clone;
            e.Clone(out clone);
            var b2 = new FORMATETC[1];
            var b3 = new FORMATETC[1];
            int hrOrig = e.Next(1, b2, null);
            int hrClone = clone.Next(1, b3, null);

            // Assert -- clone carries the same state, so both return #2.
            Assert.Equal(NativeMethods.S_OK, hrOrig);
            Assert.Equal(NativeMethods.S_OK, hrClone);
            Assert.Equal(2, b2[0].cfFormat);
            Assert.Equal(2, b3[0].cfFormat);
        }
    }
}
