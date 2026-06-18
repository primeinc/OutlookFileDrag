using System;
using System.IO;
using OutlookFileDrag;
using Xunit;

namespace OutlookFileDrag.Core.Tests
{
    // Unit-level coverage for the leaf-name and unique-filename helpers behind GetContainedUniqueTarget.
    public class FileUtilityTests
    {
        // ---- GetSafeLeafName -------------------------------------------------------------------

        [Theory]
        [InlineData("report.pdf", "report.pdf")]
        [InlineData("a/b/c.txt", "c.txt")]
        [InlineData("a\\b\\c.txt", "c.txt")]
        [InlineData("/abs/path/file", "file")]
        public void GetSafeLeafName_TakesFinalSegment_NoNormalization(string input, string expected)
        {
            // Act
            string leaf = FileUtility.GetSafeLeafName(input, replaceSpecialChars: false);

            // Assert
            Assert.Equal(expected, leaf);
        }

        [Theory]
        [InlineData("")]
        [InlineData(null)]
        [InlineData(".")]
        [InlineData("..")]
        [InlineData("a/b/")]   // trailing separator -> empty leaf
        public void GetSafeLeafName_EmptyOrDotComponents_FallBackToDefault(string input)
        {
            // Act
            string leaf = FileUtility.GetSafeLeafName(input, replaceSpecialChars: false);

            // Assert
            Assert.Equal("OutlookFileDrag", leaf);
        }

        [Fact]
        public void GetSafeLeafName_Normalization_CollapsesSpecialChars_KeepsExtension()
        {
            // Act
            string leaf = FileUtility.GetSafeLeafName("RE: weekly report!.pdf", replaceSpecialChars: true);

            // Assert -- runs of non-letter/digit collapse to '_'; the extension is preserved.
            Assert.Equal("RE_weekly_report.pdf", leaf);
        }

        [Fact]
        public void GetSafeLeafName_Normalization_AllSpecial_FallsBackToDefaultName()
        {
            // Act
            string leaf = FileUtility.GetSafeLeafName("***", replaceSpecialChars: true);

            // Assert
            Assert.Equal("OutlookFileDrag", leaf);
        }

        // ---- GetUniqueFilename -----------------------------------------------------------------

        [Fact]
        public void GetUniqueFilename_NonExisting_ReturnsInputUnchanged()
        {
            // Arrange
            string dir = NewDir();
            try
            {
                string path = Path.Combine(dir, "a.txt");

                // Act
                string result = FileUtility.GetUniqueFilename(path);

                // Assert
                Assert.Equal(path, result);
            }
            finally { Directory.Delete(dir, true); }
        }

        [Fact]
        public void GetUniqueFilename_Existing_AppendsCounterSuffix_InSameDirectory()
        {
            // Arrange
            string dir = NewDir();
            try
            {
                string path = Path.Combine(dir, "a.txt");
                File.WriteAllText(path, "x");

                // Act
                string result = FileUtility.GetUniqueFilename(path);

                // Assert
                Assert.NotEqual(path, result);
                Assert.Equal(dir, Path.GetDirectoryName(result));
                Assert.Equal(".txt", Path.GetExtension(result));
                Assert.False(File.Exists(result));
            }
            finally { Directory.Delete(dir, true); }
        }

        [Fact]
        public void GetUniqueFilename_OverlongName_ShortensNameComponent_NotDirectory()
        {
            // Arrange
            string dir = NewDir();
            try
            {
                string path = Path.Combine(dir, new string('a', 500) + ".bin");

                // Act
                string result = FileUtility.GetUniqueFilename(path);

                // Assert -- directory preserved, total within MAX_PATH, extension preserved.
                Assert.Equal(dir, Path.GetDirectoryName(result));
                Assert.True(result.Length <= NativeMethods.MAX_PATH);
                Assert.EndsWith(".bin", result);
            }
            finally { Directory.Delete(dir, true); }
        }

        private static string NewDir()
        {
            string dir = Path.Combine(Path.GetTempPath(), "OFD_FU", Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            return dir;
        }
    }
}
