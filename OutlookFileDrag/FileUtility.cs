using System;
using System.Configuration;
using System.IO;
using System.Text.RegularExpressions;
using log4net;

namespace OutlookFileDrag
{
    static class FileUtility
    {
        private static ILog log = LogManager.GetLogger(System.Reflection.MethodBase.GetCurrentMethod().DeclaringType);

        public static string GetTempPath()
        {
            log.Debug("Getting temp path");
            string path = Path.Combine(Path.GetTempPath(), "OutlookFileDrag", Guid.NewGuid().ToString());
            if (!System.IO.Directory.Exists(path))
                System.IO.Directory.CreateDirectory(path);
            log.DebugFormat("Temp path: {0}", path);
            return path;
        }

        public static void CleanupTempPath(int tempFileExpiration)
        {
            log.Debug("Cleaning up temp path");
            string path = Path.Combine(Path.GetTempPath(), "OutlookFileDrag");
            log.InfoFormat("Temp path: {0}", path);
            if (!System.IO.Directory.Exists(path))
            {
                log.Info("Temp path does not exist");
                return;
            }

            var dirInfo = new DirectoryInfo(path);
            foreach(DirectoryInfo subfolder in dirInfo.GetDirectories())
            {
                //If folder was created before expiration window, delete it
                if (subfolder.CreationTime < DateTime.Now.AddMinutes(-tempFileExpiration))
                    try
                    {
                        log.InfoFormat("Deleting temp folder: {0}", subfolder.FullName);
                        subfolder.Delete(true);
                    }
                    catch
                    {
                        log.WarnFormat("Could not delete temp folder: {0}", subfolder.FullName);
                    }
            }
        }

        // Production entry point used by OutlookDataObject.ExtractFiles: reads the ReplaceSpecialChars
        // policy from configuration once, then delegates to the testable, pure overload.
        public static string GetContainedUniqueTarget(string tempRoot, string descriptorName)
        {
            bool replaceSpecialChars;
            bool.TryParse(ConfigurationManager.AppSettings["ReplaceSpecialChars"], out replaceSpecialChars);
            return GetContainedUniqueTarget(tempRoot, descriptorName, replaceSpecialChars);
        }

