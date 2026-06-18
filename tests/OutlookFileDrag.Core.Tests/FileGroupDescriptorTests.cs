using System;
using System.Runtime.InteropServices;
using OutlookFileDrag;
using Xunit;

namespace OutlookFileDrag.Core.Tests
{
    // Boundary coverage for the untrusted FILEGROUPDESCRIPTOR.cItems bound check. The descriptor size
    // is derived the same way production derives it (Marshal.SizeOf), so the test cannot go stale if
    // struct packing or the runtime changes.
    public class FileGroupDescriptorTests
    {
        private static readonly int Desc = Marshal.SizeOf(typeof(NativeMethods.FILEDESCRIPTORW));
        private const int CountField = FileGroupDescriptor.CItemsFieldSize;

        [Fact]
        public void ExactFit_DoesNotThrow()
        {
            // Arrange
            int buffer = CountField + 2 * Desc;

            // Act
            Exception ex = Record.Exception(() => FileGroupDescriptor.ValidateCount(buffer, Desc, 2));

            // Assert
            Assert.Null(ex);
        }

        [Fact]
        public void ZeroItems_WithOnlyCountField_DoesNotThrow()
        {
            // Arrange
            int buffer = CountField;

            // Act
            Exception ex = Record.Exception(() => FileGroupDescriptor.ValidateCount(buffer, Desc, 0));

            // Assert
            Assert.Null(ex);
        }

        [Fact]
        public void OneByteShortOfTwoDescriptors_Throws()
        {
            // Arrange
            int buffer = CountField + 2 * Desc - 1;

            // Act
            Exception ex = Record.Exception(() => FileGroupDescriptor.ValidateCount(buffer, Desc, 2));

            // Assert
            Assert.IsType<InvalidOperationException>(ex);
        }

        [Fact]
        public void BufferTooSmallForCountField_Throws()
        {
            // Arrange
            int buffer = CountField - 1;

            // Act
            Exception ex = Record.Exception(() => FileGroupDescriptor.ValidateCount(buffer, Desc, 0));

            // Assert
            Assert.IsType<InvalidOperationException>(ex);
        }

        [Fact]
        public void HugeCount_DoesNotOverflow_Throws()
        {
            // Arrange
            int buffer = 1000;

            // Act
            Exception ex = Record.Exception(() => FileGroupDescriptor.ValidateCount(buffer, Desc, uint.MaxValue));

            // Assert
            Assert.IsType<InvalidOperationException>(ex);
        }

        [Fact]
        public void ValidateHeaderPresent_BufferTooSmallForCountField_Throws()
        {
            // Arrange -- the pre-marshal guard must reject a medium that cannot hold the cItems field,
            // before DataObjectHelper marshals the FILEGROUPDESCRIPTOR header (a 4-byte read that would
            // otherwise over-read the unmanaged buffer).
            int buffer = CountField - 1;

            // Act
            Exception ex = Record.Exception(() => FileGroupDescriptor.ValidateHeaderPresent(buffer));

            // Assert
            Assert.IsType<InvalidOperationException>(ex);
        }

        [Fact]
        public void ValidateHeaderPresent_ExactlyCountField_DoesNotThrow()
        {
            // Arrange -- a buffer holding exactly the cItems field (zero descriptors) is marshalable.
            int buffer = CountField;

            // Act
            Exception ex = Record.Exception(() => FileGroupDescriptor.ValidateHeaderPresent(buffer));

            // Assert
            Assert.Null(ex);
        }

        [Theory]
        [InlineData(0)]
        [InlineData(-1)]
        public void NonPositiveDescriptorSize_Throws(int descriptorSize)
        {
            // Act
            Exception ex = Record.Exception(() => FileGroupDescriptor.ValidateCount(1000, descriptorSize, 1));

            // Assert
            Assert.IsType<ArgumentOutOfRangeException>(ex);
        }
    }
}
