using OutlookFileDrag;
using Xunit;

namespace OutlookFileDrag.Core.Tests
{
    // Pins the "parse-or-default, floored to positive, capped to max" policy ThisAddIn relies on for
    // the cleanup timer interval and temp-file expiration.
    public class ConfigUtilTests
    {
        [Theory]
        [InlineData("60", 60)]
        [InlineData("1", 1)]
        [InlineData("90", 90)]
        public void ParsePositiveOrDefault_ValidPositive_ReturnsParsed(string value, int expected)
        {
            // Act
            int result = ConfigUtil.ParsePositiveOrDefault(value, defaultValue: 60, maxValue: 1000);

            // Assert
            Assert.Equal(expected, result);
        }

        [Theory]
        [InlineData(null)]
        [InlineData("")]
        [InlineData("abc")]
        [InlineData("12.5")]
        [InlineData("0")]
        [InlineData("-5")]
        public void ParsePositiveOrDefault_MissingMalformedOrNonPositive_ReturnsDefault(string value)
        {
            // Act
            int result = ConfigUtil.ParsePositiveOrDefault(value, defaultValue: 60, maxValue: 1000);

            // Assert
            Assert.Equal(60, result);
        }

        [Fact]
        public void ParsePositiveOrDefault_AboveMax_ClampsToMax()
        {
            // Act -- a large-but-parseable value is capped so later (minutes * 60 * 1000) can't overflow.
            int result = ConfigUtil.ParsePositiveOrDefault("2147483647", defaultValue: 60, maxValue: 1000);

            // Assert
            Assert.Equal(1000, result);
        }

        [Fact]
        public void ParsePositiveOrDefault_ExactlyMax_ReturnsMax()
        {
            // Act
            int result = ConfigUtil.ParsePositiveOrDefault("1000", defaultValue: 60, maxValue: 1000);

            // Assert
            Assert.Equal(1000, result);
        }
    }
}
