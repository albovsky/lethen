public class FixtureClass235 {
    // Reported: its SPI group is listed in --no-retain-spi, so it is not retained public API.
    @_spi(Internal) public func listedSPIFunc(unused: Int) {}

    // Retained: its SPI group is not listed.
    @_spi(Other) public func unlistedSPIFunc(unused: Int) {}

    public func callSPI() {
        listedSPIFunc(unused: 0)
    }
}
