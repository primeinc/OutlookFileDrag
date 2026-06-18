using System;
using System.IO;
using OutlookFileDrag;
using Xunit;

namespace OutlookFileDrag.Core.Tests
{
    // Pins the ship-blocking invariant at the SAME method the production write path uses:
    // OutlookDataObject.ExtractFiles delegates to FileUtility.GetContainedUniqueTarget. An untrusted
    // descriptor name must never resolve a target outside the temp root.
    public class PathContainmentTests
    {
        private static string NewTempRoot()
        {
            string root = Path.Combine(Path.GetTempPath(), "OFD_Tests", Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            return root;
        }

        private static string FullRootWithSep(string root)
        {
            string full = Path.GetFullPath(root);
            if (full[full.Length - 1] != Path.DirectorySeparatorChar)
                full += Path.DirectorySeparatorChar;
            return full;
        }

        [Theory]
        [InlineData("../../evil.exe")]
        [InlineData("..\\..\\evil.exe")]
        [InlineData("subdir/name.txt")]
        [InlineData("subdir\\name.txt")]
        [InlineData("/etc/passwd")]
        [InlineData("\\\\server\\share\\evil")]
        [InlineData("a/../../b/../../../escape")]
        [InlineData("..")]
        [InlineData(".")]
        [InlineData("subdir/..")]
        public void GetContainedUniqueTarget_NeverEscapesTempRoot(string descriptorName)
        {
            // Arrange
            string root = NewTempRoot();
            try
            {
                // Act
                string target = FileUtility.GetContainedUniqueTarget(root, descriptorName, replaceSpecialChars: false);

                // Assert
                Assert.StartsWith(FullRootWithSep(root), Path.GetFullPath(target), StringComparison.OrdinalIgnoreCase);
            }
            finally { Directory.Delete(root, true); }
        }

        [Theory]
        [InlineData("..\\..\\evil.exe", "evil.exe")]
        [InlineData("../../evil.exe", "evil.exe")]
        [InlineData("subdir\\name.txt", "name.txt")]
        [InlineData("subdir/name.txt", "name.txt")]
        public void GetContainedUniqueTarget_FlattensSeparatorsToLeaf(string descriptorName, string expectedLeaf)
        {
            // Arrange
            string root = NewTempRoot();
            try
            {
                // Act
                string target = FileUtility.GetContainedUniqueTarget(root, descriptorName, replaceSpecialChars: false);

                // Assert
                Assert.Equal(expectedLeaf, Path.GetFileName(target));
            }
            finally { Directory.Delete(root, true); }
        }

        [Fact]
        public void GetContainedUniqueTarget_ColonSubjectName_StaysContained_DoesNotThrow()
        {
            // Arrange -- ':' is why production avoids Path.GetFileName; normalization must still yield a
            // contained, non-throwing target.
            string root = NewTempRoot();
            try
            {
                // Act
                string target = FileUtility.GetContainedUniqueTarget(root, "RE: plan:v2.pdf", replaceSpecialChars: true);

                // Assert
                Assert.StartsWith(FullRootWithSep(root), Path.GetFullPath(target), StringComparison.OrdinalIgnoreCase);
            }
            finally { Directory.Delete(root, true); }
        }

        [Fact]
        public void GetContainedUniqueTarget_OverlongName_TruncatesNameComponent_StaysWithinMaxPath()
        {
            // Arrange -- a name far past MAX_PATH must be shortened in the NAME component only (never by
            // cutting directory segments) and must not over-long the path handed to Path.GetFullPath.
            string root = NewTempRoot();
            try
            {
                string longName = new string('a', 500) + ".bin";

                // Act
                string target = FileUtility.GetContainedUniqueTarget(root, longName, replaceSpecialChars: false);

                // Assert
                Assert.StartsWith(FullRootWithSep(root), Path.GetFullPath(target), StringComparison.OrdinalIgnoreCase);
                Assert.True(target.Length <= NativeMethods.MAX_PATH, "target exceeds MAX_PATH: " + target.Length);
                Assert.EndsWith(".bin", target);
            }
            finally { Directory.Delete(root, true); }
        }

        [Fact]
        public void GetContainedUniqueTarget_RelativeRoot_OverlongName_ResolvedPathStaysWithinMaxPath()
        {
            // Arrange -- a RELATIVE tempRoot resolves (via Path.GetFullPath) to a longer absolute
            // directory. The MAX_PATH name-budget must be charged against that ABSOLUTE length so the
            // resolved path never overruns MAX_PATH. Were the overlong name truncated against the
            // shorter relative directory instead, Path.GetFullPath would push the result past MAX_PATH
            // and throw on .NET Framework. (No directory is created -- the helper only probes
            // File.Exists -- so nothing needs cleanup.)
            string relativeRoot = "OFD_RelRoot_" + Guid.NewGuid().ToString("N");
            string longName = new string('a', 500) + ".bin";

            // Act
            string target = FileUtility.GetContainedUniqueTarget(relativeRoot, longName, replaceSpecialChars: false);

            // Assert
            string resolved = Path.GetFullPath(target);
            Assert.StartsWith(FullRootWithSep(relativeRoot), resolved, StringComparison.OrdinalIgnoreCase);
            Assert.True(resolved.Length <= NativeMethods.MAX_PATH, "resolved path exceeds MAX_PATH: " + resolved.Length);
        }

        [Fact]
        public void GetContainedUniqueTarget_NameCollision_ReturnsDistinctContainedPath()
        {
            // Arrange -- the first extraction occupies the target; the second must get a different,
            // still-contained path.
            string root = NewTempRoot();
            try
            {
                string first = FileUtility.GetContainedUniqueTarget(root, "report.pdf", replaceSpecialChars: false);
                File.WriteAllText(first, "x");

                // Act
                string second = FileUtility.GetContainedUniqueTarget(root, "report.pdf", replaceSpecialChars: false);

                // Assert
                Assert.NotEqual(first, second);
                Assert.False(File.Exists(second));
                Assert.StartsWith(FullRootWithSep(root), Path.GetFullPath(second), StringComparison.OrdinalIgnoreCase);
            }
            finally { Directory.Delete(root, true); }
        }
    }
}
