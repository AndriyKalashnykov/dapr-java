package io.diagrid.dapr;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Adds baseline HTTP security response headers to every response served by pizza-store (the only
 * service exposed to a browser). Closes the OWASP ZAP baseline DAST findings (CSP not set, missing
 * anti-clickjacking, nosniff, Permissions-Policy, COOP/CORP) so the {@code e2e} job's ZAP scan can
 * run as a strict gate.
 *
 * <p>The Content-Security-Policy allowlists exactly the pinned third-party origins the frontend
 * loads (jQuery from code.jquery.com, STOMP from cdn.jsdelivr.net, Bootstrap CSS/fonts from
 * maxcdn.bootstrapcdn.com — all Subresource-Integrity pinned in index.html) plus the same-origin
 * WebSocket endpoint (/ws) the live order feed connects to. {@code style-src} keeps {@code
 * 'unsafe-inline'} because jQuery manipulates element styles at runtime; scripts carry no inline
 * allowance (the former inline {@code onload} handler was moved into app.js).
 *
 * <p>Cross-Origin-Embedder-Policy is intentionally NOT set: {@code require-corp} would force every
 * cross-origin CDN subresource to opt in via CORP and buys nothing without cross-origin-isolation
 * needs (no SharedArrayBuffer here). COOP and CORP are set.
 */
@Component
public class SecurityHeadersFilter extends OncePerRequestFilter {

  private static final String CONTENT_SECURITY_POLICY =
      String.join(
          "; ",
          "default-src 'self'",
          "script-src 'self' https://code.jquery.com https://cdn.jsdelivr.net",
          "style-src 'self' 'unsafe-inline' https://maxcdn.bootstrapcdn.com",
          "img-src 'self' data:",
          "font-src 'self' https://maxcdn.bootstrapcdn.com",
          "connect-src 'self' ws: wss:",
          "object-src 'none'",
          "base-uri 'self'",
          "frame-ancestors 'none'");

  private static final String PERMISSIONS_POLICY =
      String.join(
          ", ",
          "geolocation=()",
          "camera=()",
          "microphone=()",
          "payment=()",
          "usb=()",
          "accelerometer=()",
          "gyroscope=()",
          "magnetometer=()");

  @Override
  protected void doFilterInternal(
      HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
      throws ServletException, IOException {
    response.setHeader("Content-Security-Policy", CONTENT_SECURITY_POLICY);
    response.setHeader("X-Content-Type-Options", "nosniff");
    response.setHeader("X-Frame-Options", "DENY");
    response.setHeader("Referrer-Policy", "strict-origin-when-cross-origin");
    response.setHeader("Permissions-Policy", PERMISSIONS_POLICY);
    response.setHeader("Cross-Origin-Opener-Policy", "same-origin");
    response.setHeader("Cross-Origin-Resource-Policy", "same-origin");
    filterChain.doFilter(request, response);
  }
}
