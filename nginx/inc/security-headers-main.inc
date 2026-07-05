# Browser security headers (main tier — includes HSTS).
include /etc/nginx/inc/security-headers.inc;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
