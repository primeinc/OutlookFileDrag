using System;
using OutlookFileDrag;
using Xunit;

namespace OutlookFileDrag.Core.Tests
{
    // Boundary coverage for the untrusted cItems bound check.
    public class FileGroupDescriptorTests
    {
        private const int Desc = 592;   // representative FILEDESCRIPTORW size

        [Fact]
        public void ExactFit_Ok()
        {
            FileGroupDescriptor.ValidateCount(FileGroupDescriptor.CItemsFieldSize + 2 * Desc, Desc, 2);
        }

        [Fact]
        public void ZeroItems_Ok()
        {
            FileGroupDescriptor.ValidateCount(FileGroupDescriptor.CItemsFieldSize, Desc, 0);
        }

        [Fact]
        public void OneByteShort_Throws()
        {
            Assert.Throws<InvalidOperationException>(() =>
                FileGroupDescriptor.ValidateCount(FileGroupDescriptor.CItemsFieldSize + 2 * Desc - 1, Desc, 2));
        }

        [Fact]
        public void BufferTooSmallForCountField_Throws()
        {
            Assert.Throws<InvalidOperationException>(() =>
                FileGroupDescriptor.ValidateCount(3, Desc, 0));
        }

        [Fact]
        public void HugeCount_Throws_WithoutOverflow()
        {
            Assert.Throws<InvalidOperationException>(() =>
                FileGroupDescriptor.ValidateCount(1000, Desc, uint.MaxValue));
        }

        [Fact]
        public void NonPositiveDescriptorSize_Throws()
        {
            Assert.Throws<ArgumentOutOfRangeException>(() =>
                FileGroupDescriptor.ValidateCount(1000, 0, 1));
        }
    }
}
