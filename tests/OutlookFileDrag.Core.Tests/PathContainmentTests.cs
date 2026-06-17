using System;
using System.IO;
using OutlookFileDrag;
using Xunit;

namespace OutlookFileDrag.Core.Tests
{
    // Pins the ship-blocking invariant at the SAME method the production write path uses:
    // OutlookDataObject.ExtractFiles delegates to FileUtility.GetContainedUniqueTarget, which is
    // exercised directly here. A descriptor-supplied name (untrusted) must never resolve a file
    // target outside the temp root, regardless of traversal, absolute paths, or Windows-style
    // separators on a non-Windows host.
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
        public void ContainedTarget_StaysUnderRoot(string descriptorName)
        {
            string root = NewTempRoot();
            try
            {
                string target = FileUtility.GetContainedUniqueTarget(root, descriptorName, replaceSpecialChars: false);
                string full = Path.GetFullPath(target);
                Assert.StartsWith(FullRootWithSep(root), full, StringComparison.OrdinalIgnoreCase);
            }
            finally { Directory.Delete(root, true); }
        }

        [Theory]
        [InlineData("..\\..\\evil.exe", "evil.exe")]
        [InlineData("../../evil.exe", "evil.exe")]
        [InlineData("subdir\\name.txt", "name.txt")]
        [InlineData("subdir/name.txt", "name.txt")]
        public void ContainedTarget_FlattensWindowsAndUnixSeparatorsToLeaf(string descriptorName, string expectedLeaf)
        {
            string root = NewTempRoot();
            try
            {
                string target = FileUtility.GetContainedUniqueTarget(root, descriptorName, replaceSpecialChars: false);
                Assert.Equal(expectedLeaf, Path.GetFileName(target));
            }
            finally { Directory.Delete(root, true); }
        }

        [Fact]
        public void ContainedTarget_ColonSubjectName_DoesNotThrow_AndStaysContained()
        {
            string root = NewTempRoot();
            try
            {
                // ':' is why production avoids Path.GetFileName; with normalization on it must still
                // produce a contained, non-throwing target.
                string target = FileUtility.GetContainedUniqueTarget(root, "RE: plan:v2.pdf", replaceSpecialChars: true);
                string full = Path.GetFullPath(target);
                Assert.StartsWith(FullRootWithSep(root), full, StringComparison.OrdinalIgnoreCase);
            }
            finally { Directory.Delete(root, true); }
        }
    }
}
