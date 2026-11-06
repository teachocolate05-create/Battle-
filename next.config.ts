import type { NextConfig } from "next";

// Supabase 주소 (실시간 연결 wss:// 포함) — 이 주소들로만 브라우저가 통신할 수 있게 제한
const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
const supabaseWs = supabaseUrl.replace(/^https:/, "wss:");
const isProd = process.env.NODE_ENV === "production";

/**
 * 보안 헤더
 *  - CSP: 우리 사이트와 Supabase 외의 곳에서 스크립트를 불러오거나 데이터를 보내지 못하게 막음 (XSS 2차 방어)
 *    (개발 모드는 Next.js 가 eval 을 쓰므로 운영 배포에서만 적용)
 *  - 다른 사이트가 이 사이트를 iframe 으로 감싸지 못하게(클릭재킹 방지), MIME 추측 금지 등
 */
const csp = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob:",
  "font-src 'self' data:",
  `connect-src 'self' ${supabaseUrl} ${supabaseWs}`.trim(),
  "frame-ancestors 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "object-src 'none'",
].join("; ");

const securityHeaders = [
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
  ...(isProd ? [{ key: "Content-Security-Policy", value: csp }] : []),
];

const nextConfig: NextConfig = {
  poweredByHeader: false,
  async headers() {
    return [{ source: "/(.*)", headers: securityHeaders }];
  },
};

export default nextConfig;