        // Canonical security boundary: turn an untrusted descriptor name into a unique file target
        // GUARANTEED to live under tempRoot, or throw. Descriptor names can legitimately carry
        // sub-path segments (folder drags) and maliciously carry traversal ("..\") or absolute/UNC
        // paths; both are neutralized by reducing to a single leaf component, and a normalized-path
        // containment check backstops it. This is the method the production write path calls, so it
        // is also the method the path-containment tests pin.
        internal static string GetContainedUniqueTarget(string tempRoot, string descriptorName, bool replaceSpecialChars)
        {
            string rootFull = Path.GetFullPath(tempRoot);
            if (rootFull.Length == 0 || rootFull[rootFull.Length - 1] != Path.DirectorySeparatorChar)
                rootFull += Path.DirectorySeparatorChar;

            string leaf = GetSafeLeafName(descriptorName, replaceSpecialChars);

            // Build + uniquify WITHOUT normalizing the (possibly over-long) combined path first.
            // GetUniqueFilename shortens the NAME component to fit MAX_PATH using string operations, so
            // the result is short enough that the subsequent Path.GetFullPath cannot throw
            // PathTooLongException on .NET Framework (which enforces MAX_PATH=260 unless the app opts
            // into long paths). Containment is then validated on the FINAL, bounded path -- covering
            // any truncation / "(n)" uniqueness suffixing, and a "." / ".." leaf.
            string target = GetUniqueFilename(Path.Combine(tempRoot, leaf));
            if (!Path.GetFullPath(target).StartsWith(rootFull, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException(
                    string.Format("Refusing to extract '{0}': resolved path '{1}' is outside temp folder '{2}'",
                        descriptorName, target, rootFull));

            return target;
        }

        // Reduce a descriptor-supplied name to a single safe filename component. BOTH '/' and '\'
        // are treated as separators regardless of host OS (descriptor names originate on Windows),
        // and the final segment is taken -- NOT Path.GetFileName, which throws on ':' that legitimate
        // subject-derived names contain. Optionally normalizes disallowed characters.
        internal static string GetSafeLeafName(string descriptorName, bool replaceSpecialChars)
        {
            if (string.IsNullOrEmpty(descriptorName))
                return "OutlookFileDrag";

            int sep = descriptorName.LastIndexOfAny(new char[] { '\\', '/' });
            string leaf = sep >= 0 ? descriptorName.Substring(sep + 1) : descriptorName;
            if (string.IsNullOrEmpty(leaf))
                leaf = "OutlookFileDrag";

            // "." and ".." are relative path components, never filenames -- collapse so they can never
            // combine to the temp root or its parent.
            if (leaf == "." || leaf == "..")
                leaf = "OutlookFileDrag";

            if (!replaceSpecialChars)
                return leaf;

            int extIndex = leaf.LastIndexOf('.');
            string justFilenameNoExt = extIndex >= 0 ? leaf.Substring(0, extIndex) : leaf;
            string justExt = extIndex >= 0 ? leaf.Substring(extIndex) : string.Empty;

            string justFilenameNoExtSimple = Regex.Replace(justFilenameNoExt, @"[^\p{L}\p{Nd}]+", "_").Trim('_');
            if (string.IsNullOrEmpty(justFilenameNoExtSimple))
                justFilenameNoExtSimple = "OutlookFileDrag";

            //Replace invalid characters in extension as well
            foreach (char invalidChar in Path.GetInvalidFileNameChars())
                justExt = justExt.Replace(invalidChar, '_');

            string sanitized = justFilenameNoExtSimple + justExt;
            if (!string.Equals(leaf, sanitized, StringComparison.OrdinalIgnoreCase))
                log.InfoFormat("Using {0} as CF_HDROP filename instead of {1}", sanitized, leaf);
            return sanitized;
        }

        // Uniqueness + MAX_PATH truncation on an ALREADY-contained path. Does not sanitize names --
        // that is GetSafeLeafName's job, applied before the path is combined with the temp root.
        // Only the NAME component is ever shortened; the directory is preserved verbatim. (Truncating
        // an absolute path from the left could cut off the temp-folder segments and move the target
        // out of the sandbox -- so directory truncation is never done here.)
        internal static string GetUniqueFilename(string filename)
        {
            string directory = Path.GetDirectoryName(filename) ?? string.Empty;
            string nameWithoutExt = Path.GetFileNameWithoutExtension(filename);
            string ext = Path.GetExtension(filename);

            // Room left for the name component once the directory, separator and extension are fixed.
            int maxNameLength = NativeMethods.MAX_PATH - directory.Length - 1 - ext.Length;
            if (maxNameLength < 1)
                throw new PathTooLongException(string.Format("Temp directory path leaves no room for a filename within MAX_PATH: {0}", directory));

            if (nameWithoutExt.Length > maxNameLength)
                nameWithoutExt = nameWithoutExt.Substring(0, maxNameLength);

            string candidate = Path.Combine(directory, nameWithoutExt + ext);
            if (!File.Exists(candidate))
                return candidate;

            //Try appending a number to the name (shortening the name further to make room) until unique
            for (int index = 1; index < 1024; index++)
            {
                string suffix = string.Format(" ({0})", index);
                int maxNameLengthWithSuffix = maxNameLength - suffix.Length;
                if (maxNameLengthWithSuffix < 1)
                    throw new PathTooLongException(string.Format("Temp directory path leaves no room for a unique filename within MAX_PATH: {0}", directory));

                string trimmedName = nameWithoutExt.Length > maxNameLengthWithSuffix
                    ? nameWithoutExt.Substring(0, maxNameLengthWithSuffix)
                    : nameWithoutExt;

                string newFilename = Path.Combine(directory, trimmedName + suffix + ext);
                if (!File.Exists(newFilename))
                    return newFilename;
            }

            //If no unique filename could be found, throw exception
            throw new Exception(string.Format("Could not generate unique filename for file {0}", filename));
        }
    }
}
