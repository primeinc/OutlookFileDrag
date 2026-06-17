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
            string leaf = GetSafeLeafName(descriptorName, replaceSpecialChars);
            string candidate = Path.Combine(tempRoot, leaf);

            // Defense in depth: "../" is normalized by GetFullPath and Path.Combine does not contain,
            // so verify the resolved path is rooted at tempRoot before any file is created. A leaf of
            // "." or ".." (which carries no separator) is caught here.
            string rootFull = Path.GetFullPath(tempRoot);
            if (rootFull.Length == 0 || rootFull[rootFull.Length - 1] != Path.DirectorySeparatorChar)
                rootFull += Path.DirectorySeparatorChar;
            string candidateFull = Path.GetFullPath(candidate);
            if (!candidateFull.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException(
                    string.Format("Refusing to extract '{0}': resolved path '{1}' is outside temp folder '{2}'",
                        descriptorName, candidateFull, rootFull));

            return GetUniqueFilename(candidateFull);
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
        internal static string GetUniqueFilename(string filename)
        {
            string filenameNoExt;
            string ext;

            //If filename is too long, truncate filename
            if (filename.Length >= NativeMethods.MAX_PATH)
            {
                ext = Path.GetExtension(filename);
                filename = filename.Substring(0, NativeMethods.MAX_PATH - ext.Length - 1) + ext;
            }

            //If file does not exist, use original filename
            if (!File.Exists(filename))
                return filename;

            //Try appending number to filename until unique filename is found
            filenameNoExt = Path.Combine(Path.GetDirectoryName(filename), Path.GetFileNameWithoutExtension(filename));
            ext = Path.GetExtension(filename);

            for (int index = 1; index < 1024; index++)
            {
                string newFilename = string.Format("{0} ({1}){2}", filenameNoExt, index, ext);

                //If new filename is too long, truncate new filename
                if (newFilename.Length > NativeMethods.MAX_PATH)
                {
                    newFilename = string.Format("{0} ({1}){2}", filenameNoExt.Substring(0, NativeMethods.MAX_PATH - ext.Length - 8), index, ext);
                }

                if (!File.Exists(newFilename))
                    return newFilename;
            }

            //If no unique filename could be found, throw exception
            throw new Exception(string.Format("Could not generate unique filename for file {0}", filename));
        }
    }
}
