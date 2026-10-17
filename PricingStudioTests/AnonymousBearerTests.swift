import XCTest
@testable import PricingStudio

/// An operator with holder bearer on answers 401 to a request with no
/// `Authorization` header, and a 401 sends the SDK's authorizer into an
/// interactive login. Studio proves itself in the arguments, so every request
/// carries `Bearer anonymous` — unless the authorizer set a real token.
final class AnonymousBearerTests: XCTestCase {

    private let endpoint = URL(string: "https://example-mcp.fastmcp.app/mcp")!

    func testARequestWithoutATokenCarriesTheAnonymousBearer() {
        let request = MCPService.withAnonymousBearer(URLRequest(url: endpoint))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer anonymous")
    }

    func testATokenTheAuthorizerSetIsLeftAlone() {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer dpyc_ha_abc", forHTTPHeaderField: "Authorization")
        let modified = MCPService.withAnonymousBearer(request)
        XCTAssertEqual(modified.value(forHTTPHeaderField: "Authorization"), "Bearer dpyc_ha_abc")
    }
}
