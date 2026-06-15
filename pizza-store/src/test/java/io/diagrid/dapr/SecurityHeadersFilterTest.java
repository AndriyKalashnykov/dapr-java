package io.diagrid.dapr;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockFilterChain;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

/**
 * Unit test for {@link SecurityHeadersFilter}. Fast contract guard for the baseline HTTP security
 * headers — the same headers the e2e OWASP ZAP strict gate asserts, but verified in milliseconds
 * with no cluster/Dapr/Spring context. A regression here fails Surefire immediately instead of
 * waiting for the weekly/dispatch e2e ZAP run.
 *
 * <p>Lives in {@code io.diagrid.dapr} so it can call the filter's {@code protected
 * doFilterInternal}.
 */
class SecurityHeadersFilterTest {

  private MockHttpServletResponse invokeFilter() throws Exception {
    var filter = new SecurityHeadersFilter();
    var request = new MockHttpServletRequest("GET", "/");
    var response = new MockHttpServletResponse();
    var chain = new MockFilterChain();
    filter.doFilterInternal(request, response, chain);
    // The chain must be invoked — the filter passes the request through.
    assertNotNull(chain.getRequest(), "filter must call filterChain.doFilter");
    return response;
  }

  @Test
  void addsAllBaselineSecurityHeaders() throws Exception {
    var response = invokeFilter();
    assertEquals("nosniff", response.getHeader("X-Content-Type-Options"));
    assertEquals("DENY", response.getHeader("X-Frame-Options"));
    assertEquals("strict-origin-when-cross-origin", response.getHeader("Referrer-Policy"));
    assertEquals("same-origin", response.getHeader("Cross-Origin-Opener-Policy"));
    assertEquals("same-origin", response.getHeader("Cross-Origin-Resource-Policy"));
    assertNotNull(response.getHeader("Permissions-Policy"));
    assertTrue(
        response.getHeader("Permissions-Policy").contains("geolocation=()"),
        "Permissions-Policy should restrict unused features");
  }

  @Test
  void cspAllowlistsPinnedCdnsAndHasNoScriptUnsafeInline() throws Exception {
    var response = invokeFilter();
    var csp = response.getHeader("Content-Security-Policy");
    assertNotNull(csp, "CSP header must be present");
    assertTrue(csp.contains("default-src 'self'"), "CSP must default to self");
    // The frontend loads jQuery + STOMP from these pinned CDNs (SRI-guarded).
    assertTrue(
        csp.contains("script-src 'self' https://code.jquery.com https://cdn.jsdelivr.net"),
        "CSP script-src must allowlist exactly the pinned CDN origins");
    // The high-value protection: scripts carry NO inline allowance (the former
    // inline onload handler was moved into app.js). Guards against a regression
    // that reintroduces 'unsafe-inline' on script-src.
    assertFalse(
        csp.contains("script-src 'self' 'unsafe-inline'"),
        "CSP script-src must NOT permit 'unsafe-inline'");
    assertTrue(csp.contains("frame-ancestors 'none'"), "CSP must deny framing");
    assertTrue(csp.contains("object-src 'none'"), "CSP must block plugins");
  }

  @Test
  void coepIsIntentionallyNotSet() throws Exception {
    // Cross-Origin-Embedder-Policy is deliberately omitted (require-corp would
    // break the cross-origin CDN subresources). COOP and CORP ARE set. This
    // pins that decision so it isn't silently changed.
    var response = invokeFilter();
    assertEquals(
        null, response.getHeader("Cross-Origin-Embedder-Policy"), "COEP must remain unset");
  }
}
