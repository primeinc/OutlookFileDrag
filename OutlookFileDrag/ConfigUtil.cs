using System;

namespace OutlookFileDrag
{
    // Pure config-value parsing shared by the add-in's startup/cleanup paths, factored out so the
    // "parse-or-default, floored to positive, capped to a safe maximum" policy can be unit-tested
    // off-Windows.
    static class ConfigUtil
    {
        // Returns an integer parsed from a config string, clamped to (0, maxValue], or defaultValue
        // when the value is missing, malformed, or non-positive. Bounds rationale:
        //   - non-positive is rejected: a non-positive CleanupTimerInterval makes the
        //     System.Threading.Timer period invalid (negative throws ArgumentOutOfRangeException since
        //     it is not Timeout.Infinite; zero fires the callback only once), and a non-positive
        //     TempFileExpiration makes DateTime.Now.AddMinutes(-value) resolve to "now"/the future,
        //     deleting temp folders still in use by an in-progress drag;
        //   - maxValue caps the result so a large-but-parseable value cannot overflow when later
        //     converted to milliseconds (minutes * 60 * 1000) or push DateTime.AddMinutes out of range.
        public static int ParsePositiveOrDefault(string value, int defaultValue, int maxValue)
        {
            int parsed;
            if (!int.TryParse(value, out parsed) || parsed <= 0)
                return defaultValue;
            return parsed > maxValue ? maxValue : parsed;
        }
    }
}
